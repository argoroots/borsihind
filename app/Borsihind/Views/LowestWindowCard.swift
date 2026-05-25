import SwiftUI

/// One cheapest-hours card: hour badge on the left, time range + average +
/// savings on the right. Tapping invokes `onTap` (caller decides whether to
/// select/toggle the chart highlight or open the paywall).
struct LowestWindowCard: View {
    let window: LowestWindow
    let isSelected: Bool
    /// Premium-gated (slots 1...3 for free users). Tap opens the paywall.
    let isLocked: Bool
    /// `false` while StoreKit is still resolving — render placeholder.
    let isReady: Bool
    /// Average price of the same N hours starting now. Baseline for "% cheaper".
    let nowAverage: Double?
    /// iPhone carousel: every card uses the selected tint (no lighter
    /// non-selected state). Defaults off (iPad/Mac column distinguishes).
    var uniformBackground: Bool = false
    let onTap: () -> Void

    @Environment(\.locale) private var locale
    @State private var isHovering = false
    @State private var showDeadlineExplanation = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 18) {
                Text(window.label)
                    // Smaller badge on macOS; larger on iOS/iPadOS.
                    #if os(macOS)
                    .font(.system(size: 22, weight: .bold))
                    #else
                    .font(.system(size: 30, weight: .bold))
                    #endif
                    .foregroundStyle(Color.green.opacity(0.6))
                    .fixedSize()

                if !isReady {
                    // Reserve height while subscription state resolves.
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 36)
                } else if isLocked {
                    lockedContent
                } else {
                    unlockedContent
                }
            }
            // Larger green section with more breathing room.
            .padding(18)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(
                RoundedRectangle(cornerRadius: 8).fill(backgroundFill)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .alert(locale.t("Deadline warning"), isPresented: $showDeadlineExplanation) {
            Button(locale.t("OK"), role: .cancel) { }
        } message: {
            Text(deadlineExplanation)
        }
    }

    // MARK: - Inner layouts

    private var lockedContent: some View {
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
    }

    private var unlockedContent: some View {
        // Price is a sibling of the two-line time/percent block so it sits
        // vertically centred against it. The block fills the remaining width
        // (8pt gap) so the price stays pinned to the right.
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(window.start, format: Date.VerbatimFormatStyle.hourMinute24)
                        .font(.headline.bold())
                    Text("–")
                        .font(.headline)
                    Text(window.end, format: Date.VerbatimFormatStyle.hourMinute24)
                        .font(.headline.bold())
                    if window.missedDeadline != nil {
                        // Inner Button intercepts the tap so the outer card
                        // selection doesn't toggle.
                        Button { showDeadlineExplanation = true } label: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(locale.t("Deadline warning"))
                    }
                }
                Text(percentString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(window.averagePrice.priceString(locale: locale))
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                // Hug the price (dynamic width, never truncate) and keep it
                // pinned to the right; the time block yields space first.
                .fixedSize()
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived strings + styling

    private var backgroundFill: Color {
        // Selected card (or every card when `uniformBackground`) gets the
        // strong tint; others are lighter so the selection stands out in the
        // iPad/Mac column.
        if uniformBackground || isSelected { return Color.green.opacity(0.18) }
        if isHovering { return Color.green.opacity(0.08) }
        return Color.green.opacity(0.05)
    }

    /// Window savings vs. running the same N hours starting now, rounded
    /// to a whole percent. Nil when not enough future data is available.
    private var roundedDiffPercent: Int? {
        guard let baseline = nowAverage, baseline > 0 else { return nil }
        return Int(((baseline - window.averagePrice) / baseline * 100).rounded())
    }

    private var percentString: String {
        guard let pct = roundedDiffPercent else { return "—" }
        if pct > 0 {
            return locale.t("%@% cheaper than now").replacingOccurrences(of: "%@", with: String(pct))
        }
        if pct < 0 {
            return locale.t("%@% higher than now").replacingOccurrences(of: "%@", with: String(-pct))
        }
        // Window starts at index 0 → it *is* the current slot. Future
        // windows that just happen to match the running-now average
        // keep the "same as now" wording.
        return window.startIndex == 0
            ? locale.t("Right now")
            : locale.t("Same price as now")
    }

    /// Locked-card status line. Cheapest finder picks the minimum, so
    /// "negative savings" never happens — we just need a binary "is there
    /// a cheaper window or not".
    private var savingsTeaser: String {
        (roundedDiffPercent ?? 0) > 0
            ? locale.t("Cheaper window available")
            : locale.t("Already cheapest now")
    }

    /// Alert body. Uses `{token}` placeholders so the localized template
    /// can reorder freely.
    private var deadlineExplanation: String {
        let fmt = Date.VerbatimFormatStyle.hourMinute24
        let deadlineStr = window.missedDeadline.map { $0.formatted(fmt) } ?? "—"
        return locale.t("No {hours}h window fits before {deadline}. Showing the cheapest available window ({start} – {end}) as a fallback.")
            .replacingOccurrences(of: "{hours}", with: String(window.hours))
            .replacingOccurrences(of: "{deadline}", with: deadlineStr)
            .replacingOccurrences(of: "{start}", with: window.start.formatted(fmt))
            .replacingOccurrences(of: "{end}", with: window.end.formatted(fmt))
    }
}
