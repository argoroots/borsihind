import Foundation
#if !os(tvOS)
import UserNotifications
#endif

/// Schedules local notifications for the user's cheapest-hours slots.
///
/// Each active slot becomes one `UNCalendarNotificationTrigger` fired
/// `leadMinutes` before `LowestWindow.start`. Identifiers are deterministic
/// (`"slot.0"…"slot.3"`) so a fresh `reschedule(...)` cleanly replaces the
/// previous batch without stacking duplicates.
///
/// Notifications fire even when the app is fully closed — the OS
/// notification daemon delivers them; we just need to register the
/// triggers ahead of time. To keep them populated when the user goes
/// days without opening the app, `BackgroundRefresh` wakes the app
/// periodically and re-runs the unified refresh pipeline.
///
/// tvOS doesn't support `UserNotifications`, so the whole namespace is
/// guarded out on that platform.
@MainActor
enum NotificationScheduler {

    #if !os(tvOS)

    /// Slot ids 0...3 — matches `LowestWindow.slotIndex`.
    private static let slotIdentifiers = (0..<4).map { "slot.\($0)" }

    /// Ask the OS for alert + sound permission. Idempotent: subsequent
    /// calls return the cached authorization without prompting again.
    /// Returns true for `.authorized` and `.provisional` (silent).
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// Replace pending slot notifications with a fresh batch derived from
    /// `slots`. Slots whose `start - leadMinutes` is already in the past
    /// are skipped. `leadMinutes < 0` is treated as "off" — calls
    /// `removeAll()` and returns.
    static func reschedule(slots: [LowestWindow], leadMinutes: Int, locale: Locale) async {
        guard leadMinutes >= 0 else {
            await removeAll()
            return
        }
        guard await requestAuthorizationIfNeeded() else {
            await removeAll()
            return
        }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: slotIdentifiers)

        let now = Date()
        let cal = Calendar.current
        let fmt = Date.VerbatimFormatStyle.hourMinute24

        for slot in slots {
            let identifier = "slot.\(slot.slotIndex)"
            let fireDate = slot.start.addingTimeInterval(-Double(leadMinutes) * 60)
            // Skip slots whose fire date has already passed.
            guard fireDate > now else { continue }

            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute],
                                           from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

            let content = UNMutableNotificationContent()
            content.title = "Börsihind"
            content.body = locale.t("Cheapest %@h starts at %@")
                .replacingOccurrences(of: "%@1", with: "")
                .replacingFirstOccurrence(of: "%@", with: String(slot.hours))
                .replacingFirstOccurrence(of: "%@", with: slot.start.formatted(fmt))
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    /// Drop any pending slot notifications. Safe to call repeatedly.
    static func removeAll() async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: slotIdentifiers)
    }

    #else

    // tvOS: notifications aren't supported. No-op stubs keep call sites
    // platform-agnostic without `#if` cluttering ContentView.
    static func requestAuthorizationIfNeeded() async -> Bool { false }
    static func reschedule(slots: [LowestWindow], leadMinutes: Int, locale: Locale) async {}
    static func removeAll() async {}

    #endif
}

// MARK: - Helpers

private extension String {
    /// Replace only the first occurrence of `needle` with `replacement`.
    /// Used to fill positional `%@` placeholders one at a time without
    /// needing `String(format:)`'s positional gymnastics.
    func replacingFirstOccurrence(of needle: String, with replacement: String) -> String {
        guard let range = self.range(of: needle) else { return self }
        return self.replacingCharacters(in: range, with: replacement)
    }
}
