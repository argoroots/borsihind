import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

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

        /// Settings the widget needs to refresh itself when the host app is
        /// closed (mainly on macOS, where there's no `BGAppRefreshTask`).
        /// Optional so older snapshots still decode after migration.
        let planRaw: String?
        let intervalRaw: String?
        let marginal: Double?
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

    /// Publish a fresh snapshot + subscription state and nudge WidgetKit to
    /// reload all widget/complication timelines. The single recipe shared by
    /// the iPhone/Mac app, the watch app, and the background-refresh handler.
    @MainActor
    static func publish(snapshot: Snapshot?, isSubscribed: Bool) {
        Self.isSubscribed = isSubscribed
        if let snapshot { writeSnapshot(snapshot) }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
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

    /// Convenience init that folds margin into per-slot totals and stamps
    /// `writtenAt` to `Date()`. Shared by `PricesViewModel.snapshot(…)` and
    /// the widget/complication self-refresh path.
    init?(prices: [PriceEntry], hourly: [PriceEntry],
          plan: Plan, interval: Interval, marginal: Double,
          cheapestHours: Int, selectedSlotDeadline: Int) {
        guard let first = prices.first else { return nil }
        self.init(
            slotTotals: prices.map { $0.total(withMargin: marginal) },
            slotStart: first.date,
            slotMinutes: interval.minutes,
            cheapestHours: cheapestHours,
            selectedSlotDeadline: selectedSlotDeadline,
            hourlyTotals: hourly.map { $0.total(withMargin: marginal) },
            hourlyStart: hourly.first?.date ?? first.date,
            writtenAt: Date(),
            planRaw: plan.rawValue,
            intervalRaw: interval.rawValue,
            marginal: marginal
        )
    }

    /// `true` when the snapshot is missing, > 3 h old, or has < 1 h of
    /// future slot data left — i.e. the extensions should refetch.
    static func shouldRefresh(_ snap: SharedStorage.Snapshot?, at now: Date) -> Bool {
        guard let snap, !snap.slotTotals.isEmpty else { return true }
        if now.timeIntervalSince(snap.writtenAt) > 3 * 3600 { return true }
        let slotDuration = TimeInterval(snap.slotMinutes * 60)
        let lastSlotEnd = snap.slotStart.addingTimeInterval(TimeInterval(snap.slotTotals.count) * slotDuration)
        return lastSlotEnd < now.addingTimeInterval(3600)
    }

    /// Fetch fresh prices and rebuild the snapshot from the settings carried
    /// on `old`, preserving the cheapest-window selection. Returns nil when
    /// the settings are missing (older snapshot) or the fetch fails.
    static func refresh(from old: SharedStorage.Snapshot?) async -> SharedStorage.Snapshot? {
        guard let old,
              let planRaw = old.planRaw, let plan = Plan(rawValue: planRaw),
              let intervalRaw = old.intervalRaw, let interval = Interval(rawValue: intervalRaw),
              let marginal = old.marginal
        else { return nil }
        let service = PriceService()
        do {
            async let primary = service.fetchPrices(plan: plan, interval: interval)
            let prices: [PriceEntry]
            let hourly: [PriceEntry]
            if interval == .oneHour {
                prices = try await primary
                hourly = prices
            } else {
                async let hourlyFetch = service.fetchPrices(plan: plan, interval: .oneHour)
                prices = try await primary
                hourly = (try? await hourlyFetch) ?? []
            }
            return SharedStorage.Snapshot(
                prices: prices, hourly: hourly,
                plan: plan, interval: interval, marginal: marginal,
                cheapestHours: old.cheapestHours,
                selectedSlotDeadline: old.selectedSlotDeadline
            )
        } catch {
            return nil
        }
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
