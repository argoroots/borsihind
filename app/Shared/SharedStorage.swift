import Foundation

/// App Group bridge between the main app and the widget extension.
/// Both targets need the `group.ee.borsihind` entitlement.
enum SharedStorage {
    static let appGroupID = "group.ee.borsihind"

    private static let snapshotKey = "widget.snapshot.v5"
    private static let isSubscribedKey = "widget.isSubscribed.v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Everything the widget needs to render. JSON-encoded so the
    /// schema can evolve without per-key migrations.
    struct Snapshot: Codable, Hashable, Sendable {
        /// Slot totals at the user's interval (15-min or 1-h),
        /// margin + VAT folded in. Drives current price and cheapest math.
        let slotTotals: [Double]
        let slotStart: Date
        /// 15 or 60. Maps `entry.date` to a `slotTotals` index.
        let slotMinutes: Int

        /// User-selected window length (1...6 hours).
        let cheapestHours: Int
        /// "Must end before" hour-of-day (-1 = off, 0...23 = hour).
        let selectedSlotDeadline: Int

        /// Hour-aggregated totals for the mini bar chart only.
        let hourlyTotals: [Double]
        let hourlyStart: Date

        /// Snapshot write time. Used for staleness checks.
        let writtenAt: Date
    }

    static func writeSnapshot(_ snapshot: Snapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func readSnapshot() -> Snapshot? {
        guard let defaults,
              let data = defaults.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }
        return snap
    }

    /// Mirrors `StoreManager.isSubscribed` so the widget can gate the
    /// premium UI without re-running StoreKit in the extension.
    static var isSubscribed: Bool {
        get { defaults?.bool(forKey: isSubscribedKey) ?? false }
        set { defaults?.set(newValue, forKey: isSubscribedKey) }
    }
}
