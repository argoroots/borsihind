import WidgetKit
import SwiftUI

/// Glanceable current-price widget. Reads pre-computed snapshots written
/// by the main app to the App Group — no network or StoreKit calls in
/// the widget process. Refreshes when the app re-writes the snapshot,
/// plus once per slot end via the timeline policy.
struct CurrentPriceWidget: Widget {
    let kind = "CurrentPriceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PriceProvider()) { entry in
            CurrentPriceWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Börsihind")
        .description("Hetkehind koos kõikide tasudega. Pluss odavaim tund.")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        // Lock-screen / Watch accessory families are iOS / iPadOS only.
        // macOS desktop widgets only have system small/medium.
        #if os(iOS)
        [.systemSmall, .systemMedium,
         .accessoryRectangular, .accessoryCircular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }
}

// MARK: - Timeline

struct PriceEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedStorage.Snapshot?
    /// Mirrors `StoreManager.isSubscribed`, used to gate the widget
    /// behind the Börsihind+ paywall.
    let isSubscribed: Bool
}

struct PriceProvider: TimelineProvider {
    func placeholder(in context: Context) -> PriceEntry {
        PriceEntry(date: Date(), snapshot: nil, isSubscribed: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (PriceEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PriceEntry>) -> Void) {
        // Refresh at the current slot's end so the visible price flips
        // at the slot boundary; fall back to every 30 min when no
        // snapshot is available.
        let entry = currentEntry()
        let next = entry.snapshot?.currentEnd ?? Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> PriceEntry {
        PriceEntry(
            date: Date(),
            snapshot: SharedStorage.readSnapshot(),
            isSubscribed: SharedStorage.isSubscribed
        )
    }
}

// MARK: - Root view

struct CurrentPriceWidgetView: View {
    let entry: PriceEntry
    @Environment(\.widgetFamily) private var family

    /// Read the user's language from shared storage. The widget process
    /// has its own UserDefaults.standard, so `store: .shared` is required.
    @AppStorage("language", store: .shared) private var languageRaw: String = Language.et.rawValue

    private var locale: Locale {
        (Language(rawValue: languageRaw) ?? .et).locale
    }

    var body: some View {
        Group {
            if entry.isSubscribed {
                switch family {
                #if os(iOS)
                case .accessoryInline:      inlineView
                case .accessoryCircular:    circularView
                case .accessoryRectangular: rectangularView
                #endif
                case .systemMedium:         mediumView
                default:                    smallView
                }
            } else {
                lockedView
            }
        }
        // Free users tap → paywall; subscribers tap → default scene.
        .widgetURL(entry.isSubscribed ? nil : URL(string: "borsihind://paywall"))
    }

    /// Compact upsell shown to non-subscribers in every widget family.
    private var lockedView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Börsihind+")
                .font(.headline.bold())
                .foregroundStyle(.primary)
            Text(locale.t("Open widget"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Lock Screen / Watch (iOS only)

#if os(iOS)
private extension CurrentPriceWidgetView {

    var inlineView: some View {
        Group {
            if let snap = entry.snapshot {
                Text("\(WidgetFormat.price(snap.currentTotal, locale: locale)) c/kWh")
            } else {
                Text("Börsihind")
            }
        }
    }

    /// Circular complication — just the integer cents.
    var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(WidgetFormat.integer(entry.snapshot?.currentTotal))
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                Text("c/kWh")
                    .font(.system(size: 9))
            }
        }
    }

    var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Börsihind").font(.caption2.weight(.semibold))
            HStack(alignment: .firstTextBaseline) {
                Text(WidgetFormat.price(entry.snapshot?.currentTotal, locale: locale))
                    .font(.title3.bold())
                    .monospacedDigit()
                Text("c/kWh").font(.caption2)
            }
            if let snap = entry.snapshot, let cheapest = snap.cheapestStart {
                Text("\(cheapestHeader): \(cheapest, format: WidgetFormat.hourMinute24)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif

// MARK: - Home Screen

private extension CurrentPriceWidgetView {

    var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            priceBlock(largeFontSize: 32)

            Spacer(minLength: 4)

            if let totals = entry.snapshot?.hourlyTotals, !totals.isEmpty {
                MiniBarChart(values: totals,
                             highlightedRange: highlightedRange,
                             midnightIndices: midnightIndices)
                    .frame(height: 28)
            } else if let snap = entry.snapshot, let start = snap.cheapestStart {
                Text(cheapestHeader)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(start, format: WidgetFormat.hourMinute24)
                    .font(.callout.bold())
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var mediumView: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                priceBlock(largeFontSize: 36)
                Spacer()
                cheapestBlock
            }

            if let totals = entry.snapshot?.hourlyTotals, !totals.isEmpty {
                MiniBarChart(values: totals,
                             highlightedRange: highlightedRange,
                             midnightIndices: midnightIndices)
                    .frame(height: 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Top-left price block, shared by small + medium families.
    func priceBlock(largeFontSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Börsihind")
                .textCase(.uppercase)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(WidgetFormat.price(entry.snapshot?.currentTotal, locale: locale))
                .font(.system(size: largeFontSize, weight: .bold))
                .monospacedDigit()
            Text("c/kWh")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Top-right "Cheapest Nh" block (medium family only).
    var cheapestBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cheapestHeader)
                .textCase(.uppercase)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let snap = entry.snapshot,
               let start = snap.cheapestStart,
               let avg = snap.cheapestAverage {
                Text(start, format: WidgetFormat.hourMinute24)
                    .font(.title2.bold())
                    .monospacedDigit()
                Text("\(WidgetFormat.price(avg, locale: locale)) c/kWh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("—").font(.title2.bold())
            }
        }
    }
}

// MARK: - Computed labels

private extension CurrentPriceWidgetView {

    /// "Cheapest Nh" / "Odavaim Nh" — N from the user's selected window
    /// in the main app (1/2/3/4). Falls back to 1h.
    var cheapestHeader: String {
        let n = entry.snapshot?.cheapestHours ?? 1
        return locale.t("Cheapest %@h").replacingOccurrences(of: "%@", with: String(n))
    }

    /// `hourlyTotals` indices covered by the selected cheapest window.
    /// Drives the green highlight on the mini chart. Nil when the
    /// window doesn't fall within the visible 24-hour horizon.
    var highlightedRange: ClosedRange<Int>? {
        guard let snap = entry.snapshot,
              let start = snap.cheapestHighlightStart,
              !snap.hourlyTotals.isEmpty
        else { return nil }
        let end = start + max(snap.cheapestHours, 1) - 1
        return start...min(end, snap.hourlyTotals.count - 1)
    }

    /// `hourlyTotals` indices at 00:00 — drives the day-divider line in
    /// the mini chart. Index 0 is excluded (nothing to divide from).
    var midnightIndices: Set<Int> {
        guard let snap = entry.snapshot,
              let start = snap.hourlyStart,
              !snap.hourlyTotals.isEmpty
        else { return [] }
        let cal = Calendar.current
        var out: Set<Int> = []
        for i in 1..<snap.hourlyTotals.count {
            let date = start.addingTimeInterval(TimeInterval(i) * 3600)
            if cal.component(.hour, from: date) == 0 {
                out.insert(i)
            }
        }
        return out
    }
}

// MARK: - Formatting

/// Stateless formatting helpers. `enum` rather than `struct` so it's
/// clearly a namespace, not an instantiable type.
private enum WidgetFormat {
    /// "24,62" / "24.62" with placeholder. Locale picks the separator.
    static func price(_ value: Double?, locale: Locale = .current) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(2)).locale(locale))
    }

    /// Whole-number rounded — for tight spaces (circular complication).
    static func integer(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))"
    }

    /// 24-hour HH:mm regardless of locale (matches the main app).
    static let hourMinute24 = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: .current,
        calendar: .current
    )
}

