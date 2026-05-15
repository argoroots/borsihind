import Foundation
#if !os(tvOS)
import UserNotifications
#endif

/// Schedules local notifications for cheapest-hours slots.
///
/// Each active slot becomes a `UNCalendarNotificationTrigger` fired
/// `leadMinutes` before `LowestWindow.start`. Identifiers are
/// deterministic (`"slot.0"…"slot.3"`) so a fresh `reschedule(...)`
/// cleanly replaces the previous batch without stacking duplicates.
///
/// Notifications fire even when the app is fully closed — the OS handles
/// delivery once they're registered. `BackgroundRefresh` keeps them
/// populated when the user goes days without opening the app.
///
/// tvOS has no `UserNotifications` framework — all entry points are
/// no-op stubs there so call sites stay platform-agnostic.
@MainActor
enum NotificationScheduler {

    #if !os(tvOS)

    /// Slot ids 0...3 — matches `LowestWindow.slotIndex`.
    private static let slotIdentifiers = (0..<4).map { "slot.\($0)" }

    /// Request alert + sound permission. Idempotent: returns the cached
    /// authorization without prompting on subsequent calls. Returns
    /// `true` for `.authorized`, `.provisional`, `.ephemeral`.
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// Replace pending slot notifications with a fresh batch derived
    /// from `slots`. Slots whose `start - leadMinutes` is already past
    /// are skipped. `leadMinutes < 0` → `removeAll()`.
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
            let fireDate = slot.start.addingTimeInterval(-Double(leadMinutes) * 60)
            guard fireDate > now else { continue }

            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

            let content = UNMutableNotificationContent()
            content.title = "Börsihind"
            content.body = locale.t("Cheapest %@h starts at %@")
                .replacingFirstOccurrence(of: "%@", with: String(slot.hours))
                .replacingFirstOccurrence(of: "%@", with: slot.start.formatted(fmt))
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "slot.\(slot.slotIndex)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    static func removeAll() async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: slotIdentifiers)
    }

    #else

    static func requestAuthorizationIfNeeded() async -> Bool { false }
    static func reschedule(slots: [LowestWindow], leadMinutes: Int, locale: Locale) async {}
    static func removeAll() async {}

    #endif
}

private extension String {
    /// Replace only the first occurrence of `needle` with `replacement`.
    /// Used to fill positional `%@` placeholders one at a time.
    func replacingFirstOccurrence(of needle: String, with replacement: String) -> String {
        guard let range = self.range(of: needle) else { return self }
        return self.replacingCharacters(in: range, with: replacement)
    }
}
