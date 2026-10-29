import Foundation

public struct RemovalReport: Sendable {
    public var results: [ItemResult]
    /// DiskInfo nachher − vorher, mindestens 0.
    public var freedBytes: Int64
    public var failures: [ItemResult]

    public init(results: [ItemResult], freedBytes: Int64, failures: [ItemResult]) {
        self.results = results
        self.freedBytes = freedBytes
        self.failures = failures
    }
}

public struct RemovalRunner: Sendable {
    private let trash: Remover
    private let delete: Remover
    private let tool: Remover
    private let admin: AdminRemover
    private let runningApps: RunningApps
    private let diskSpace: @Sendable () throws -> DiskSpace

    public init(
        trash: Remover, delete: Remover, tool: Remover, admin: AdminRemover,
        runningApps: RunningApps, diskSpace: @escaping @Sendable () throws -> DiskSpace
    ) {
        self.trash = trash
        self.delete = delete
        self.tool = tool
        self.admin = admin
        self.runningApps = runningApps
        self.diskSpace = diskSpace
    }

    public func run(_ plan: RemovalPlan, progress: @Sendable (String) -> Void) async -> RemovalReport {
        let dryRun = plan.options.dryRun
        let before = try? diskSpace()
        var results: [ItemResult] = []

        for (remover, steps) in [(tool, plan.toolSteps), (trash, plan.trashSteps), (delete, plan.deleteSteps)] {
            for (finding, items) in steps {
                progress("Entferne: \(finding.title)")
                let (ready, skipped) = screen(finding, items)
                results += skipped
                if !ready.isEmpty {
                    results += await remover.remove(finding, items: ready, dryRun: dryRun)
                }
            }
        }

        if !plan.adminSteps.isEmpty {
            progress("Admin-Schritte (eine Passwortabfrage)")
            var batch: [(Finding, [FindingItem])] = []
            for (finding, items) in plan.adminSteps {
                let (ready, skipped) = screen(finding, items)
                results += skipped
                if !ready.isEmpty { batch.append((finding, ready)) }
            }
            if !batch.isEmpty { results += await admin.remove(batch, dryRun: dryRun) }
        }

        let freed: Int64
        if dryRun {
            freed = 0
        } else if let before, let after = try? diskSpace() {
            freed = max(0, after.free - before.free)
        } else {
            freed = results.reduce(0) { sum, r in
                if case .removed(let f) = r.outcome { return sum + (f ?? 0) }
                return sum
            }
        }
        let failures = results.filter {
            switch $0.outcome {
            case .failed, .cancelled: true
            case .skipped(let reason): reason != RemovalText.dryRun
            case .removed: false
            }
        }
        return RemovalReport(results: results, freedBytes: freed, failures: failures)
    }

    /// Prüft unmittelbar vor der Ausführung, ob blockierende Apps laufen; liefert Items, die weiterlaufen dürfen, und Übersprungenes.
    private func screen(_ finding: Finding, _ items: [FindingItem]) -> (ready: [FindingItem], skipped: [ItemResult]) {
        func skip(_ app: AppRef, _ items: [FindingItem]) -> [ItemResult] {
            let outcome = ItemOutcome.skipped("\(app.displayName) läuft – vorher beenden")
            if items.isEmpty { return [ItemResult(findingID: finding.id, itemID: nil, outcome: outcome)] }
            return items.map { ItemResult(findingID: finding.id, itemID: $0.id, outcome: outcome) }
        }
        var seen = Set<AppRef>()
        let watched = (finding.watchedApps + finding.blockingApps).filter { seen.insert($0).inserted }
        if let app = runningApps.running(watched).first { return ([], skip(app, items)) }

        var ready: [FindingItem] = []
        var skipped: [ItemResult] = []
        var firstBlocker: AppRef?
        for item in items {
            if let candidate = item.watchedApp ?? item.blockingApp, let app = runningApps.running([candidate]).first {
                firstBlocker = firstBlocker ?? app
                skipped += skip(app, [item])
            } else {
                ready.append(item)
            }
        }
        // ToolRemover kann keine Teilmenge entfernen: ein blockiertes Item sperrt den ganzen Fund.
        if case .tool = finding.method, let app = firstBlocker { return ([], skip(app, items)) }
        return (ready, skipped)
    }
}