// MARK: - Mini bar chart

/// Compact bar chart for the widget. One thin bar per hourly total,
/// height proportional to value vs. series max. Bars use `.primary` so
/// they adapt to light, dark, AND iOS tinted Home Screen modes —
/// cheapest-window bars at 35% opacity read as "faded" against the rest.
/// (Green disappears under iOS's tinted filter, so we don't use it.)
private struct MiniBarChart: View {
    let values: [Double]
    let highlightedRange: ClosedRange<Int>?
    /// Indices with a thin day-divider drawn to their left.
    let midnightIndices: Set<Int>

    var body: some View {
        GeometryReader { geo in
            let maxValue = values.max() ?? 1
            let count = max(values.count, 1)
            let barWidth = max(1, (geo.size.width - CGFloat(count - 1)) / CGFloat(count))

            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(values.indices, id: \.self) { i in
                        let ratio = maxValue > 0 ? CGFloat(values[i] / maxValue) : 0
                        let isHighlighted = highlightedRange?.contains(i) == true
                        Rectangle()
                            .fill(Color.primary.opacity(isHighlighted ? 0.35 : 1))
                            .frame(width: barWidth, height: max(2, geo.size.height * ratio))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                // Day dividers drawn in a separate layer so they span the
                // full chart height regardless of the adjacent bar height.
                ForEach(Array(midnightIndices), id: \.self) { i in
                    Rectangle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 1, height: geo.size.height)
                        .offset(x: CGFloat(i) * (barWidth + 1) - 1)
                }
            }
        }
    }
}
