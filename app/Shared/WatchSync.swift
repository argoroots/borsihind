import Foundation

/// Settings + subscription state pushed phone → watch via
/// WatchConnectivity. The watch fetches price JSON itself; this only
/// carries the small config payload so the watch matches the app.
struct SyncedState: Codable, Equatable, Sendable {
    var planRaw: String
    var intervalRaw: String
    var marginal: Double
    /// 4 slots; `hours[i] == 0` means off.
    var slotHours: [Int]
    /// 4 slots; `-1` = no deadline, else hour-of-day 0...23.
    var slotDeadlines: [Int]
    /// Selected slot index 0...3, or -1 = none.
    var selectedSlot: Int
    var languageRaw: String
    var isSubscribed: Bool

    /// First-launch defaults before the phone has synced anything.
    static let `default` = SyncedState(
        planRaw: Plan.v1.rawValue,
        intervalRaw: Interval.fifteenMin.rawValue,
        marginal: 0,
        slotHours: [1, 2, 3, 4],
        slotDeadlines: [-1, -1, -1, -1],
        selectedSlot: 0,
        languageRaw: Language.et.rawValue,
        isSubscribed: false
    )

    var plan: Plan { Plan(rawValue: planRaw) ?? .v1 }
    var interval: Interval { Interval(rawValue: intervalRaw) ?? .fifteenMin }
    var locale: Locale { (Language(rawValue: languageRaw) ?? .et).locale }

    /// Effective interval/margin/slots applying the same premium gating
    /// as the iOS app.
    var effectiveInterval: Interval { isSubscribed ? interval : .oneHour }
    var effectiveMargin: Double { isSubscribed ? marginal : 0 }

    var effectiveSlots: [CheapestSlot] {
        let all = (0..<4).map { i in
            CheapestSlot(id: i, hours: slotHours[i], deadline: slotDeadlines[i])
        }
        return isSubscribed ? all : [CheapestSlot(id: 0, hours: 1, deadline: slotDeadlines[0])]
    }
}

/// Encode/decode `SyncedState` for a `WCSession` application context.
enum WatchSync {
    private static let key = "state"

    static func encode(_ state: SyncedState) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(state) else { return [:] }
        return [key: data]
    }

    static func decode(_ context: [String: Any]) -> SyncedState? {
        guard let data = context[key] as? Data else { return nil }
        return try? JSONDecoder().decode(SyncedState.self, from: data)
    }
}
