import SwiftUI
import StoreKit
#if os(iOS)
import UIKit
#endif

/// Posted by the macOS `Settings…` menu item; observed by `ContentView` to
/// present the settings sheet.
extension Notification.Name {
    static let openSettings = Notification.Name("ee.borsihind.openSettings")
}

#if os(iOS)
/// iOS-only app delegate. Wires up a `WindowSceneDelegate` so we can apply
/// per-scene settings (currently: a minimum window size for iPad
/// multitasking / Stage Manager — Mac uses `.frame(minWidth:)` on the
/// SwiftUI `WindowGroup` instead).
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

final class WindowSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // `sizeRestrictions` is non-nil only on iPad (and Mac via Catalyst).
        // It's the same minimum we set for the macOS WindowGroup.
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 500, height: 680)
    }
}
#endif

/// Application entry point. Hosts the single `WindowGroup` containing
/// `ContentView`, applies the user-selected locale to the environment, and
/// installs platform-specific window styling and the macOS Settings menu
/// command. iOS picks up additional per-scene config via `AppDelegate` above.
@main
struct BorsihindApp: App {
    /// Shared StoreKit 2 subscription manager. Bootstrapped on first
    /// appearance of the root scene; status kept fresh by
    /// `subscriptionStatusTask` (iOS 17+/macOS 14+).
    @State private var store = StoreManager()

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @AppStorage("language") private var languageRaw: String = Language.et.rawValue

    private var locale: Locale {
        (Language(rawValue: languageRaw) ?? .et).locale
    }

    /// ContentView with platform-specific framing. The macOS window is
    /// freely resizable, so we apply a minimum frame to keep it usable. On
    /// iOS the window size is fixed by the device, so any minWidth/minHeight
    /// would just push content past the screen edges.
    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        ContentView()
            .environment(\.locale, locale)
            .environment(store)
//            .frame(minWidth: 1280, minHeight: 768)
            .frame(minWidth: 500, minHeight: 700)
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
                // Modern lifecycle hook: fires on background renewals,
                // refunds, family-sharing changes, billing-grace transitions.
                .subscriptionStatusTask(for: StoreManager.subscriptionGroupID) { _ in
                    await store.refresh()
                }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        #endif
        #if !os(tvOS)
        // tvOS has no menu bar / keyboard shortcuts. The settings sheet on
        // tvOS is reached via the in-app gear button only.
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
        #endif
    }
}
