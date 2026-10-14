import SwiftUI
import Charts

/// Stacked bar chart of upcoming prices, one bar per slot.
/// Six layered components stack bottom→top per bar; three styles: normal
/// blue, green for the selected cheapest-window highlight, amber for the
/// bar pinned via tap (wins over green). A negative electricity price offsets
/// the whole stack below zero. Y-axis bounds round to whole cents with an
/// automatic step; X-axis labels are centred between hour ticks.
struct PriceChart: View {
    let prices: [PriceEntry]
    let marginal: Double
    let interval: Interval
    let highlightRange: ClosedRange<Int>?
    @Binding var selectedDate: Date?

    /// Stack layers bottom→top.
    private enum Layer: String, CaseIterable, Plottable {
        case marginal, excise, supplySec, renewable, transmission, electricity
    }

    private enum Style {
        case normal     // blue
        case cheapHour  // green (selected cheapest window)
        case selected   // amber (tapped bar — wins over green)
    }

    // Tailwind blue-{800, 600, 500, 400, 300, 200}.
    private static let blueShades: [Color] = [
        Color(red: 0.118, green: 0.251, blue: 0.686),
        Color(red: 0.149, green: 0.388, blue: 0.922),
        Color(red: 0.231, green: 0.510, blue: 0.965),
        Color(red: 0.376, green: 0.647, blue: 0.980),
        Color(red: 0.576, green: 0.773, blue: 0.992),
        Color(red: 0.749, green: 0.859, blue: 0.996),
    ]
    // Emerald-{800..300}.
    private static let greenShades: [Color] = [
        Color(red: 0.024, green: 0.373, blue: 0.275),
        Color(red: 0.016, green: 0.471, blue: 0.341),
        Color(red: 0.020, green: 0.588, blue: 0.412),
        Color(red: 0.063, green: 0.725, blue: 0.506),
        Color(red: 0.204, green: 0.827, blue: 0.600),
        Color(red: 0.431, green: 0.906, blue: 0.718),
    ]
    // Amber gradient derived from the app icon (#fec012 / #c79100).
    private static let amberShades: [Color] = [
        Color(red: 0.420, green: 0.300, blue: 0.000),
        Color(red: 0.560, green: 0.400, blue: 0.000),
        Color(red: 0.700, green: 0.510, blue: 0.000),
        Color(red: 0.880, green: 0.650, blue: 0.040),
        Color(red: 1.000, green: 0.752, blue: 0.071),
        Color(red: 1.000, green: 0.847, blue: 0.290),
    ]

    /// Minimum gap between rendered hour labels — two-digit body-font
    /// labels measure ~18pt, so 30pt is comfortable.
    private static let minLabelSpacing: CGFloat = 30

    // MARK: - Body

