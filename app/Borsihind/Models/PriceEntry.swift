import Foundation

/// One price row, c/kWh (already converted from €/MWh).
/// Stack order bottom → top: excise, supplySecurity, renewable,
/// transmission, electricity. `marginal` is added separately by the UI.
struct PriceEntry: Identifiable, Hashable, Sendable {
    let date: Date
    let electricity: Double
    let transmission: Double
    let renewable: Double
    let excise: Double
    let supplySecurity: Double

    var id: Date { date }

    /// Decode one entry from the raw JSON array:
    /// `[year, month, day, hour, minute, electricity, transmission,
    ///   renewable, excise, supplySecurity]`. Prices are €/MWh → ×100 c/kWh.
    static func decode(from raw: [Double]) -> PriceEntry? {
        guard raw.count >= 10 else { return nil }
        var comps = DateComponents()
        comps.year = Int(raw[0])
        comps.month = Int(raw[1])
        comps.day = Int(raw[2])
        comps.hour = Int(raw[3])
        comps.minute = Int(raw[4])
        guard let date = Calendar(identifier: .gregorian).date(from: comps) else { return nil }
        return PriceEntry(
            date: date,
            electricity: raw[5] * 100,
            transmission: raw[6] * 100,
            renewable: raw[7] * 100,
            excise: raw[8] * 100,
            supplySecurity: raw[9] * 100
        )
    }

    /// Sum of all components, excluding marginal.
    var componentSum: Double {
        electricity + transmission + renewable + excise + supplySecurity
    }

    /// Full price including marginal. Shared helper used everywhere a
    /// `Double` total is needed (snapshot, cheapest-window math).
    func total(withMargin marginal: Double) -> Double {
        componentSum + marginal
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

    /// Localization key looked up via `Locale.t(_:)`.
    var labelKey: String {
        switch self {
        case .fifteenMin: "15 minutes"
        case .oneHour: "1 hour"
        }
    }

    var minutes: Int { self == .oneHour ? 60 : 15 }

    /// Multiplier when computing N-hour windows.
    var slotsPerHour: Int { self == .oneHour ? 1 : 4 }
}

/// Cheapest-window result for one user slot. Up to four slots are shown
/// on the main screen, each with its own `hours` (1...6) and deadline.
struct LowestWindow: Identifiable, Hashable, Sendable {
    /// Stable storage slot index 0...3 — distinguishes two slots that
    /// happen to use the same `hours` value.
    let slotIndex: Int
    let hours: Int          // 1...6
    let startIndex: Int
    let endIndex: Int
    let start: Date
    let end: Date
    /// c/kWh, including marginal.
    let averagePrice: Double
    /// The user's deadline that this window couldn't satisfy. Non-nil
    /// surfaces a warning glyph on the card; the displayed window is
    /// the unconstrained cheapest fallback.
    let missedDeadline: Date?

    var id: Int { slotIndex }

    var label: String { "\(hours)h" }
}

/// User-configurable cheapest-hours slot. `hours == 0` disables the slot;
/// `deadline == -1` means no "must end before" constraint, otherwise it's
/// an hour of day (0...23, where 0 = midnight). `id` mirrors the storage
/// slot index so a `LowestWindow.slotIndex` stays tied to the right
/// `@AppStorage` entry.
struct CheapestSlot: Hashable, Sendable {
    var id: Int        // 0...3
    var hours: Int     // 0...6 (0 = off)
    var deadline: Int  // -1 = off, 0...23 = hour of day
}
