import Foundation

/// One row of price data, after conversion from €/MWh to c/kWh.
/// Stack order (bottom → top): excise, supplySecurity, renewable, transmission, electricity.
/// `marginal` is added separately at the bottom from user input.
struct PriceEntry: Identifiable, Hashable {
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

enum Plan: String, CaseIterable, Identifiable {
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

enum Interval: String, CaseIterable, Identifiable {
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

/// 1h/2h/3h/4h cheapest-window result.
struct LowestWindow: Identifiable, Hashable {
    let hours: Int            // 1, 2, 3, 4
    let startIndex: Int
    let endIndex: Int
    let start: Date
    let end: Date
    let averagePrice: Double  // average c/kWh including marginal

    var id: Int { hours }

    var label: String { "\(hours)h" }
}
