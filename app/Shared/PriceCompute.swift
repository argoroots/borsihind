import Foundation

/// Shared price math used by every consumer (app, widget, future
/// targets). Pure functions — no state, no side effects, no platform
/// APIs beyond `Foundation`.
public enum PriceCompute {

    /// A flat slot series in chronological order. `totals[i]` is the
    /// fully-loaded price (component sum + margin) of the slot starting
    /// at `baseDate + i * slotDuration`.
    public struct SlotSeries {
        public let totals: [Double]
        public let baseDate: Date
        public let slotDuration: TimeInterval

        public init(totals: [Double], baseDate: Date, slotDuration: TimeInterval) {
            self.totals = totals
            self.baseDate = baseDate
            self.slotDuration = slotDuration
        }

        public func startDate(at i: Int) -> Date {
            baseDate.addingTimeInterval(TimeInterval(i) * slotDuration)
        }

        public func endDate(at i: Int) -> Date {
            baseDate.addingTimeInterval(TimeInterval(i + 1) * slotDuration)
        }
    }

    public struct WindowResult {
        public let startIndex: Int
        public let endIndex: Int
        public let start: Date
        public let end: Date
        public let average: Double
        /// The deadline that couldn't be satisfied; the result is the
        /// unconstrained cheapest in that case. `nil` when honoured.
        public let missedDeadline: Date?
    }

    /// Sliding-window minimum. Falls back to unconstrained cheapest
    /// when no candidate fits `deadlineEnd`, surfacing the missed
    /// deadline so the UI can warn.
    public static func cheapestWindow(
        in series: SlotSeries,
        spanSlots: Int,
        fromIndex: Int = 0,
        deadlineEnd: Date? = nil
    ) -> WindowResult? {
        guard spanSlots > 0, series.totals.count >= fromIndex + spanSlots else { return nil }
        let lastStart = series.totals.count - spanSlots

        var bestSum = Double.infinity
        var bestIdx = -1

        // Pass 1: cheapest respecting the deadline.
        if let deadline = deadlineEnd {
            for i in fromIndex...lastStart where series.endDate(at: i + spanSlots - 1) <= deadline {
                let sum = series.totals[i..<(i + spanSlots)].reduce(0, +)
                if sum < bestSum { bestSum = sum; bestIdx = i }
            }
        }

        // Fallback: no candidate fits → unconstrained cheapest.
        let missed: Date?
        if bestIdx < 0 {
            bestSum = .infinity
            for i in fromIndex...lastStart {
                let sum = series.totals[i..<(i + spanSlots)].reduce(0, +)
                if sum < bestSum { bestSum = sum; bestIdx = i }
            }
            missed = deadlineEnd
        } else {
            missed = nil
        }
        guard bestIdx >= 0 else { return nil }

        return WindowResult(
            startIndex: bestIdx,
            endIndex: bestIdx + spanSlots - 1,
            start: series.startDate(at: bestIdx),
            end: series.endDate(at: bestIdx + spanSlots - 1),
            average: bestSum / Double(spanSlots),
            missedDeadline: missed
        )
    }

    /// Next occurrence of `hourOfDay`:00 at or after `now`. Returns
    /// `nil` for out-of-range hours (`-1` = off).
    public static func nextOccurrence(ofHour hourOfDay: Int, after now: Date,
                                      calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(hourOfDay) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hourOfDay
        guard var target = calendar.date(from: comps) else { return nil }
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return target
    }
}
