import SwiftUI

/// One row in the cheapest-hours list. Shows a green `1h`/`2h`/`3h`/`4h`
/// badge on the left and the window's time range, average price, and percent
/// savings vs. running an N-hour load starting *right now* on the right.
/// Tapping toggles selection (light-green tinted background); non-selected
/// rows light up on hover.
struct LowestWindowCard: View {
    let window: LowestWindow
    let isSelected: Bool
    /// Average price of the same number of consecutive hours starting now —
    /// the apples-to-apples baseline for the savings %. `nil` when not enough
    /// future data is available.
    let nowAverage: Double?
    let onTap: () -> Void

    @Environment(\.locale) private var locale
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 14) {
                Text(window.label)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.green.opacity(0.6))
                    .frame(minWidth: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(window.start, format: Self.timeFormat)
                            .font(.headline.bold())
                        Text("–")
                            .font(.headline)
                        Text(window.end, format: Self.timeFormat)
                            .font(.headline.bold())
                    }
                    HStack {
                        Text(window.averagePrice.formatted(.number.precision(.fractionLength(2)).locale(locale)))
                            .font(.headline.weight(.regular))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(percentString)
                            .font(.headline.weight(.regular))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundFill)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var backgroundFill: Color {
        if isSelected { return Color.green.opacity(0.15) }
        if isHovering { return Color.green.opacity(0.06) }
        return Color.clear
    }

    /// How much cheaper the window is vs. running for the same N hours
    /// starting now. Positive when the window saves money; negative when
    /// it would actually be more expensive than running now.
    private var percentString: String {
        guard let baseline = nowAverage, baseline > 0 else { return "—" }
        let diff = (baseline - window.averagePrice) / baseline * 100
        let rounded = Int(diff.rounded())
        if rounded > 0 { return "−\(rounded)%" }   // window is cheaper → "−N% vs now"
        if rounded < 0 { return "+\(-rounded)%" }  // window is pricier → "+N% vs now"
        return "0%"
    }

    /// 24-hour HH:mm regardless of locale, matching the chart axis style.
    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened)
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
}
