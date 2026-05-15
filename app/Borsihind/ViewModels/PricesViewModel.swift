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
    private var minuteTask: Task<Void, Never>?
    /// Most recent rounded slot start the ticker observed. When this
    /// changes between ticks, we've crossed a slot boundary and notify
    /// the host (which triggers a `refreshAll(...)` so prices, snapshot,
    /// and notifications all update at exactly the right moment).
    private var lastSlotStart: Date?

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

    /// Once-a-minute tick that bumps `now`. Cheap — just refilters in
    /// memory, causing the chart and cheapest-windows to drop slots as
    /// they end. When the rounded slot start changes between ticks
    /// (i.e. a new 15-min or 1-h slot has just begun, matching the
    /// user's interval), invoke `onSlotBoundary` so the host can run
    /// the full refresh pipeline (network fetch + widget snapshot +
    /// notification reschedule).
    func startMinuteTicker(onSlotBoundary: (@MainActor () -> Void)? = nil) {
        minuteTask?.cancel()
        lastSlotStart = Self.currentSlotStart(interval: currentInterval, now: now)
        minuteTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                guard let self else { return }
                let newNow = Date()
                self.now = newNow
                let newSlot = Self.currentSlotStart(interval: self.currentInterval, now: newNow)
                if self.lastSlotStart != newSlot {
                    self.lastSlotStart = newSlot
                    onSlotBoundary?()
                }
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

    /// Per-slot cheapest windows in the visible (future) data, with the
    /// seller margin folded into each slot's price. Returns one
    /// `LowestWindow` per input slot (in order). A slot whose deadline
    /// can't be satisfied falls back to the unconstrained cheapest window
    /// and surfaces `missedDeadline` so the UI can warn the user.
    ///
    /// Each slot's `deadline` is a "must end before" hour of day (1...23),
    /// or `0` for no constraint. Interpreted as the *next* occurrence of
    /// that hour-of-day relative to `now` (so 07:00 at 22:00 means tomorrow
    /// 07:00, not this morning 07:00 which is already past).
    func lowestWindows(interval: Interval, marginal: Double,
                       slots: [CheapestSlot]) -> [LowestWindow] {
        let visible = prices
        guard !visible.isEmpty else { return [] }
        let multiplier = interval.slotsPerHour
        return slots.compactMap { slot in
            // hours == 0 means the user turned the slot off — no card.
            guard slot.hours > 0 else { return nil }
            return findLowest(in: visible, span: slot.hours * multiplier,
                              slotIndex: slot.id, hours: slot.hours, interval: interval,
                              marginal: marginal,
                              deadlineEnd: deadlineDate(forHour: slot.deadline))
        }
    }

    /// Resolve a deadline hour-of-day to an absolute `Date` — the next
    /// occurrence of HH:00 at or after `now`. Returns nil when the hour
    /// is 0 (off) or out of range.
    private func deadlineDate(forHour hour: Int) -> Date? {
        guard (1...23).contains(hour) else { return nil }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        guard var target = cal.date(from: comps) else { return nil }
        if target <= now {
            target = cal.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return target
    }

    private func findLowest(in visible: [PriceEntry], span: Int,
                            slotIndex: Int, hours: Int,
                            interval: Interval, marginal: Double,
                            deadlineEnd: Date?) -> LowestWindow? {
        guard visible.count >= span, span > 0 else { return nil }
        let sums = visible.map { $0.componentSum + marginal }
        let slotSeconds = TimeInterval(interval.minutes * 60)

        // First pass: cheapest window that respects the deadline (if any).
        var lowestSum = Double.infinity
        var lowestIdx = -1
        if let deadline = deadlineEnd {
            for i in 0...(sums.count - span) {
                let endDate = visible[i + span - 1].date.addingTimeInterval(slotSeconds)
                if endDate > deadline { continue }
                var s = 0.0
                for j in 0..<span { s += sums[i + j] }
                if s < lowestSum {
                    lowestSum = s
                    lowestIdx = i
                }
            }
        }

        // Fallback: no candidate fits the deadline (or no deadline at all)
        // → find the unconstrained cheapest window. We still show this
        // result so the card stays visible; the `missedDeadline` flag tells
        // the view to surface a warning glyph.
        let missed: Date?
        if lowestIdx < 0 {
            lowestSum = .infinity
            for i in 0...(sums.count - span) {
                var s = 0.0
                for j in 0..<span { s += sums[i + j] }
                if s < lowestSum {
                    lowestSum = s
                    lowestIdx = i
                }
            }
            missed = deadlineEnd          // only set when the user had one
        } else {
            missed = nil
        }
        guard lowestIdx >= 0 else { return nil }

        let startEntry = visible[lowestIdx]
        let endEntry = visible[lowestIdx + span - 1]
        let endDate = endEntry.date.addingTimeInterval(slotSeconds)

        return LowestWindow(
            slotIndex: slotIndex,
            hours: hours,
            startIndex: lowestIdx,
            endIndex: lowestIdx + span - 1,
            start: startEntry.date,
            end: endDate,
            averagePrice: lowestSum / Double(span),
            missedDeadline: missed
        )
    }
}
