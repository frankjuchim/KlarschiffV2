import Foundation
import KlarschiffCore
@preconcurrency import UserNotifications

/// Gespeicherter Mitteilungs-Entscheid – „nie gefragt“ ist etwas anderes als „abgelehnt“.
enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined, denied, authorized
}

/// Sendet die eine Check-Mitteilung – in Tests eine Attrappe.
protocol Notifier: Sendable {
    /// Fragt beim ersten Mal nach der Erlaubnis (System-Dialog!); nur beim Einschalten des Checks aufrufen.
    func requestAuthorization() async -> Bool
    /// Liest den gespeicherten Entscheid, ohne zu fragen – für den Check-Lauf.
    func isAuthorized() async -> Bool
    /// Wie `isAuthorized`, unterscheidet aber „nie gefragt“ von „abgelehnt“ (für den Hinweis in den Einstellungen).
    func authorizationStatus() async -> NotificationAuthorization
    func send(_ n: CheckNotification) async
}

/// Produktion: `UNUserNotificationCenter`. Der Ziel-Tab steckt in `userInfo["tab"]` (`AppTab.rawValue`).
struct UserNotificationCenterNotifier: Notifier {
    static func userInfo(for n: CheckNotification) -> [String: String] { ["tab": n.tab.rawValue] }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAuthorized() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: true
        default: false
        }
    }

    func authorizationStatus() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
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
