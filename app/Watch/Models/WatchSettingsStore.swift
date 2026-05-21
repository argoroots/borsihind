import Foundation
import Observation
import WatchConnectivity

/// Receives `SyncedState` from the phone and caches it locally so the
/// watch keeps working offline. The watch fetches price data itself;
/// this only holds the settings + subscription payload.
@Observable
@MainActor
final class WatchSettingsStore: NSObject, WCSessionDelegate {
    private(set) var state: SyncedState

    private static let cacheKey = "synced.state.v1"

    override init() {
        state = Self.cached() ?? .default
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}

    /// Latest application context — the phone's most recent settings.
    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = WatchSync.payload(in: applicationContext) else { return }
        Task { @MainActor in
            guard let new = WatchSync.decode(data) else { return }
            self.state = new
            Self.cache(new)
        }
    }

    // MARK: Local cache

    private static func cached() -> SyncedState? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(SyncedState.self, from: data)
    }

    private static func cache(_ state: SyncedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
