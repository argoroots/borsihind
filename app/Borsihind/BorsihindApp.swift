import SwiftUI
import StoreKit
#if os(iOS)
import UIKit
#endif

/// Posted by the macOS Settings… menu item; observed by `ContentView` to
/// present the settings sheet.
extension Notification.Name {
    static let openSettings = Notification.Name("ee.borsihind.openSettings")
}

#if os(iOS)
/// iOS app delegate, wired up just to configure a `WindowSceneDelegate`
/// (which applies a minimum window size for iPad multitasking).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = WindowSceneDelegate.self
        return config
    }
}

/// Per-scene delegate that applies a minimum window size on iPad
/// (multitasking / Stage Manager). iPhone has nil `sizeRestrictions`, so
/// this is a no-op there.
final class WindowSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 500, height: 680)
    }
}
#endif

@main
struct BorsihindApp: App {
    /// Shared StoreKit 2 subscription manager. Bootstrapped on the root
    /// scene's `.task`; kept fresh by `subscriptionStatusTask`.
    @State private var store = StoreManager()

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Register the BGAppRefreshTask identifier as early as possible —
    /// Apple requires `BGTaskScheduler.register(...)` before launch
    /// finishes. The actual handler is installed by `ContentView`.
    init() {
        BackgroundRefresh.register()
    }
    #endif

    @AppStorage("language", store: .shared) private var languageRaw: String = Language.et.rawValue

    private var locale: Locale {
        (Language(rawValue: languageRaw) ?? .et).locale
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        ContentView()
            .environment(\.locale, locale)
            .environment(store)
            .frame(minWidth: 560, minHeight: 700)
            // App Store macOS screenshot capture mode — DO NOT DELETE.
            // Swap with the `minWidth/minHeight` line above when taking
            // App Store screenshots. Apple requires a 1280×800 pt outer
            // window; macOS adds ~32pt of title-bar chrome above the
            // content view (even with `.hiddenTitleBar`), so the content
            // frame is 1280×768 to land the window at 1280×800
            // (= 2560×1600 px @2x, Apple's accepted screenshot size).
            // .frame(width: 1280, height: 768)
        #else
        ContentView()
            .environment(\.locale, locale)
            .environment(store)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            content
                .task { store.bootstrap() }
                // Fires on background renewals, refunds, family-sharing
                // changes, billing-grace transitions.
                .subscriptionStatusTask(for: StoreManager.subscriptionGroupID) { _ in
                    await store.refresh()
                }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        #endif
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                } label: {
                    Label(locale.t("Settings") + "…", systemImage: "gear")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
