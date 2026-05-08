import WidgetKit
import SwiftUI

/// Glanceable current-price widget. Reads pre-computed snapshots written
/// by the main app to the App Group — no network or StoreKit calls in the
/// widget process. Refreshes when the app re-writes the snapshot, plus
/// once per slot end via the timeline policy.
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
        // Lock-screen / Watch accessory families exist only on iOS / iPadOS.
        // macOS desktop widgets get the system small/medium sizes.
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
    /// Mirrors `StoreManager.isSubscribed` from the main app — used to gate
    /// the widget content behind the Börsihind+ paywall.
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
        // Refresh once at the current slot's end so the visible price flips
        // at the slot boundary, or every 30 minutes if no snapshot exists.
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

    /// Read the user's app language from the shared App Group store —
    /// same pattern as `PaywallView` / `SettingsView`. The widget process
    /// has its own UserDefaults.standard, so without `store: .shared` it
    /// would always see the default value.
    @AppStorage("language", store: .shared) private var languageRaw: String = Language.et.rawValue

    private var locale: Locale {
        (Language(rawValue: languageRaw) ?? .et).locale
    }

    var body: some View {
        Group {
            if entry.isSubscribed {
                // Subscriber: full widget content per family.
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
                // Free user: show a Börsihind+ upgrade card. Tapping the
                // widget deep-links into the paywall via the `widgetURL`
                // below.
                lockedView
            }
        }
        .widgetURL(URL(string: "borsihind://paywall"))
    }

    /// Shown to non-subscribers in every family. Compact wordmark + lock
    /// glyph so it reads as "this is a paid feature" rather than a broken
    /// widget. Layout adapts loosely to family without per-family branches.
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

    /// One-line label.
    var inlineView: some View {
        Group {
            if let snap = entry.snapshot {
                Text("\(WidgetFormat.price(snap.currentTotal)) c/kWh")
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

    /// Rectangular complication.
    var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Börsihind").font(.caption2.weight(.semibold))
            HStack(alignment: .firstTextBaseline) {
                Text(WidgetFormat.price(entry.snapshot?.currentTotal))
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

    /// Home Screen small.
    var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            priceBlock(largeFontSize: 32)

            Spacer(minLength: 4)

            if let totals = entry.snapshot?.hourlyTotals, !totals.isEmpty {
                MiniBarChart(values: totals, highlightedRange: highlightedRange)
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

    /// Home Screen medium.
    var mediumView: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                priceBlock(largeFontSize: 36)
                Spacer()
                cheapestBlock
            }

            if let totals = entry.snapshot?.hourlyTotals, !totals.isEmpty {
                MiniBarChart(values: totals, highlightedRange: highlightedRange)
                    .frame(height: 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Top-left price block — shared by small and medium.
    func priceBlock(largeFontSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Börsihind")
                .textCase(.uppercase)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(WidgetFormat.price(entry.snapshot?.currentTotal))
                .font(.system(size: largeFontSize, weight: .bold))
                .monospacedDigit()
            Text("c/kWh")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Top-right "Odavaim Nh" block — medium widget only.
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
                Text("\(WidgetFormat.price(avg)) c/kWh")
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

    /// "Odavaim Nh" / "Cheapest Nh" — N comes from the user's selected
    /// window in the main app (1/2/3/4). Falls back to 1h.
    var cheapestHeader: String {
        let n = entry.snapshot?.cheapestHours ?? 1
        return locale.t("Cheapest %@h").replacingOccurrences(of: "%@", with: String(n))
    }

    /// Indices in `hourlyTotals` that the user's selected cheapest window
    /// covers. Drives the green highlight on the mini bar chart. `nil`
    /// when the window doesn't fall inside the visible 24-hour horizon.
    var highlightedRange: ClosedRange<Int>? {
        guard let snap = entry.snapshot,
              let start = snap.cheapestHighlightStart,
              !snap.hourlyTotals.isEmpty
        else { return nil }
        let end = start + max(snap.cheapestHours, 1) - 1
        return start...min(end, snap.hourlyTotals.count - 1)
    }
}

// MARK: - Formatting

/// Stateless formatting helpers. `enum` rather than `struct` so it's clear
/// these are namespace-only — no instances are ever created.
private enum WidgetFormat {
    /// "24.62" with optional placeholder.
    static func price(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(2)))
    }

    /// Whole-number rounded for tight spaces.
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

/// Compact bar chart for the widget. One thin bar per hourly total at a
/// height proportional to that hour's value vs. the series max. All bars
/// use `.primary` so they adapt to light, dark, AND iOS tinted-Home-Screen
/// modes — non-cheapest bars at full opacity, cheapest-window bars at 35%
/// so they read as "faded" against the rest. (Earlier iterations used
/// green, but green disappears under iOS's tinted Home Screen filter.)
private struct MiniBarChart: View {
    let values: [Double]
    let highlightedRange: ClosedRange<Int>?

    var body: some View {
        GeometryReader { geo in
            let maxValue = values.max() ?? 1
            let count = max(values.count, 1)
            let barWidth = max(1, (geo.size.width - CGFloat(count - 1)) / CGFloat(count))

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
        }
    }
}
