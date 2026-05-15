import SwiftUI

/// One row in the cheapest-hours list. Shows a green `1h`/`2h`/`3h`/`4h`
/// badge on the left and the window's time range, average price, and percent
/// savings vs. running an N-hour load starting *right now* on the right.
/// Tapping toggles selection (light-green tinted background); non-selected
/// rows light up on hover.
struct LowestWindowCard: View {
    let window: LowestWindow
    let isSelected: Bool
    /// True when the window is gated behind Börsihind+ (2/3/4h windows for
    /// non-subscribers). The card still renders, but with a lock icon and
    /// tap routes to the paywall.
    let isLocked: Bool
    /// `false` while the subscription state hasn't been resolved yet — the
    /// card renders just the hour badge and reserves the right-side space
    /// without flashing Börsihind+ chrome that may be wrong.
    let isReady: Bool
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

                if !isReady {
                    // Subscription state not yet known — reserve the slot
                    // but render nothing so we don't flash a Börsihind+ tag
                    // that may be wrong. Color.clear keeps the card height
                    // stable so the layout doesn't jump when content lands.
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 36)
                } else if isLocked {
                    // Locked card: hide the actual time/price (the answer
                    // users pay for). Single subdued line vertically
                    // centered with the badge. minHeight matches the
                    // unlocked card's two-line height so all rows in the
                    // list have the same height.
                    HStack {
                        Text(savingsTeaser)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("Börsihind+")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        // Row 1: time range on the left, price on the right.
                        HStack(spacing: 4) {
                            Text(window.start, format: Date.VerbatimFormatStyle.hourMinute24)
                                .font(.headline.bold())
                            Text("–")
                                .font(.headline)
                            Text(window.end, format: Date.VerbatimFormatStyle.hourMinute24)
                                .font(.headline.bold())
                            Spacer()
                            Text(window.averagePrice.formatted(.number.precision(.fractionLength(2)).locale(locale)))
                                .font(.headline.weight(.regular))
                                .foregroundStyle(.primary)
                        }
                        // Row 2: savings %, left-aligned under the time range.
                        Text(percentString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundFill)
            )
        }
        .buttonStyle(.plain)
        #if !os(tvOS)
        // tvOS has no mouse/pointer; the hover tint isn't applicable.
        .onHover { isHovering = $0 }
        #endif
    }

    private var backgroundFill: Color {
        if isSelected { return Color.green.opacity(0.15) }
        if isHovering { return Color.green.opacity(0.06) }
        return Color.clear
    }

    /// Savings % vs running the same N hours starting now. Computed from
    /// the raw (full-precision) prices, then rounded to a whole percent for
    /// display. Returns nil when there isn't enough future data.
    private var roundedDiffPercent: Int? {
        guard let baseline = nowAverage, baseline > 0 else { return nil }
        let pct = (baseline - window.averagePrice) / baseline * 100
        return Int(pct.rounded())
    }

    /// Display string for the unlocked savings %.
    ///   - window cheaper → "N% cheaper than now"
    ///   - window pricier → "N% higher than now" (defensive — shouldn't
    ///     normally hit since the cheapest finder picks the minimum)
    ///   - equal after rounding → "0%"
    private var percentString: String {
        guard let pct = roundedDiffPercent else { return "—" }
        if pct > 0 {
            return locale.t("%@% cheaper than now").replacingOccurrences(of: "%@", with: String(pct))
        }
        if pct < 0 {
            return locale.t("%@% higher than now").replacingOccurrences(of: "%@", with: String(-pct))
        }
        return "0%"
    }

    /// Status line for locked cards. Just states whether there's a cheaper
    /// future window or not — the actual time/price is what subscription
    /// unlocks. Math note: the cheapest-window finder picks the minimum
    /// average, so savings is never strictly negative; rounding to whole-%
    /// gives us a clean binary "is there a cheaper window or is now already
    /// the cheapest".
    private var savingsTeaser: String {
        let savings = roundedDiffPercent ?? 0
        return savings > 0
            ? locale.t("Cheaper window available")
            : locale.t("Already cheapest now")
    }

}
