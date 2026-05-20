import Foundation
import Observation
import WidgetKit

/// One chartable price point for the watch graph (date + total).
struct WatchPricePoint: Identifiable {
    let date: Date
    let total: Double
    var id: Date { date }
}

/// Thin watch wrapper around the shared `PricesViewModel`. Fetches the
/// JSON itself and exposes the current price + cheapest windows for
/// the current `SyncedState`.
@Observable
@MainActor
final class WatchPricesModel {
    private let vm = PricesViewModel()

    var isLoading: Bool { vm.isLoading }
    var hasData: Bool { !vm.prices.isEmpty }
    /// A genuine fetch failure (not a cancellation). Surfaces the
    /// offline/error page when there's no data to fall back on.
    var hasError: Bool { vm.errorMessage != nil }

    /// Force-fetch for the synced settings (applying premium gating),
    /// then publish a snapshot so the complication can render it. Used by
    /// pull-to-refresh, retry, and settings changes.
    func refresh(for state: SyncedState) async {
        await vm.load(plan: state.plan, interval: state.effectiveInterval)
        publishSnapshot(for: state)
    }

    /// Fetch only when data is stale (≥ 3 h) or absent — used on glance
    /// so opening the app repeatedly doesn't re-hit the network.
    func refreshIfStale(for state: SyncedState) async {
        let didLoad = await vm.loadIfStale(plan: state.plan,
                                           interval: state.effectiveInterval)
        if didLoad { publishSnapshot(for: state) }
    }

    /// Write the latest snapshot to the watch's App Group container and
    /// nudge WidgetKit to reload the complication. No-ops gracefully
    /// until the `group.ee.borsihind` entitlement is granted to the
    /// watch app + complication extension.
    func publishSnapshot(for state: SyncedState) {
        SharedStorage.isSubscribed = state.isSubscribed
        if let snap = vm.snapshot(slots: state.effectiveSlots,
                                  selectedSlotID: state.selectedSlot,
                                  marginal: state.effectiveMargin) {
            SharedStorage.writeSnapshot(snap)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Re-filter past slots without re-fetching.
    func tick() { vm.bumpNow() }

    /// Current slot's total price (component sum + margin).
    func currentTotal(for state: SyncedState) -> Double? {
        guard let bar = vm.prices.first else { return nil }
        return bar.total(withMargin: state.effectiveMargin)
    }

    /// Current slot's time range.
    func currentRange(for state: SyncedState) -> (start: Date, end: Date)? {
        guard let bar = vm.prices.first else { return nil }
        let end = bar.date.addingTimeInterval(TimeInterval(state.effectiveInterval.minutes * 60))
        return (bar.date, end)
    }

    /// Cheapest windows for the synced slot config.
    func windows(for state: SyncedState) -> [LowestWindow] {
        vm.lowestWindows(interval: state.effectiveInterval,
                         marginal: state.effectiveMargin,
                         slots: state.effectiveSlots)
    }

    /// Upcoming slots as chartable points (date + fully-loaded total).
    func series(for state: SyncedState) -> [WatchPricePoint] {
        vm.prices.map {
            WatchPricePoint(date: $0.date, total: $0.total(withMargin: state.effectiveMargin))
        }
    }

    /// `series` index range of the selected cheapest window (falls back
    /// to the first), used to highlight those bars on the graph.
    func selectedWindowRange(for state: SyncedState) -> ClosedRange<Int>? {
        let windows = windows(for: state)
        let selected = windows.first { $0.slotIndex == state.selectedSlot } ?? windows.first
        guard let window = selected else { return nil }
        return window.startIndex...window.endIndex
    }
}
