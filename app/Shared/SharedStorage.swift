import Foundation

/// Bridge between the main app and the widget extension. Both targets need
/// the App Group `group.ee.borsihind` entitlement enabled in Xcode for the
/// shared `UserDefaults` to be readable from the widget process.
enum SharedStorage {
    static let appGroupID = "group.ee.borsihind"

    /// Bumped to v3 when the cheapest-window fields became user-selectable
    /// (1h / 2h / 3h / 4h). Older snapshots under v1/v2 are ignored
    /// automatically since the widget only reads the current key.
    private static let snapshotKey = "widget.snapshot.v3"
    private static let isSubscribedKey = "widget.isSubscribed.v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// One-shot snapshot of "what does the user need to see in the widget
    /// right now". Encoded as JSON so we can evolve the schema without
    /// migrating bare UserDefaults keys.
    struct Snapshot: Codable, Hashable, Sendable {
        /// Total c/kWh including margin and VAT.
        let currentTotal: Double
        /// Slot start.
        let currentStart: Date
        /// Slot end (start + interval minutes).
        let currentEnd: Date
        /// Hour count of the user's selected cheapest window (1/2/3/4).
        /// Free users always get 1; premium users see their pick from the
        /// main app. Falls back to 1 when nothing is selected.
        let cheapestHours: Int
        /// Selected cheapest window's start time.
        let cheapestStart: Date?
        /// Selected cheapest window's average c/kWh (margin + VAT included).
        let cheapestAverage: Double?
        /// Hour-aggregated total c/kWh for the next ~24 hours, oldest first.
        /// Already includes margin + VAT, so it matches what the main app
        /// shows as the per-hour price.
        let hourlyTotals: [Double]
        /// Start time of `hourlyTotals[0]`. Used for chart axis labels.
        let hourlyStart: Date?
        /// Index into `hourlyTotals` where the user's selected cheapest
        /// window begins. The widget highlights `cheapestHours` bars
        /// starting from this index. `nil` if the window doesn't fall
        /// within the visible 24-hour horizon.
        let cheapestHighlightStart: Int?
        /// When the snapshot was written. Widget treats anything older than
        /// 90 minutes as stale and shows a "no data" placeholder.
        let writtenAt: Date
    }

    /// Write the latest snapshot. Called from the main app whenever prices
    /// or selection state change.
    static func writeSnapshot(_ snapshot: Snapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    /// Read the latest snapshot. Returns nil when none has been written or
    /// the encoded payload is unreadable.
    static func readSnapshot() -> Snapshot? {
        guard let defaults,
              let data = defaults.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }
        return snap
    }

    /// Mirrors `StoreManager.isSubscribed` so the widget can render a
    /// premium-vs-free state without re-running StoreKit in the extension.
    static var isSubscribed: Bool {
        get { defaults?.bool(forKey: isSubscribedKey) ?? false }
        set { defaults?.set(newValue, forKey: isSubscribedKey) }
    }
}
