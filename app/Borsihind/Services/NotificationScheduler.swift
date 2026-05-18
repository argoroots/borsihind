import Foundation
#if !os(tvOS)
import UserNotifications
#endif

/// Local notifications for cheapest-hours slots. Each slot becomes one
/// `UNCalendarNotificationTrigger` fired `leadMinutes` before its start.
/// Identifiers are deterministic (`"slot.0"…"slot.3"`) so re-scheduling
/// replaces, never stacks.
///
/// Fires even when the app is closed — the OS delivers once a trigger
/// is registered. tvOS has no `UserNotifications` framework, so the
/// entry points are no-op stubs there.
@MainActor
enum NotificationScheduler {

    #if !os(tvOS)

    private static let slotIdentifiers = (0..<4).map { "slot.\($0)" }

    /// Returns true for `.authorized`, `.provisional`, `.ephemeral`.
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied: return false
        @unknown default: return false
        }
    }

    /// Replace pending notifications. `leadMinutes < 0` → `removeAll()`.
    static func reschedule(slots: [LowestWindow], leadMinutes: Int, locale: Locale) async {
        guard leadMinutes >= 0, await requestAuthorizationIfNeeded() else {
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

            let content = UNMutableNotificationContent()
            content.title = "Börsihind"
            content.body = locale.t("Cheapest %@h starts at %@")
                .replacingFirstOccurrence(of: "%@", with: String(slot.hours))
                .replacingFirstOccurrence(of: "%@", with: slot.start.formatted(fmt))
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false
            )
            try? await center.add(UNNotificationRequest(
                identifier: "slot.\(slot.slotIndex)", content: content, trigger: trigger
            ))
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
    /// Replace only the first occurrence — fills positional `%@`
    /// placeholders one at a time.
    func replacingFirstOccurrence(of needle: String, with replacement: String) -> String {
        guard let range = self.range(of: needle) else { return self }
        return self.replacingCharacters(in: range, with: replacement)
    }
}
