import Foundation
import KlarschiffCore

/// Alles, was der löschfreie Check braucht – bewusst ohne Remover.
struct CheckDependencies: Sendable {
    var engine: ScanEngine
    var keepList: KeepList
    var history: CheckHistory
    var measureSystemRoots: CheckRunner.MeasureSystemRoots
    var diskSpace: @Sendable () throws -> DiskSpace
    var makeContext: @Sendable (_ includeSlowChecks: Bool) -> ScanContext
    var notifier: any Notifier
}

/// Ein Check-Lauf: Scan + Wurzel-Systembereiche + Verlauf (`CheckRunner`), danach höchstens eine Mitteilung.
/// Genutzt vom Startargument `--check` (LaunchAgent) und von „Jetzt prüfen“ in der laufenden App.
enum BackgroundCheck {
    struct Outcome: Sendable {
        var snapshot: CheckSnapshot
        var notification: CheckNotification?
        var notificationsAllowed: Bool
    }

    /// Startargument des LaunchAgents.
    static let argument = "--check"
    static var isRequested: Bool { CommandLine.arguments.contains(argument) }

    static func run(dependencies deps: CheckDependencies) async -> Outcome {
        let runner = CheckRunner(
            engine: deps.engine, keepList: deps.keepList, history: deps.history,
            measureSystemRoots: deps.measureSystemRoots, diskSpace: deps.diskSpace)
        let snapshot = await runner.run(deps.makeContext(false))
        let notification = CheckNotificationText.make(snapshot)
        // Abgelehnte Mitteilungen: Verlauf ist schon geschrieben, die Oberfläche zeigt einen Hinweis.
        let allowed = await deps.notifier.requestAuthorization()
        if allowed, let notification { await deps.notifier.send(notification) }
        return Outcome(snapshot: snapshot, notification: notification, notificationsAllowed: allowed)
    }

    /// Produktion: Wurzel-Systembereiche ohne Home und ohne Aufräum-Scanner messen; „nicht zuordenbar“ zählt nicht.
    static func measureSystemRootsLive(_ ctx: ScanContext) async -> [String: (title: String, size: Int64)] {
        let report = await SystemDataScanner(cleanupScanners: [], measureUserData: false).scan(ctx) { _, _ in }
        var roots: [String: (title: String, size: Int64)] = [:]
        for area in report.areas {
            guard let size = area.size else { continue }
            roots[area.id] = (area.title, size)
        }
        return roots
    }
}
