import SwiftUI

/// User-selectable UI language. Persisted as the raw identifier in
/// `@AppStorage("language")`; the matching `Locale` flows through the
/// SwiftUI `\.locale` environment so views observe live changes.
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

/// String Catalog lookup against the `.lproj` bundle for this locale's
/// language code, so the in-app language picker can switch translations
/// live. `String(localized:locale:)` only uses the locale for *formatting*
/// embedded values, not for choosing which translation table to read —
/// hence the explicit per-language bundle.
extension Locale {
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
              let bundle = Bundle(path: path) else { return nil }
        bundleCache.setObject(bundle, forKey: code as NSString)
        return bundle
    }
}