    var body: some View {
        // GeometryReader so the hour-label stride adapts to chart width:
        // every hour fits on a wide window, narrow phones need 2/4/6h.
        GeometryReader { geo in
            let step = labelHourStep(forWidth: geo.size.width)
            chart
                .chartLegend(.hidden)
                .chartXScale(domain: xDomain)
                .chartXAxis {
                    AxisMarks(values: hourBoundaryDates) { value in
                        if interval == .fifteenMin {
                            AxisTick(stroke: StrokeStyle(lineWidth: 1))
                        }
                        if showLabel(at: value, step: step) {
                            // `collisionResolution: .disabled` because our
                            // width-aware stride already guarantees spacing.
                            AxisValueLabel(
                                format: Date.VerbatimFormatStyle.hour24,
                                centered: true,
                                collisionResolution: .disabled
                            )
                            .font(.subheadline)
                        }
                    }
                }
                .chartYScale(domain: yAxisMin...yAxisMax)
                .chartYAxis {
                    // Automatic step, but ask for a finer subdivision than the
                    // default (which lands on 5 for our typical range).
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 10)) { _ in
                        AxisGridLine()
                        AxisValueLabel().font(.subheadline)
                    }
                }
                .chartOverlay { proxy in
                    tapOverlay(proxy: proxy)
                }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(barRows) { row in
                RectangleMark(
                    xStart: .value("Start", row.xStart),
                    xEnd: .value("End", row.xEnd),
                    yStart: .value("YStart", row.yStart),
                    yEnd: .value("YEnd", row.yEnd)
                )
                .foregroundStyle(color(for: row.layer, style: row.style))
            }
            // Day divider — dashed vertical line at each 00:00.
            ForEach(midnightDates, id: \.self) { date in
                RuleMark(x: .value("Midnight", date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tapOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onTapGesture { location in
                    handleTap(at: location, proxy: proxy, geo: geo)
                }
        }
    }

    // MARK: - Bar rows

    /// One row per (entry, layer) — flat data so the chart uses a single
    /// ForEach that `@ChartContentBuilder` handles cleanly.
    private struct BarRow: Identifiable {
        let id: String
        let layer: Layer
        let xStart: Date
        let xEnd: Date
        let yStart: Double
        let yEnd: Double
        let style: Style
    }

    private var barRows: [BarRow] {
        let inset = slotSeconds * 0.06
        return prices.flatMap { entry -> [BarRow] in
            let xStart = entry.date.addingTimeInterval(inset)
            let xEnd = entry.date.addingTimeInterval(slotSeconds - inset)
            let style = barStyle(for: entry)
            return layerSegments(for: entry).map { seg in
                BarRow(
                    id: "\(entry.date.timeIntervalSinceReferenceDate)-\(seg.layer.rawValue)",
                    layer: seg.layer,
                    xStart: xStart,
                    xEnd: xEnd,
                    yStart: seg.yStart,
                    yEnd: seg.yEnd,
                    style: style
                )
            }
        }
    }

    private struct LayerSegment: Identifiable {
        let layer: Layer
        let yStart: Double
        let yEnd: Double
        var id: Layer { layer }
    }

    /// Cumulative y-ranges per layer — drives the stacked vertical bar.
    /// Negative components (e.g. a negative electricity price) offset the whole
    /// stack downward: every positive layer keeps its full size, the bar's base
    /// dips below zero, and its top equals the net total. So a negative price
    /// shortens the bar without distorting any individual component.
    private func layerSegments(for entry: PriceEntry) -> [LayerSegment] {
        let values = layerValues(entry: entry)
        let baseline = values.reduce(0) { $0 + min(0, $1.1) }   // ≤ 0
        var segments: [LayerSegment] = []
        var cumulative = baseline
        for (layer, value) in values where value > 0 {
            segments.append(LayerSegment(layer: layer, yStart: cumulative, yEnd: cumulative + value))
            cumulative += value
        }
        return segments
    }

    private func layerValues(entry: PriceEntry) -> [(Layer, Double)] {
        [
            (.marginal,     marginal),
            (.excise,       entry.excise),
            (.supplySec,    entry.supplySecurity),
            (.renewable,    entry.renewable),
            (.transmission, entry.transmission),
            (.electricity,  entry.electricity),
        ]
    }

    // MARK: - Style + selection

    /// Effective selection: explicit tap (if still visible), else the
    /// current first bar (auto-advances every minute as past slots drop).
    private var effectiveSelectedDate: Date? {
        if let d = selectedDate, prices.contains(where: { $0.date == d }) {
            return d
        }
        return prices.first?.date
    }

    private func barStyle(for entry: PriceEntry) -> Style {
        if entry.date == effectiveSelectedDate { return .selected }
        if let r = highlightRange,
           let idx = prices.firstIndex(where: { $0.date == entry.date }),
           r.contains(idx) {
            return .cheapHour
        }
        return .normal
    }

    private func color(for layer: Layer, style: Style) -> Color {
        let palette: [Color] = switch style {
        case .normal:    Self.blueShades
        case .cheapHour: Self.greenShades
        case .selected:  Self.amberShades
        }
        switch layer {
        case .marginal:     return palette[0]
        case .excise:       return palette[1]
        case .supplySec:    return palette[2]
        case .renewable:    return palette[3]
        case .transmission: return palette[4]
        case .electricity:  return palette[5]
        }
    }

    // MARK: - Axis math

    private var slotSeconds: TimeInterval { TimeInterval(interval.minutes * 60) }

    /// Net total for a bar (all components + marginal); can be negative.
    private func netTotal(for entry: PriceEntry) -> Double {
        entry.componentSum + marginal
    }

    /// Rounding unit for the y-axis bounds — small so there's little wasted
    /// headroom above the tallest bar / below the lowest.
    private static let axisRounding: Double = 1

    /// Top of the y-axis: largest net total rounded up to `axisRounding`.
    private var yAxisMax: Double {
        let dataMax = prices.map { netTotal(for: $0) }.max() ?? 1
        let r = Self.axisRounding
        return max(r, (dataMax / r).rounded(.up) * r)
    }

    /// Bottom of the y-axis: 0 normally, or the most-negative bar base (the
    /// summed negative components) rounded down to `axisRounding` — this is the
    /// lowest the offset stack dips below zero.
    private var yAxisMin: Double {
        let dataMin = prices.map { entry in
            layerValues(entry: entry).reduce(0) { $0 + min(0, $1.1) }
        }.min() ?? 0
        guard dataMin < 0 else { return 0 }
        let r = Self.axisRounding
        return (dataMin / r).rounded(.down) * r
    }

    /// Hour boundaries (HH:00) inside the data range, plus synthetic
    /// boundaries at both ends so the first/last centered labels always
    /// have a "next" tick to anchor against — even when the app opens
    /// mid-hour (e.g. first slot at 09:15).
    private var hourBoundaryDates: [Date] {
        let cal = Calendar.current
        var dates: [Date] = []

        if let first = prices.first?.date {
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: first)
            if let hourStart = cal.date(from: comps) {
                dates.append(hourStart)
            }
        }
        for entry in prices where cal.component(.minute, from: entry.date) == 0 {
            if dates.last != entry.date {
                dates.append(entry.date)
            }
        }
        if let last = dates.last {
            dates.append(last.addingTimeInterval(3600))
        }
        return dates
    }

