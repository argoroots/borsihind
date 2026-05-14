import SwiftUI
import Charts

/// Stacked bar chart of upcoming prices, one bar per slot.
/// Each bar is one slot (15-min or 1h); the six layered components stack
/// bottom-to-top. Three bar styles: normal blue, green for the highlighted
/// "cheapest N-hour window", amber for the bar pinned via `selectedDate`
/// (single-tap, wins over green). X-axis labels sit at HH:30 (centered
/// between hour ticks); y-axis snaps to multiples of 5 c/kWh.
struct PriceChart: View {
    let prices: [PriceEntry]
    let marginal: Double
    let interval: Interval
    let highlightRange: ClosedRange<Int>?
    @Binding var selectedDate: Date?

    /// Component layers, bottom → top of the stack. Raw values are stable
    /// internal identifiers; user-facing labels come from the String Catalog.
    private enum Layer: String, CaseIterable, Plottable {
        case marginal
        case excise
        case supplySec
        case renewable
        case transmission
        case electricity
    }

    /// How a bar should be coloured.
    private enum Style {
        case normal       // blue (default)
        case cheapHour    // green (within selected cheapest-window)
        case selected     // yellow/amber (single tapped bar — wins over green)
    }

    /// Tailwind blue-{800, 600, 500, 400, 300, 200}. Bottom (marginal) is the
    /// darkest shade; top (electricity) is the lightest.
    private static let blueShades: [Color] = [
        Color(red: 0.118, green: 0.251, blue: 0.686),
        Color(red: 0.149, green: 0.388, blue: 0.922),
        Color(red: 0.231, green: 0.510, blue: 0.965),
        Color(red: 0.376, green: 0.647, blue: 0.980),
        Color(red: 0.576, green: 0.773, blue: 0.992),
        Color(red: 0.749, green: 0.859, blue: 0.996)
    ]
    /// Emerald-{800..300} for cheapest-window highlight.
    private static let greenShades: [Color] = [
        Color(red: 0.024, green: 0.373, blue: 0.275),
        Color(red: 0.016, green: 0.471, blue: 0.341),
        Color(red: 0.020, green: 0.588, blue: 0.412),
        Color(red: 0.063, green: 0.725, blue: 0.506),
        Color(red: 0.204, green: 0.827, blue: 0.600),
        Color(red: 0.431, green: 0.906, blue: 0.718)
    ]
    /// Amber gradient derived from the icon's #fec012 / #c79100 — used for
    /// the single tapped bar. Bottom (marginal layer) is dark, top (electricity)
    /// is light.
    private static let amberShades: [Color] = [
        Color(red: 0.420, green: 0.300, blue: 0.000),  // dark amber
        Color(red: 0.560, green: 0.400, blue: 0.000),
        Color(red: 0.700, green: 0.510, blue: 0.000),  // ~icon dark #c79100
        Color(red: 0.880, green: 0.650, blue: 0.040),
        Color(red: 1.000, green: 0.752, blue: 0.071),  // ~icon yellow #fec012
        Color(red: 1.000, green: 0.847, blue: 0.290)   // light yellow
    ]

    /// One row per (entry, layer) — flat data so the chart needs only one
    /// `ForEach`, which the `@ChartContentBuilder` compiler handles cleanly.
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

    /// Effective selection: explicit tap (only if still visible),
    /// otherwise the current (first) bar — which auto-advances every
    /// minute as past slots drop out.
    private var effectiveSelectedDate: Date? {
        if let d = selectedDate, prices.contains(where: { $0.date == d }) {
            return d
        }
        return prices.first?.date
    }

    private func barStyle(for entry: PriceEntry) -> Style {
        if entry.date == effectiveSelectedDate {
            return .selected
        }
        if let r = highlightRange,
           let idx = prices.firstIndex(where: { $0.date == entry.date }),
           r.contains(idx) {
            return .cheapHour
        }
        return .normal
    }

    private var slotSeconds: TimeInterval {
        TimeInterval(interval.minutes * 60)
    }

    /// Top of the y-axis: largest stacked total in the visible data, rounded
    /// up to the next multiple of 5 so ticks land on nice numbers.
    private var yAxisMax: Double {
        let dataMax = prices.map { $0.componentSum + marginal }.max() ?? 1
        return max(5, (dataMax / 5).rounded(.up) * 5)
    }

    /// Hour boundaries (HH:00) covering the data range, with synthetic
    /// boundaries at both ends so the first/last centered labels always
    /// have a "next" tick to anchor against — even when the app opens
    /// mid-hour and the first visible slot is e.g. 09:15 or 09:30.
    private var hourBoundaryDates: [Date] {
        let cal = Calendar.current
        var dates: [Date] = []

        // Leading synthetic boundary: HH:00 of the first slot's hour.
        if let first = prices.first?.date {
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: first)
            if let hourStart = cal.date(from: comps) {
                dates.append(hourStart)
            }
        }

        // Real HH:00 boundaries inside the data.
        for entry in prices where cal.component(.minute, from: entry.date) == 0 {
            if dates.last != entry.date {
                dates.append(entry.date)
            }
        }

        // Trailing synthetic boundary one hour past the last real one so
        // the last centered label also renders.
        if let last = dates.last {
            dates.append(last.addingTimeInterval(3600))
        }

