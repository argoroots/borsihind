import Foundation

/// App Group bridge between the app and its extensions (widget +
/// watch complication). Every participating target needs the
/// `group.ee.borsihind` entitlement.
enum SharedStorage {
    static let appGroupID = "group.ee.borsihind"

    private static let snapshotKey = "widget.snapshot.v5"
    private static let isSubscribedKey = "widget.isSubscribed.v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Everything a widget or complication needs to render. JSON-encoded
    /// so the schema can evolve without per-key migrations.
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

    /// Mirrors `StoreManager.isSubscribed` so extensions can gate the
    /// premium UI without re-running StoreKit out of process.
    static var isSubscribed: Bool {
        get { defaults?.bool(forKey: isSubscribedKey) ?? false }
        set { defaults?.set(newValue, forKey: isSubscribedKey) }
    }
}

// MARK: - Snapshot rendering helpers

/// Derivations shared by the iOS widget and the watch complication, so
/// both read the current price, cheapest window, and timeline boundaries
/// from one implementation (same `PriceCompute` math the app uses).
extension SharedStorage.Snapshot {
    /// `slotTotals` index containing `date`, or `nil` if out of range.
    func slotIndex(at date: Date) -> Int? {
        guard !slotTotals.isEmpty else { return nil }
        let i = Int(date.timeIntervalSince(slotStart) / TimeInterval(slotMinutes * 60))
        return slotTotals.indices.contains(i) ? i : nil
    }

    /// Fully-loaded price (margin + VAT folded in) for the slot at `date`.
    func price(at date: Date) -> Double? {
        guard !slotTotals.isEmpty else { return nil }
        return slotTotals[slotIndex(at: date) ?? 0]
    }

    /// Cheapest selected-length window starting at or after `date`,
    /// honouring the "must end before" deadline.
    func cheapestWindow(at date: Date) -> PriceCompute.WindowResult? {
        guard !slotTotals.isEmpty else { return nil }
        let slotsPerHour = max(60 / slotMinutes, 1)
        let series = PriceCompute.SlotSeries(
            totals: slotTotals,
            baseDate: slotStart,
            slotDuration: TimeInterval(slotMinutes * 60)
        )
        return PriceCompute.cheapestWindow(
            in: series,
            spanSlots: max(cheapestHours, 1) * slotsPerHour,
            fromIndex: max(slotIndex(at: date) ?? 0, 0),
            deadlineEnd: PriceCompute.nextOccurrence(ofHour: selectedSlotDeadline, after: date)
        )
    }

    /// Entry dates for a self-advancing timeline — `now` plus every
    /// upcoming slot boundary — and the policy refresh date one slot past
    /// the last entry. Lets the widget/complication re-render at each slot
    /// without waiting on the app or a background task.
    func timelineDates(after now: Date) -> (dates: [Date], refreshAfter: Date) {
        let slotDuration = TimeInterval(slotMinutes * 60)
        var dates = [now]
        for i in slotTotals.indices {
            let start = slotStart.addingTimeInterval(TimeInterval(i) * slotDuration)
            if start > now { dates.append(start) }
        }
        return (dates, (dates.last ?? now).addingTimeInterval(slotDuration))
    }
}
