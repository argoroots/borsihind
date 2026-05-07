import Foundation
import Observation

/// Owns the price data and derived state for the screen. Fetches once and
/// then recomputes the visible window every minute via `now`, so the chart
/// rolls forward without hitting the network. Auto-refresh re-fetches every
/// 15 minutes (matching the upstream publish cadence).
@Observable
@MainActor
final class PricesViewModel {
    /// Entire price file as fetched. Filtering happens in `prices` so the
    /// visible window can advance minute-by-minute without re-fetching.
    private(set) var rawPrices: [PriceEntry] = []
    /// Tick that drives the per-minute filter recomputation.
    private(set) var now: Date = Date()
    /// Slot length used by the current view (set by the latest `load`).
    private(set) var currentInterval: Interval = .fifteenMin

    var isLoading = false
    var errorMessage: String?

    private let service = PriceService()
    private var refreshTask: Task<Void, Never>?
    private var minuteTask: Task<Void, Never>?

    /// Slots whose start is at or after the rounded-down current slot.
    /// Recomputes whenever `rawPrices`, `now`, or `currentInterval` changes.
    var prices: [PriceEntry] {
        let cutoff = Self.currentSlotStart(interval: currentInterval, now: now)
        return rawPrices.filter { $0.date >= cutoff }
    }

    func load(plan: Plan, interval: Interval) async {
        currentInterval = interval
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            rawPrices = try await service.fetchPrices(plan: plan, interval: interval)
            now = Date()
        } catch {
            errorMessage = "load_failed"
        }
    }

    /// Background loop: refetches the price file from S3 every 15 minutes.
    func startAutoRefresh(plan: @escaping () -> Plan, interval: @escaping () -> Interval) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                if Task.isCancelled { break }
                await self?.load(plan: plan(), interval: interval())
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Once-a-minute tick that bumps `now`. Cheap — just refilters in memory,
    /// causing the chart and cheapest-windows to drop slots as they end.
    func startMinuteTicker() {
        minuteTask?.cancel()
        minuteTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                self?.now = Date()
            }
        }
    }

    func stopMinuteTicker() {
        minuteTask?.cancel()
        minuteTask = nil
    }

    /// Round "now" down to the start of the current interval slot.
    private static func currentSlotStart(interval: Interval, now: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        if interval == .fifteenMin, let m = comps.minute {
            comps.minute = (m / 15) * 15
        } else {
            comps.minute = 0
        }
        return cal.date(from: comps) ?? now
    }

    /// Average price (component sum + marginal) of running an N-hour load
    /// starting RIGHT NOW — i.e. the first `hours * slotsPerHour` visible
    /// slots. Used as the baseline for the "% cheaper" badge in cheapest-
    /// hours cards: comparing apples-to-apples (N-hour avg vs N-hour avg).
    /// Returns nil if there isn't a full N-hour run available from now.
    func nowAverage(forHours hours: Int, interval: Interval, marginal: Double) -> Double? {
        let span = hours * interval.slotsPerHour
        let head = prices.prefix(span)
        guard head.count == span, span > 0 else { return nil }
        let sum = head.reduce(0.0) { $0 + $1.componentSum + marginal }
        return sum / Double(span)
    }

    /// Direct port of findLowestTimeSpan from src/App.vue:228-267.
    /// Returns 1h/2h/3h/4h cheapest windows including the marginal.
    func lowestWindows(interval: Interval, marginal: Double) -> [LowestWindow] {
        let visible = prices
        guard !visible.isEmpty else { return [] }
        let multiplier = interval.slotsPerHour
        return [1, 2, 3, 4].compactMap { hours in
            findLowest(in: visible, span: hours * multiplier,
                       hours: hours, interval: interval, marginal: marginal)
        }
    }

    private func findLowest(in visible: [PriceEntry], span: Int, hours: Int,
                            interval: Interval, marginal: Double) -> LowestWindow? {
        guard visible.count >= span, span > 0 else { return nil }
        let sums = visible.map { $0.componentSum + marginal }

        var lowestSum = Double.infinity
        var lowestIdx = -1
        for i in 0...(sums.count - span) {
            var s = 0.0
            for j in 0..<span { s += sums[i + j] }
            if s < lowestSum {
                lowestSum = s
                lowestIdx = i
            }
        }
        guard lowestIdx >= 0 else { return nil }

        let startEntry = visible[lowestIdx]
        let endEntry = visible[lowestIdx + span - 1]
        let endDate = endEntry.date.addingTimeInterval(TimeInterval(interval.minutes * 60))

        return LowestWindow(
            hours: hours,
            startIndex: lowestIdx,
            endIndex: lowestIdx + span - 1,
            start: startEntry.date,
            end: endDate,
            averagePrice: lowestSum / Double(span)
        )
    }
}
