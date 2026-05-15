import Foundation

/// Bridges the main app and the widget extension via an App Group.
/// Both targets need the `group.ee.borsihind` entitlement enabled
/// for the shared `UserDefaults` to be readable from the widget process.
enum SharedStorage {
    static let appGroupID = "group.ee.borsihind"

    /// Versioned to v3 when the cheapest-window fields became
    /// user-selectable (1h/2h/3h/4h). Older snapshots are simply ignored.
    private static let snapshotKey = "widget.snapshot.v3"
    private static let isSubscribedKey = "widget.isSubscribed.v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Snapshot of "what does the widget need to show right now".
    /// JSON-encoded so the schema can evolve without per-key migrations.
    struct Snapshot: Codable, Hashable, Sendable {
        /// Total c/kWh including margin + VAT.
        let currentTotal: Double
        let currentStart: Date
        /// Slot end (= start + interval minutes).
        let currentEnd: Date
        /// User-selected cheapest-window length (1/2/3/4). Free users
        /// always see 1.
        let cheapestHours: Int
        let cheapestStart: Date?
        /// c/kWh average for the cheapest window (incl. margin + VAT).
        let cheapestAverage: Double?
        /// Hour-aggregated totals for the next ~24h, oldest first.
        /// Already includes margin + VAT.
        let hourlyTotals: [Double]
        /// Start time of `hourlyTotals[0]`. Drives the chart axis.
        let hourlyStart: Date?
        /// Index into `hourlyTotals` where the user's selected cheapest
        /// window begins. Nil when the window falls outside the visible
        /// 24-hour horizon.
        let cheapestHighlightStart: Int?
        /// Stale threshold: widget treats anything older than ~90 min
        /// as missing data.
        let writtenAt: Date
    }

    /// Write the latest snapshot. Called from the main app whenever
    /// prices or selection state change.
    static func writeSnapshot(_ snapshot: Snapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    /// Read the latest snapshot, or nil if missing / unreadable.
    static func readSnapshot() -> Snapshot? {
        guard let defaults,
              let data = defaults.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }
        return snap
    }

    /// Mirrors `StoreManager.isSubscribed` so the widget can render the
    /// premium-vs-free state without re-running StoreKit in the extension.
    static var isSubscribed: Bool {
        get { defaults?.bool(forKey: isSubscribedKey) ?? false }
        set { defaults?.set(newValue, forKey: isSubscribedKey) }
    }
}
