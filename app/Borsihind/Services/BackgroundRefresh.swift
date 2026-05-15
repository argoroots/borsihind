#if os(iOS)
import Foundation
import BackgroundTasks
import WidgetKit

/// iOS background-refresh hook. The OS wakes the app on its own schedule
/// to refetch prices, rewrite the widget snapshot, and reschedule
/// notifications — so coverage doesn't gap out when the user goes days
/// without opening the app.
///
/// Cadence is heuristic: iOS grants runtime based on usage patterns,
/// battery, network, and demand from other apps. Typical: a few times
/// per day.
@MainActor
enum BackgroundRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskIdentifier = "ee.borsihind.refresh"

    /// Refresh closure supplied by the host (ContentView's `refreshAll`).
    /// Stored so the background handler can run the pipeline regardless
    /// of which view is mounted.
    static var handler: (@MainActor () async -> Void)?

    /// Register the task identifier with the system. Call once early in
    /// the app lifecycle — repeated calls are safe but pointless.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil  // run on main queue
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                await runHandler(task: task)
            }
        }
    }

    /// Submit the next refresh request. iOS coalesces duplicates per
    /// identifier, so it's safe to call from multiple sites.
    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func runHandler(task: BGAppRefreshTask) async {
        // Bail cleanly if the OS preempts us.
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        await handler?()

        // Belt-and-suspenders widget reload in case the host forgot.
        WidgetCenter.shared.reloadAllTimelines()

        scheduleNext()
        task.setTaskCompleted(success: true)
    }
}
#endif
