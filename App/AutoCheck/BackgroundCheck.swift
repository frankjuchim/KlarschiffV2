import Foundation
import KlarschiffCore
import Synchronization

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
        // Nie fragen (kein Dialog aus dem Hintergrund) – nur den gespeicherten Entscheid lesen. Abgelehnt oder
        // nie erlaubt: Verlauf ist schon geschrieben, die Oberfläche zeigt einen Hinweis.
        let allowed = await deps.notifier.isAuthorized()
        if allowed, let notification { await deps.notifier.send(notification) }
        return Outcome(snapshot: snapshot, notification: notification, notificationsAllowed: allowed)
    }

    /// Wächter für den kopflosen Lauf: höchstens so lange warten, dann beenden.
    static let headlessTimeout: Duration = .seconds(600)

    /// Wartet auf `operation`, höchstens `timeout`; danach `nil` (die Arbeit wird abgebrochen, aber nicht abgewartet –
    /// auch eine Operation, die Abbruch ignoriert, hält den Aufrufer nicht fest).
    static func withTimeout<T: Sendable>(
        _ timeout: Duration, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let pending = Mutex<CheckedContinuation<T?, Never>?>(continuation)
            let work = Task {
                let result = await operation()
                pending.withLock { $0.take() }?.resume(returning: result)
            }
            Task {
                try? await Task.sleep(for: timeout)
                guard let c = pending.withLock({ $0.take() }) else { return }
                work.cancel()
                c.resume(returning: nil)
            }
        }
    }

    /// Produktion: Wurzel-Systembereiche ohne Home und ohne Aufräum-Scanner messen; „nicht zuordenbar“ zählt nicht.
    /// Nur teilweise messbare Bereiche (`isLowerBound`) werden als Untergrenze weitergegeben – nie für Wachstum verglichen.
    static func measureSystemRootsLive(_ ctx: ScanContext) async -> [String: (title: String, size: Int64, isLowerBound: Bool)] {
        let report = await SystemDataScanner(cleanupScanners: [], measureUserData: false).scan(ctx) { _, _ in }
        var roots: [String: (title: String, size: Int64, isLowerBound: Bool)] = [:]
        for area in report.areas {
            guard let size = area.size else { continue }
            roots[area.id] = (area.title, size, area.isLowerBound)
        }
        return roots
    }
}
