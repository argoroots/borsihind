import Foundation
import Observation

/// Single source of truth for price data. Pipeline:
///   1. `load(...)` fetches both JSONs (user's interval + 1-h).
///   2. `prices` / `hourlyPrices` filter past slots from `now`.
///   3. Component sum + margin folded at compute time, not stored.
///   4. `lowestWindows(...)` runs `PriceCompute.cheapestWindow` —
///      same algorithm the widget uses.
///   5. App reads `prices`; widget reads `snapshot(...)` output.
@Observable
@MainActor
final class PricesViewModel {
    /// Raw data at the user's interval.
    private(set) var rawPrices: [PriceEntry] = []
    /// Raw data at 1-h resolution. Used by the widget's mini chart so
    /// bars match Nord Pool's published hourly prices (no averaging).
    private(set) var hourlyRawPrices: [PriceEntry] = []
    /// Per-minute tick driving the past-slot filter.
    private(set) var now: Date = .init()
    /// Interval used for the most recent `load(...)`.
    private(set) var currentInterval: Interval = .fifteenMin

    var isLoading = false
    var errorMessage: String?
    /// Last successful fetch timestamp. Drives the ≤ 3 h throttle.
    private(set) var lastFetchDate: Date?

    private let service = PriceService()
    private var minuteTask: Task<Void, Never>?
    /// In-flight fetch. A new `load` cancels it and supersedes — the
    /// latest requested (plan, interval) always wins.
    private var loadTask: Task<Void, Never>?
    /// Most recent rounded slot start the ticker saw — for crossing detection.
    private var lastSlotStart: Date?

    /// Past-slot filter at the user's interval.
    var prices: [PriceEntry] {
        let cutoff = Self.currentSlotStart(interval: currentInterval, now: now)
        return rawPrices.filter { $0.date >= cutoff }
    }

    /// Past-slot filter at 1-h resolution.
    var hourlyPrices: [PriceEntry] {
        let cutoff = Self.currentSlotStart(interval: .oneHour, now: now)
        return hourlyRawPrices.filter { $0.date >= cutoff }
    }

    /// Advance `now` to wall-clock time — re-filters `prices` without
    /// re-fetching the network.
    func bumpNow() {
        now = Date()
    }

    /// Force-fetch both files in parallel. Cancels any in-flight load
    /// and supersedes it, so the latest requested (plan, interval)
    /// always wins — e.g. the launch 1-h fetch is replaced the moment
    /// the subscription resolves to 15-min. Resets the staleness clock.
    func load(plan: Plan, interval: Interval) async {
        loadTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(plan: plan, interval: interval)
        }
        loadTask = task
        await task.value
    }

    private func performLoad(plan: Plan, interval: Interval) async {
        currentInterval = interval
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let primary = service.fetchPrices(plan: plan, interval: interval)
            if interval == .oneHour {
                rawPrices = try await primary
                hourlyRawPrices = rawPrices
            } else {
                async let hourly = service.fetchPrices(plan: plan, interval: .oneHour)
                rawPrices = try await primary
                hourlyRawPrices = (try? await hourly) ?? []
            }
            now = Date()
            lastFetchDate = Date()
        } catch {
            // Cancelled (superseded) or network failure — leave existing
            // data intact. Only surface genuine failures.
            if !(error is CancellationError) {
                errorMessage = "load_failed"
            }
        }
    }

    /// Fetch only when last fetch is older than `maxAge` (default 3 h)
    /// or unset. Returns `true` when a fetch actually ran.
    @discardableResult
    func loadIfStale(plan: Plan, interval: Interval,
                     maxAge: TimeInterval = 3 * 3600) async -> Bool {
        if let last = lastFetchDate,
           Date().timeIntervalSince(last) < maxAge,
           currentInterval == interval {
            return false
        }
        await load(plan: plan, interval: interval)
        return true
    }

    /// Per-minute ticker. Bumps `now` and fires `onSlotBoundary` when
    /// a new 15-min or 1-h slot has begun.
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

    /// Average of running an N-hour load starting NOW — baseline for
    /// the "% cheaper" badge. Nil when not enough future data.
    func nowAverage(forHours hours: Int, interval: Interval, marginal: Double) -> Double? {
        let span = hours * interval.slotsPerHour
        let head = prices.prefix(span)
        guard head.count == span, span > 0 else { return nil }
        return head.map { $0.total(withMargin: marginal) }.reduce(0, +) / Double(span)
    }

    /// Steps 3 + 4: fold margin into per-slot totals, then run the
    /// shared cheapest-window finder per user slot. Slots with
    /// `hours == 0` are skipped; a slot whose deadline can't be
    /// satisfied falls back to the unconstrained cheapest with
    /// `missedDeadline` set.
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

    /// Resolve the user's deadline hour to an absolute date via the
    /// shared helper — same logic the widget uses.
    private func deadlineDate(forHour hour: Int) -> Date? {
        PriceCompute.nextOccurrence(ofHour: hour, after: now)
    }

    /// Wrap `PriceCompute.cheapestWindow` and re-pack as `LowestWindow`.
    private func findLowest(in visible: [PriceEntry], span: Int,
                            slotIndex: Int, hours: Int,
                            interval: Interval, marginal: Double,
                            deadlineEnd: Date?) -> LowestWindow? {
        guard let first = visible.first else { return nil }
        let series = PriceCompute.SlotSeries(
            totals: visible.map { $0.total(withMargin: marginal) },
            baseDate: first.date,
            slotDuration: TimeInterval(interval.minutes * 60)
        )
        guard let r = PriceCompute.cheapestWindow(in: series, spanSlots: span,
                                                  deadlineEnd: deadlineEnd) else {
            return nil
        }
        return LowestWindow(
            slotIndex: slotIndex, hours: hours,
            startIndex: r.startIndex, endIndex: r.endIndex,
            start: r.start, end: r.end,
            averagePrice: r.average, missedDeadline: r.missedDeadline
        )
    }

    /// Step 5 (widget side): assemble the App Group snapshot. Centralised
    /// here so all snapshot fields derive from the same `prices` /
    /// `hourlyPrices` / margin source. ContentView just calls this and
    /// writes the result.
    func snapshot(slots: [CheapestSlot], selectedSlotID: Int?,
                  marginal: Double) -> SharedStorage.Snapshot? {
        guard let first = prices.first else { return nil }
        let selected = slots.first { $0.id == selectedSlotID && $0.hours > 0 }
            ?? slots.first { $0.hours > 0 }
            ?? CheapestSlot(id: 0, hours: 1, deadline: -1)
        let hourly = hourlyPrices
        return SharedStorage.Snapshot(
            slotTotals: prices.map { $0.total(withMargin: marginal) },
            slotStart: first.date,
            slotMinutes: currentInterval.minutes,
            cheapestHours: selected.hours,
            selectedSlotDeadline: selected.deadline,
            hourlyTotals: hourly.map { $0.total(withMargin: marginal) },
            hourlyStart: hourly.first?.date ?? first.date,
            writtenAt: Date()
        )
    }
}
