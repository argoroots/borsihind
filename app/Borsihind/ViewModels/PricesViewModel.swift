import Foundation
import Observation

/// Owns price data and derived state. Fetches once; `prices` is filtered
/// on every `now` tick so the chart slides forward without re-fetching.
/// `startMinuteTicker` drives both the slide and the slot-boundary
/// callback that triggers a full refresh.
@Observable
@MainActor
final class PricesViewModel {
    /// Entire fetched price file. Filtering happens in `prices`.
    private(set) var rawPrices: [PriceEntry] = []
    /// Tick that drives the per-minute filter recomputation.
    private(set) var now: Date = .init()
    /// Slot length used for the most recent `load(...)`.
    private(set) var currentInterval: Interval = .fifteenMin

    var isLoading = false
    var errorMessage: String?

    private let service = PriceService()
    private var minuteTask: Task<Void, Never>?
    /// Most recent rounded slot start the ticker observed. When it changes
    /// between ticks, we crossed a slot boundary.
    private var lastSlotStart: Date?

    /// Slots at or after the current rounded-down slot. Recomputes on
    /// any change to `rawPrices`, `now`, or `currentInterval`.
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

    /// Per-minute ticker. Bumps `now` (chart slide) and fires
    /// `onSlotBoundary` whenever a new 15-min or 1-h slot has just begun.
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

    /// Round `now` down to the start of the current interval's slot.
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

    /// Average price of running an N-hour load starting NOW — apples-to-apples
    /// baseline for the "% cheaper" badge. Nil when not enough future data.
    func nowAverage(forHours hours: Int, interval: Interval, marginal: Double) -> Double? {
        let span = hours * interval.slotsPerHour
        let head = prices.prefix(span)
        guard head.count == span, span > 0 else { return nil }
        let sum = head.reduce(0.0) { $0 + $1.componentSum + marginal }
        return sum / Double(span)
    }

    /// One cheapest window per input slot. Slots with `hours == 0` are
    /// skipped. A slot whose deadline can't be satisfied falls back to
    /// the unconstrained cheapest window with `missedDeadline` set.
    func lowestWindows(interval: Interval, marginal: Double,
                       slots: [CheapestSlot]) -> [LowestWindow] {
        let visible = prices
        guard !visible.isEmpty else { return [] }
        let multiplier = interval.slotsPerHour
        return slots.compactMap { slot in
            guard slot.hours > 0 else { return nil }
            return findLowest(in: visible,
                              span: slot.hours * multiplier,
                              slotIndex: slot.id,
                              hours: slot.hours,
                              interval: interval,
                              marginal: marginal,
                              deadlineEnd: deadlineDate(forHour: slot.deadline))
        }
    }

    /// Next occurrence of HH:00 at or after `now`. Returns nil when the
    /// hour is out of range (off sentinel is `-1`).
    private func deadlineDate(forHour hour: Int) -> Date? {
        guard (0...23).contains(hour) else { return nil }
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

        // Pass 1: cheapest window respecting the deadline (if any).
        var lowestSum = Double.infinity
        var lowestIdx = -1
        if let deadline = deadlineEnd {
            for i in 0...(sums.count - span) {
                let endDate = visible[i + span - 1].date.addingTimeInterval(slotSeconds)
                if endDate > deadline { continue }
                let s = sums[i..<(i + span)].reduce(0, +)
                if s < lowestSum { lowestSum = s; lowestIdx = i }
            }
        }

        // Fallback: no candidate fits the deadline → unconstrained
        // cheapest, with `missedDeadline` set so the UI can warn.
        let missed: Date?
        if lowestIdx < 0 {
            lowestSum = .infinity
            for i in 0...(sums.count - span) {
                let s = sums[i..<(i + span)].reduce(0, +)
                if s < lowestSum { lowestSum = s; lowestIdx = i }
            }
            missed = deadlineEnd
        } else {
            missed = nil
        }
        guard lowestIdx >= 0 else { return nil }

        let startEntry = visible[lowestIdx]
        let endEntry = visible[lowestIdx + span - 1]
        return LowestWindow(
            slotIndex: slotIndex,
            hours: hours,
            startIndex: lowestIdx,
            endIndex: lowestIdx + span - 1,
            start: startEntry.date,
            end: endEntry.date.addingTimeInterval(slotSeconds),
            averagePrice: lowestSum / Double(span),
            missedDeadline: missed
        )
    }
}
