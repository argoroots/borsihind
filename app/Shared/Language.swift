import SwiftUI

extension UserDefaults {
    /// App Group-backed defaults shared between the main app and the
    /// widget extension. Persists the language preference so both
    /// processes see the same value.
    static let shared = UserDefaults(suiteName: SharedStorage.appGroupID) ?? .standard
}

/// User-selectable UI language. Persisted as the raw identifier in
/// `@AppStorage("language", store: .shared)`.
enum Language: String, CaseIterable, Identifiable {
    case et
    case en

    var id: String { rawValue }

    /// Self-name (always shown in its own language).
    var label: String {
        switch self {
        case .et: "Eesti"
        case .en: "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

extension Locale {
    /// Look up a string in the matching `.lproj` bundle so the in-app
    /// language picker switches translations live. The standard
    /// `String(localized:locale:)` only uses the locale for formatting
    /// embedded values, not for choosing the table — hence the explicit
    /// per-language bundle.
    func t(_ key: String) -> String {
        let bundle = Self.cachedBundle(forLanguage: self.identifier) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private static let bundleCache = NSCache<NSString, Bundle>()

    private static func cachedBundle(forLanguage code: String) -> Bundle? {
        if let cached = bundleCache.object(forKey: code as NSString) {
            return cached
        }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return nil }
        bundleCache.setObject(bundle, forKey: code as NSString)
        return bundle
    }
}

extension Date.VerbatimFormatStyle {
    /// 24-hour `HH:mm`. Verbatim — bypasses locale/region so 13:00
    /// never renders as "01:00". (macOS honors locale `hourCycle`
    /// inconsistently depending on region settings.)
    static let hourMinute24 = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: .current,
        calendar: .current
    )

    /// 24-hour `HH` without minutes. Same locale-stability rationale.
    static let hour24 = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))",
        timeZone: .current,
        calendar: .current
    )
}
