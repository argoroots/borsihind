#if os(iOS)
import Foundation
import WatchConnectivity

/// Pushes settings + subscription state to the paired watch via
/// `updateApplicationContext` — the latest payload is retained by the
/// system and delivered the next time the watch wakes, so the watch
/// stays in sync without needing the phone reachable at push time.
@MainActor
final class WatchConnectivityProvider: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityProvider()
    private override init() { super.init() }

    private var lastPushed: SyncedState?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Push only when the state actually changed and a watch is paired.
    func push(_ state: SyncedState) {
        guard WCSession.isSupported(), state != lastPushed else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else { return }
        if (try? session.updateApplicationContext(WatchSync.encode(state))) != nil {
            lastPushed = state
        }
    }

    // MARK: WCSessionDelegate (required stubs)

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
#endif
