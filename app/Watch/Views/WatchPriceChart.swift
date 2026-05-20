import SwiftUI

/// Compact upcoming-price bar chart for the watch graph page. Hand-drawn
/// rather than Swift Charts so bar width, spacing, and the y-axis label
/// column are fully controlled on the small watch screen — bars fill the
/// width with hairline gaps and never overlap the axis labels. One bar
/// per slot (total price); bars inside the selected cheapest window are
/// green, the rest blue.
struct WatchPriceChart: View {
    let points: [WatchPricePoint]
    /// `points` indices to highlight as the selected cheapest window.
    let highlight: ClosedRange<Int>?

    private let barGap: CGFloat = 1

    /// Y-axis top, rounded up to a multiple of 5 (matches the app chart).
    private var axisMax: Double {
        let peak = points.map(\.total).max() ?? 1
        return max(5, (peak / 5).rounded(.up) * 5)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            yAxisLabels
            VStack(spacing: 2) {
                plot
                xAxisLabels
            }
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
        .frame(width: 18, alignment: .trailing)
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
                            .fill(highlight?.contains(index) == true ? Color.green : Color.blue)
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
                        .position(x: CGFloat(index) * (barWidth + barGap) + barWidth / 2, y: 6)
                }
            }
        }
        .frame(height: 12)
    }

    /// Label only top-of-hour slots on a 6-hour stride (00/06/12/18).
    private func isLabelledHour(_ date: Date) -> Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return comps.minute == 0 && (comps.hour ?? 0) % 6 == 0
    }
}
