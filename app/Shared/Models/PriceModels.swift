import Foundation

/// Price file as published on S3: slot times in UTC, prices in €/kWh
/// with VAT.
struct PriceFile: Decodable, Sendable {
    struct Slot: Decodable, Sendable {
        let start: Date
        let electricity: Double
        let transmission: Double
        let renewable: Double
        let excise: Double
        let supplySecurity: Double
    }

    let prices: [Slot]
}

/// One price row, c/kWh (already converted from €/kWh).
/// Stack order bottom → top: excise, supplySecurity, renewable,
/// transmission, electricity. `marginal` is added separately by the UI.
struct PriceEntry: Identifiable, Hashable, Sendable {
    /// Slot start (absolute time).
    let date: Date
    let electricity: Double
    let transmission: Double
    let renewable: Double
    let excise: Double
    let supplySecurity: Double

    var id: Date { date }

    /// Convert one slot from the price file. Prices are €/kWh → ×100 c/kWh.
    init(slot: PriceFile.Slot) {
        self.init(
            date: slot.start,
            electricity: slot.electricity * 100,
            transmission: slot.transmission * 100,
            renewable: slot.renewable * 100,
            excise: slot.excise * 100,
            supplySecurity: slot.supplySecurity * 100
        )
    }

    init(date: Date, electricity: Double, transmission: Double,
         renewable: Double, excise: Double, supplySecurity: Double) {
        self.date = date
        self.electricity = electricity
        self.transmission = transmission
        self.renewable = renewable
        self.excise = excise
        self.supplySecurity = supplySecurity
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
