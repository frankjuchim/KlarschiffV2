import Foundation
import KlarschiffCore
@preconcurrency import UserNotifications

/// Sendet die eine Check-Mitteilung – in Tests eine Attrappe.
protocol Notifier: Sendable {
    /// Fragt beim ersten Mal nach der Erlaubnis; danach liefert es den gespeicherten Entscheid.
    func requestAuthorization() async -> Bool
    func send(_ n: CheckNotification) async
}

/// Produktion: `UNUserNotificationCenter`. Der Ziel-Tab steckt in `userInfo["tab"]` (`AppTab.rawValue`).
struct UserNotificationCenterNotifier: Notifier {
    static func userInfo(for n: CheckNotification) -> [String: String] { ["tab": n.tab.rawValue] }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Kehrt zurück, sobald das System die Mitteilung angenommen hat (sofortige Zustellung, kein Auslöser).
    func send(_ n: CheckNotification) async {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.userInfo = Self.userInfo(for: n)
        let request = UNNotificationRequest(identifier: "klarschiff2.check", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
