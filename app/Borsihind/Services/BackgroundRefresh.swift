#if os(iOS)
import Foundation
import BackgroundTasks
import WidgetKit

/// iOS background refresh hook. Wakes the app on the OS's schedule to
/// re-fetch the price file, rewrite the widget snapshot, and reschedule
/// notifications — so coverage doesn't gap out when the user goes days
/// without opening the app.
///
/// Cadence is heuristic: iOS decides when to grant runtime based on
/// user habits, battery, network, and overall demand. Typical: a few
/// times per day. We just submit a request with `earliestBeginDate` ~6 h
/// out and trust the system.
@MainActor
enum BackgroundRefresh {
    /// Must match the value in `Info.plist`'s
    /// `BGTaskSchedulerPermittedIdentifiers` array. Hard-coding rather
    /// than reading from the bundle so the identifier never silently
    /// diverges between code and config.
    static let taskIdentifier = "ee.borsihind.refresh"

    /// Closure the host app supplies to actually do the refresh work.
    /// Set once in `BorsihindApp` (or `ContentView`) before the system
    /// can dispatch a background task. Kept as a stored property so the
    /// background handler can find the right pipeline regardless of
    /// which view is currently mounted.
    static var handler: (@MainActor () async -> Void)?

    /// Register the task identifier with the system. Call once early in
    /// the app lifecycle — repeated calls are safe but pointless. The
    /// matching `submit()` schedules the *next* wake-up after each
    /// refresh completes.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil  // run handler on main queue
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                await runHandler(task: task)
            }
        }
    }

    /// Submit the next background refresh request. Idempotent — iOS
    /// coalesces duplicate submissions for the same identifier.
    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        // ~6 h gives iOS plenty of leeway to batch with other apps' wake-ups.
        // It's an *earliest* — the actual fire time can be much later.
        request.earliestBeginDate = Date().addingTimeInterval(6 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func runHandler(task: BGAppRefreshTask) async {
        // If our handler runs over time, the OS calls `expirationHandler`
        // to give us a chance to bail out cleanly. We pass through to
        // `setTaskCompleted(success:)` so the system records the result.
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        await handler?()

        // Reload widget timelines explicitly in case the host handler
        // forgot — cheap, idempotent.
        WidgetCenter.shared.reloadAllTimelines()

        // Chain the next wake-up so the cycle continues.
        scheduleNext()

        task.setTaskCompleted(success: true)
    }
}
#endif
