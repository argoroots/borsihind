import Foundation

/// One row of price data, after conversion from €/MWh to c/kWh.
/// Stack order (bottom → top): excise, supplySecurity, renewable, transmission, electricity.
/// `marginal` is added separately at the bottom from user input.
struct PriceEntry: Identifiable, Hashable, Sendable {
    let date: Date
    let electricity: Double
    let transmission: Double
    let renewable: Double
    let excise: Double
    let supplySecurity: Double

    var id: Date { date }

    /// Decode one entry from raw JSON array:
    /// [year, month, day, hour, minute, electricity, transmission, renewable, excise, supplySecurity]
    /// All price fields are in €/MWh; we convert to c/kWh by ×100.
    static func decode(from raw: [Double]) -> PriceEntry? {
        guard raw.count >= 10 else { return nil }
        var comps = DateComponents()
        comps.year = Int(raw[0])
        comps.month = Int(raw[1])
        comps.day = Int(raw[2])
        comps.hour = Int(raw[3])
        comps.minute = Int(raw[4])
        let cal = Calendar(identifier: .gregorian)
        guard let date = cal.date(from: comps) else { return nil }
        return PriceEntry(
            date: date,
            electricity: raw[5] * 100,
            transmission: raw[6] * 100,
            renewable: raw[7] * 100,
            excise: raw[8] * 100,
            supplySecurity: raw[9] * 100
        )
    }

    /// Sum of all components excluding marginal.
    var componentSum: Double {
        electricity + transmission + renewable + excise + supplySecurity
    }
}

enum Plan: String, CaseIterable, Identifiable, Sendable {
    case v1 = "V1"
    case v2 = "V2"
    case v4 = "V4"
    case v5 = "V5"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .v1: "Võrk 1"
        case .v2: "Võrk 2"
        case .v4: "Võrk 4"
        case .v5: "Võrk 5"
        }
    }
}

enum Interval: String, CaseIterable, Identifiable, Sendable {
    case fifteenMin = "15min"
    case oneHour = "1h"

    var id: String { rawValue }

    /// Localization key — looked up via `Locale.t(_:)`.
    var labelKey: String {
        switch self {
        case .fifteenMin: "15 minutes"
        case .oneHour: "1 hour"
        }
    }

    var minutes: Int { self == .oneHour ? 60 : 15 }

    /// Slots per hour — used as multiplier when computing N-hour windows.
    var slotsPerHour: Int { self == .oneHour ? 1 : 4 }
}

/// Cheapest-window result for a single user slot. Each slot is one row
/// in the main screen's cheapest-hours list; users configure up to 4
/// slots with their own `hours` (1...6) and optional deadline.
struct LowestWindow: Identifiable, Hashable, Sendable {
    /// Slot index 0...3 — distinguishes results when two slots happen to
    /// use the same `hours` value.
    let slotIndex: Int
    /// Window length in hours (1...6) — used for display + savings %.
    let hours: Int
    let startIndex: Int
    let endIndex: Int
    let start: Date
    let end: Date
    let averagePrice: Double  // average c/kWh including marginal
    /// The user-configured "must end before HH:00" deadline that this
    /// window failed to satisfy. `nil` when there's no deadline set or
    /// the chosen window does respect it. When non-nil, the card UI
    /// renders a warning glyph next to the time so the user knows the
    /// shown window doesn't fit their deadline (but it's still the
    /// cheapest available, shown as a graceful fallback).
    let missedDeadline: Date?

    var id: Int { slotIndex }

    var label: String { "\(hours)h" }
}

/// User-configurable cheapest-hours slot: window length + optional
/// "must end before HH:00" deadline. `deadline == 0` means no constraint.
/// `id` is the stable storage slot index (0...3), used so the
/// resulting `LowestWindow.slotIndex` stays tied to the right
/// AppStorage entry even after the user re-orders the slots.
struct CheapestSlot: Hashable, Sendable {
    var id: Int        // 0...3, matches storage slot
    var hours: Int     // 1...6
    var deadline: Int  // 0 = off, 1...23
}
