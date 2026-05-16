import SwiftUI

/// One cheapest-hours card: hour badge on the left, time range + average +
/// savings on the right. Tapping toggles selection (chart highlight).
struct LowestWindowCard: View {
    let window: LowestWindow
    let isSelected: Bool
    /// Premium-gated (slots 1...3 for free users). Tap opens the paywall.
    let isLocked: Bool
    /// `false` while StoreKit is still resolving — render placeholder.
    let isReady: Bool
    /// Average price of the same N hours starting now. Baseline for "% cheaper".
    let nowAverage: Double?
    let onTap: () -> Void

    @Environment(\.locale) private var locale
    @State private var isHovering = false
    @State private var showDeadlineExplanation = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 14) {
                Text(window.label)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.green.opacity(0.6))
                    .frame(minWidth: 36)

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
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(
                RoundedRectangle(cornerRadius: 8).fill(backgroundFill)
            )
        }
        .buttonStyle(.plain)
        #if !os(tvOS)
        .onHover { isHovering = $0 }
        #endif
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
                Spacer()
                Text(window.averagePrice.formatted(.number.precision(.fractionLength(2)).locale(locale)))
                    .font(.headline.weight(.regular))
                    .foregroundStyle(.primary)
            }
            Text(percentString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived strings + styling

    private var backgroundFill: Color {
        if isSelected { return Color.green.opacity(0.15) }
        if isHovering { return Color.green.opacity(0.06) }
        return Color.clear
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