    /// Midnight boundaries inside the x-domain — drive the day-divider rule.
    private var midnightDates: [Date] {
        let cal = Calendar.current
        return hourBoundaryDates.filter { cal.component(.hour, from: $0) == 0 }
    }

    /// Smallest hour stride from {1,2,4,6} that keeps every rendered label
    /// at least `minLabelSpacing` apart. Divisors of 24 so labels stay
    /// aligned to round hours.
    private func labelHourStep(forWidth width: CGFloat) -> Int {
        let hours = max(hourBoundaryDates.count, 1)
        let perHour = width / CGFloat(hours)
        for step in [1, 2, 4, 6] where perHour * CGFloat(step) >= Self.minLabelSpacing {
            return step
        }
        return 6
    }

    private func showLabel(at value: AxisValue, step: Int) -> Bool {
        guard let date = value.as(Date.self) else { return true }
        return Calendar.current.component(.hour, from: date) % step == 0
    }

    /// Visible time range. Extends back to the first slot's hour start so
    /// the leading synthetic boundary is in-domain.
    private var xDomain: ClosedRange<Date> {
        guard let first = hourBoundaryDates.first,
              let last = hourBoundaryDates.last
        else { return Date()...Date().addingTimeInterval(3600) }
        return first...last
    }

    // MARK: - Tap

    private func handleTap(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geo[plotFrame].origin
        let x = location.x - origin.x
        guard let date: Date = proxy.value(atX: x) else { return }
        let nearest = prices.first(where: {
            date >= $0.date && date < $0.date.addingTimeInterval(slotSeconds)
        }) ?? prices.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
        selectedDate = nearest?.date
    }
}
