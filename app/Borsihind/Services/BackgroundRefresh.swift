#if os(iOS)
import Foundation
import BackgroundTasks
import WidgetKit

/// iOS background-refresh hook. iOS wakes the app on its own schedule
/// to refetch prices + update the widget snapshot, so coverage doesn't
/// gap out when the user goes days without opening the app.
@MainActor
enum BackgroundRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskIdentifier = "ee.borsihind.refresh"

    /// Refresh closure supplied by ContentView. Stored so the handler
    /// runs the same pipeline regardless of view state.
    static var handler: (@MainActor () async -> Void)?

    /// Register the task with the system. Call once at app launch.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in await runHandler(task: task) }
        }
    }

    /// Submit the next refresh request. `earliestBeginDate` is a floor,
    /// not a cadence — iOS decides when to actually grant runtime. 1 h
    /// is plenty: data only changes when new slots publish.
    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func runHandler(task: BGAppRefreshTask) async {
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        await handler?()
        WidgetCenter.shared.reloadAllTimelines()
        scheduleNext()
        task.setTaskCompleted(success: true)
    }
}
#endif
