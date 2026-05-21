import SwiftUI

/// Compact upcoming-price bar chart for the watch graph page. Hand-drawn
/// rather than Swift Charts so bar width, spacing, and the y-axis label
/// column are fully controlled on the small watch screen — bars fill the
/// width with hairline gaps and never overlap the axis labels. One bar
/// per slot (total price). Colour priority: the crown-selected bar is
/// amber, bars inside the cheapest window are green, the rest blue.
struct WatchPriceChart: View {
    let points: [WatchPricePoint]
    /// `points` indices to highlight as the selected cheapest window.
    let highlight: ClosedRange<Int>?
    /// The crown-selected bar index — drawn amber, wins over green.
    let selected: Int?

    private let barGap: CGFloat = 1
    private let yAxisWidth: CGFloat = 18

    /// Bar colour by priority: selected (amber) → cheapest window
    /// (green) → default (blue).
    private func barColor(_ index: Int) -> Color {
        if index == selected { return .orange }
        if highlight?.contains(index) == true { return .green }
        return .blue
    }

    /// Y-axis top, rounded up to a multiple of 5 (matches the app chart).
    private var axisMax: Double {
        let peak = points.map(\.total).max() ?? 1
        return max(5, (peak / 5).rounded(.up) * 5)
    }

    var body: some View {
        VStack(spacing: 1) {
            // Bars share a row with the y-axis so "0" lines up with the
            // bar baseline.
            HStack(alignment: .top, spacing: 4) {
                yAxisLabels
                plot
            }
            // Hour labels sit directly under the bars (indented past the
            // y-axis column so they align with their bar).
            xAxisLabels
                .padding(.leading, yAxisWidth + 4)
        }
        .font(.system(size: 9))
    }

    /// Right-aligned y labels: max, mid, 0 — in a fixed column left of
    /// the plot so bars never draw over them.
    private var yAxisLabels: some View {
        VStack(alignment: .trailing) {
            Text("\(Int(axisMax))")
            Spacer()
            Text("\(Int(axisMax / 2))")
            Spacer()
            Text("0")
        }
        .foregroundStyle(.secondary)
        .frame(width: yAxisWidth, alignment: .trailing)
    }

    private var plot: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Gridlines at 0 / 50% / 100%.
                ForEach([0.0, 0.5, 1.0], id: \.self) { fraction in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(maxWidth: .infinity)
                        .frame(height: 1)
                        .offset(y: -(geo.size.height - 1) * fraction)
                }
                // Bars — flexible widths fill the plot with hairline gaps.
                HStack(alignment: .bottom, spacing: barGap) {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(barColor(index))
                            .frame(height: max(1, geo.size.height * CGFloat(point.total / axisMax)))
                    }
                }
            }
        }
    }

    /// Sparse hour labels (every 6th hour) aligned under their bar.
    private var xAxisLabels: some View {
        GeometryReader { geo in
            let count = max(points.count, 1)
            let barWidth = (geo.size.width - barGap * CGFloat(count - 1)) / CGFloat(count)
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                if isLabelledHour(point.date) {
                    Text(point.date, format: Date.VerbatimFormatStyle.hour24)
                        .foregroundStyle(.secondary)
                        .position(x: CGFloat(index) * (barWidth + barGap) + barWidth / 2, y: 5)
                }
            }
        }
        .frame(height: 11)
    }

    /// Label only top-of-hour slots on a 6-hour stride (00/06/12/18).
    private func isLabelledHour(_ date: Date) -> Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return comps.minute == 0 && (comps.hour ?? 0) % 6 == 0
    }
}