        return dates
    }

    /// Minimum horizontal space (in points) each "HH" label needs to read
    /// cleanly without crowding its neighbours. Two-digit body-font labels
    /// measure ~18pt wide; 30pt gives a comfortable gap.
    private static let minLabelSpacing: CGFloat = 30

    /// How many hours to step between labels, given the chart's available
    /// width. Picks the smallest step from {1,2,4,6} that keeps every
    /// rendered label at least `minLabelSpacing` apart. Sticking to divisors
    /// of 24 keeps labels aligned to round hours (00, 04, 08, …).
    private func labelHourStep(forWidth width: CGFloat) -> Int {
        let hours = max(hourBoundaryDates.count, 1)
        let perHour = width / CGFloat(hours)
        for step in [1, 2, 4, 6] {
            if perHour * CGFloat(step) >= Self.minLabelSpacing {
                return step
            }
        }
        return 6
    }

    /// Should the label at this axis value render, given the chosen step?
    private func showLabel(at value: AxisValue, step: Int) -> Bool {
        guard let date = value.as(Date.self) else { return true }
        return Calendar.current.component(.hour, from: date) % step == 0
    }

    /// Visible time range. Extends back to the first slot's hour start so
    /// the leading synthetic axis boundary is in-domain (otherwise Charts
    /// would drop it and the first label).
    private var xDomain: ClosedRange<Date> {
        guard let first = hourBoundaryDates.first,
              let last = hourBoundaryDates.last else {
            return Date()...Date().addingTimeInterval(3600)
        }
        return first...last
    }

    var body: some View {
        // Wrap in GeometryReader so the hour-label stride can adapt to the
        // actual chart width — every hour fits on a wide macOS window, but
        // long day-ahead datasets on a phone need 2/4/6h stride to avoid
        // overlap.
        GeometryReader { geo in
            let step = labelHourStep(forWidth: geo.size.width)
            chart
                .chartLegend(.hidden)
                .chartXScale(domain: xDomain)
                .chartXAxis {
                    // Single AxisMarks at HH:00 boundaries: ticks land on the
                    // hour, labels (centered: true) sit between adjacent ticks
                    // — i.e. at HH:30, the visual midpoint of each hour group.
                    AxisMarks(values: hourBoundaryDates) { value in
                        if interval == .fifteenMin {
                            // Solid (no dash). Color is the default Charts grid
                            // colour so it matches the horizontal y-axis lines.
                            AxisTick(stroke: StrokeStyle(lineWidth: 1))
                        }
                        if showLabel(at: value, step: step) {
                            // Disabled collision resolution — our width-aware
                            // hour stride already produces gaps wide enough
                            // that labels never overlap, so we want them all
                            // to render rather than letting Charts hide some
                            // unpredictably.
                            AxisValueLabel(
                                format: Date.VerbatimFormatStyle.hour24,
                                centered: true,
                                collisionResolution: .disabled
                            )
                            .font(.body)
                        }
                    }
                }
                .chartYScale(domain: 0...yAxisMax)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .stride(by: 5)) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                            .font(.body)
                    }
                }
                .chartOverlay { proxy in
                    tapOverlay(proxy: proxy)
                }
        }
    }

    /// Midnight (00:00) boundaries inside the visible x-domain. Drives the
    /// day-divider rule marks so the user can tell at a glance where
    /// "tomorrow" begins in the day-ahead price strip.
    private var midnightDates: [Date] {
        let cal = Calendar.current
        return hourBoundaryDates.filter { cal.component(.hour, from: $0) == 0 }
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
            // Day divider — thin dashed vertical line at each 00:00 so the
            // boundary between today and tomorrow is visually obvious.
            ForEach(midnightDates, id: \.self) { date in
                RuleMark(x: .value("Midnight", date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func tapOverlay(proxy: ChartProxy) -> some View {
        #if os(tvOS)
        // tvOS uses the focus engine; location-based taps aren't available.
        // Bar selection is disabled — the chart is read-only on Apple TV.
        EmptyView()
        #else
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onTapGesture { location in
                    handleTap(at: location, proxy: proxy, geo: geo)
                }
        }
        #endif
    }

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

    private func layerValues(entry: PriceEntry) -> [(Layer, Double)] {
        [
            (.marginal,     marginal),
            (.excise,       entry.excise),
            (.supplySec,    entry.supplySecurity),
            (.renewable,    entry.renewable),
            (.transmission, entry.transmission),
            (.electricity,  entry.electricity)
        ]
    }

    private struct LayerSegment: Identifiable {
        let layer: Layer
        let yStart: Double
        let yEnd: Double
        var id: Layer { layer }
    }

    /// Cumulative y-ranges per layer so `RectangleMark(xStart:xEnd:yStart:yEnd:)`
    /// renders a proper stacked vertical bar.
    private func layerSegments(for entry: PriceEntry) -> [LayerSegment] {
        var segments: [LayerSegment] = []
        var cumulative: Double = 0
        for (layer, value) in layerValues(entry: entry) {
            segments.append(LayerSegment(
                layer: layer,
                yStart: cumulative,
                yEnd: cumulative + value
            ))
            cumulative += value
        }
        return segments
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

}
