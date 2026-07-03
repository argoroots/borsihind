import WidgetKit
import SwiftUI

/// watchOS complication. Reads the snapshot the Watch app publishes to the
/// App Group (`group.ee.borsihind`) — no network or StoreKit here. Self-
/// advances one entry per upcoming slot so the price stays current between
/// Watch-app refreshes. Mirrors the Watch app's view (price shown to all
/// users), so no subscription gate.
///
/// Type names mirror the iOS widget (`CurrentPriceWidget`,
/// `PriceTimelineEntry`, `PriceProvider`, `CurrentPriceWidgetView`) so the
/// same role has the same name across both extensions.
@main
struct BorsihindWidgetBundle: WidgetBundle {
    var body: some Widget { CurrentPriceWidget() }
}

struct CurrentPriceWidget: Widget {
    let kind = "CurrentPriceWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PriceProvider()) { entry in
            CurrentPriceWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Börsihind")
        .description("Hetkehind ja odavaim tund.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular,
                            .accessoryInline, .accessoryCorner])
    }
}

// MARK: - Timeline

struct PriceTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedStorage.Snapshot?
}

struct PriceProvider: TimelineProvider {
    func placeholder(in context: Context) -> PriceTimelineEntry {
        PriceTimelineEntry(date: Date(), snapshot: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (PriceTimelineEntry) -> Void) {
        completion(PriceTimelineEntry(date: Date(), snapshot: SharedStorage.readSnapshot()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PriceTimelineEntry>) -> Void) {
        Task {
            let now = Date()
            var snap = SharedStorage.readSnapshot()
            // Refresh the snapshot ourselves when it's stale or running out of
            // data — covers gaps where the Watch app hasn't run recently.
            if SharedStorage.Snapshot.shouldRefresh(snap, at: now),
               let refreshed = await SharedStorage.Snapshot.refresh(from: snap) {
                snap = refreshed
                SharedStorage.writeSnapshot(refreshed)
            }

            guard let snap, !snap.slotTotals.isEmpty else {
                let entry = PriceTimelineEntry(date: now, snapshot: nil)
                completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(30 * 60))))
                return
            }
            // Self-advancing entries — boundary math shared with the iOS widget.
            let timeline = snap.timelineDates(after: now)
            let entries = timeline.dates.map { PriceTimelineEntry(date: $0, snapshot: snap) }
            completion(Timeline(entries: entries, policy: .after(timeline.refreshAfter)))
        }
    }
}

// MARK: - Root view

struct CurrentPriceWidgetView: View {
    let entry: PriceTimelineEntry
    @Environment(\.widgetFamily) private var family

    @AppStorage("language", store: .shared) private var languageRaw = Language.et.rawValue
    private var locale: Locale { (Language(rawValue: languageRaw) ?? .et).locale }

    // Current price + cheapest window via the shared `Snapshot` helpers —
    // same derivation the iOS widget and app use.
    private var priceForEntry: Double? { entry.snapshot?.price(at: entry.date) }
    private var cheapestForEntry: PriceCompute.WindowResult? {
        entry.snapshot?.cheapestWindow(at: entry.date)
    }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangularView
        case .accessoryInline:      inlineView
        case .accessoryCorner:      cornerView
        default:                    circularView
        }
    }

    // Locale price string / whole cents, "—" when no data. Shared
    // `Double.priceString` / `centsString` — same names as the iOS widget.
    private func priceString(_ value: Double?) -> String {
        value?.priceString(locale: locale) ?? "—"
    }
    private func cents(_ value: Double?) -> String { value?.centsString ?? "—" }

    private var cheapestHeader: String {
        locale.t("Cheapest %@h")
            .replacingOccurrences(of: "%@", with: String(entry.snapshot?.cheapestHours ?? 1))
    }

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(cents(priceForEntry)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                Text(locale.t("c/kWh")).font(.system(size: 9))
            }
        }
    }
    private var cornerView: some View {
        Text(cents(priceForEntry)).font(.system(size: 18, weight: .bold)).monospacedDigit()
            .widgetCurvesContent()
            .widgetLabel(locale.t("c/kWh"))
    }
    private var inlineView: some View {
        Text(priceForEntry == nil ? "Börsihind" : "\(priceString(priceForEntry)) \(locale.t("c/kWh"))")
    }
    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Börsihind").font(.caption2.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(priceString(priceForEntry)).font(.headline.bold()).monospacedDigit()
                Text(locale.t("c/kWh")).font(.caption2)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            if let cheapest = cheapestForEntry {
                Text("\(cheapestHeader): \(cheapest.start, format: Date.VerbatimFormatStyle.hourMinute24)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}
