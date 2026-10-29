import Testing
import Foundation
@testable import KlarschiffCore

private let liveEnabled = ProcessInfo.processInfo.environment["KLARSCHIFF_LIVE_SCAN"] == "1"

/// Opt-in Abnahme-Scan gegen den echten Mac. Nur lesend: Es werden keine Remover gebaut.
struct LiveScanTests {
    @Test(.enabled(if: liveEnabled), .timeLimit(.minutes(15)))
    func liveScanWritesSummary() async throws {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cache = try #require(SafetyGuard.userCacheDirectory())
        let ctx = ScanContext(
            home: home, userCacheDir: cache, rootPrefix: URL(filePath: "/"), runner: ProcessCommandRunner(),
            tools: .standard, sizer: SizeMeter(), runningApps: WorkspaceRunningApps(), claims: PathClaims(),
            now: Date(), hasFullDiskAccess: FullDiskAccess.isGranted(home: home), includeSlowChecks: true)
        let started = Date()
        let report = await ScanEngine(scanners: Catalog.allScanners()).run(ctx, progress: { _, _ in })
        let chunks = await BigChunksScanner().scan(ctx, findings: report.findings)
        let seconds = Int(Date().timeIntervalSince(started))

        var md = "# Live-Scan (nur lesend)\n\n"
        md += "Dauer: \(seconds) s, Voller Festplattenzugriff: \(ctx.hasFullDiskAccess ? "ja" : "nein"), Funde: \(report.findings.count), Fehler: \(report.failures.count)\n\n"
        md += "## Funde\n\n| Tab | Kategorie | Titel | Risiko | Methode | Größe | keepSuggested | blockiert |\n|---|---|---|---|---|---|---|---|\n"
        for f in report.findings.sorted(by: { ($0.size ?? 0) > ($1.size ?? 0) }) {
            let size = f.size.map { ByteFormat.string($0) } ?? "–"
            let blocking = f.blockingApps.map(\.displayName).joined(separator: ", ")
            md += "| \(f.tab.title) | \(f.category.title) | \(f.title.replacingOccurrences(of: "|", with: "/")) | \(f.risk) | \(Self.kind(f.method)) | \(size) | \(f.keepSuggested) | \(blocking.isEmpty ? "–" : blocking) |\n"
        }
        md += "\n## Scan-Fehler\n\n"
        md += report.failures.isEmpty ? "keine\n" : report.failures.map { "- \($0.scannerID): \($0.message)\n" }.joined()
        md += "\n## Große Brocken\n\n"
        for c in chunks {
            md += "- \(c.displayName): \(ByteFormat.string(c.size))" + (c.cleanableSize > 0 ? " (davon \(ByteFormat.string(c.cleanableSize)) oben aufräumbar)" : "") + "\n"
        }
        if let out = env["KLARSCHIFF_LIVE_SCAN_OUT"] {
            try md.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(md)
        }
    }

    @Test(.enabled(if: liveEnabled), .timeLimit(.minutes(15)))
    func liveSystemDataWritesSummary() async throws {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cache = try #require(SafetyGuard.userCacheDirectory())
        let ctx = ScanContext(
            home: home, userCacheDir: cache, rootPrefix: URL(filePath: "/"), runner: ProcessCommandRunner(),
            tools: .standard, sizer: SizeMeter(), runningApps: WorkspaceRunningApps(), claims: PathClaims(),
            now: Date(), hasFullDiskAccess: FullDiskAccess.isGranted(home: home), includeSlowChecks: true,
            userTempDir: SafetyGuard.userTempDirectory() ?? URL(filePath: "/var/empty/klarschiff-no-temp-dir"))
        let started = Date()
        let r = await SystemDataScanner().scan(ctx, progress: { _, _ in })
        let seconds = Int(Date().timeIntervalSince(started))

        var md = "# Live-Messung Systemdaten (nur lesend)\n\n"
        md += "Dauer: \(seconds) s, Voller Festplattenzugriff: \(ctx.hasFullDiskAccess ? "ja" : "nein")\n\n"
        md += "## Volumes\n\n"
        if let inv = r.inventory {
            md += "Container: \(ByteFormat.string(inv.containerSize)), frei: \(ByteFormat.string(inv.containerFree))\n\n"
            for v in inv.volumes { md += "- \(v.name) (\(v.role.rawValue)): \(ByteFormat.string(v.consumed))\n" }
            for v in inv.simulatorVolumes { md += "- \(v.name) (Simulator, anderer Container): \(ByteFormat.string(v.consumed))\n" }
        } else { md += "nicht lesbar\n" }
        md += "\n## Bereiche\n\n"
        func tree(_ a: SystemArea, _ depth: Int) {
            let size = a.size.map { (a.isLowerBound ? "mindestens " : "") + ByteFormat.string($0) } ?? "nicht messbar"
            md += String(repeating: "  ", count: depth) + "- \(a.title) (\(a.url.path)): \(size)\n"
            for c in a.children { tree(c, depth + 1) }
        }
        r.areas.forEach { tree($0, 0) }
        md += "\n## Summen\n\n"
        md += "- Deine Daten (Home + /Applications): \(ByteFormat.string(r.userData))\n"
        md += "- Systembereiche gesamt: \(ByteFormat.string(r.systemAreasTotal))\n"
        md += "- Nicht zugeordnet: \(ByteFormat.string(r.unaccounted))\n"
        md += "- userDataIsLowerBound: \(r.userDataIsLowerBound), unaccountedIsUpperBound: \(r.unaccountedIsUpperBound)\n"
        if let data = r.inventory?.volumes.first(where: { $0.role == .data }), data.consumed > 0 {
            let share = Double(r.userData + r.systemAreasTotal) / Double(data.consumed)
            md += "- Data-Volume belegt: \(ByteFormat.string(data.consumed))\n"
            md += "- Anteil zugeordnet: \(String(format: "%.1f", share * 100)) %\n"
        } else { md += "- Anteil zugeordnet: unbekannt (kein Data-Volume)\n" }
        md += "\n## Fehler\n\n"
        md += r.failures.isEmpty ? "keine\n" : r.failures.map { "- \($0.scannerID): \($0.message)\n" }.joined()
        md += "\n## Systemfunde\n\n| Titel | Größe | Methode | Admin-Schritte |\n|---|---|---|---|\n"
        for f in (r.snapshotFindings + r.cleanupFindings).sorted(by: { ($0.size ?? 0) > ($1.size ?? 0) }) {
            var steps = 0
            if case .admin(let s) = f.method { steps = s.count }
            md += "| \(f.title.replacingOccurrences(of: "|", with: "/")) | \(f.size.map { ByteFormat.string($0) } ?? "–") | \(Self.kind(f.method)) | \(steps) |\n"
        }
        if let out = env["KLARSCHIFF_LIVE_SCAN_OUT"] {
            try md.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(md)
        }
    }

    @Test(.enabled(if: liveEnabled), .timeLimit(.minutes(2)))
    func liveLegacyDetectWritesSummary() async throws {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cache = try #require(SafetyGuard.userCacheDirectory())
        let ctx = ScanContext(
            home: home, userCacheDir: cache, rootPrefix: URL(filePath: "/"), runner: ProcessCommandRunner(),
            tools: .standard, sizer: SizeMeter(), runningApps: WorkspaceRunningApps(), claims: PathClaims(),
            now: Date(), hasFullDiskAccess: FullDiskAccess.isGranted(home: home), includeSlowChecks: false)
        let items = await LegacyAutomation.detect(ctx)
        var md = "# Live-Erkennung der alten Automatik (nur lesend)\n\n"
        md += "Erkannt: \(items.count)\n\n| Titel | Ordner | geladen |\n|---|---|---|\n"
        for i in items {
            md += "| \(i.title) | \(i.url.deletingLastPathComponent().path) | \(i.isLoaded ? "ja" : "nein") |\n"
        }
        if let out = env["KLARSCHIFF_LIVE_SCAN_OUT"] {
            try md.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(md)
        }
    }

    @Test(.enabled(if: liveEnabled), .timeLimit(.minutes(2)))
    func liveServicesWritesSummary() async throws {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cache = try #require(SafetyGuard.userCacheDirectory())
        let runner = ProcessCommandRunner()
        let ctx = ScanContext(
            home: home, userCacheDir: cache, rootPrefix: URL(filePath: "/"), runner: runner,
            tools: .standard, sizer: SizeMeter(), runningApps: WorkspaceRunningApps(), claims: PathClaims(),
            now: Date(), hasFullDiskAccess: FullDiskAccess.isGranted(home: home), includeSlowChecks: false)
        let agents = await LaunchItemScanner().scan(ctx)
        let login = await LoginItemReader.read(runner: runner)
        let items = agents + login.items

        func folder(_ i: LaunchItem) -> String { i.plistURL?.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~") ?? "–" }
        var md = "# Live-Messung Hintergrunddienste (nur lesend)\n\n"
        md += "Einträge: \(items.count), verwaist: \(items.filter(\.isOrphaned).count), laufend: \(items.filter(\.isRunning).count), Anmeldeobjekte lesbar: \(login.failed ? "nein" : "ja")\n\n## Anzahl je Bereich\n\n"
        for s in LaunchScope.allCases {
            let l = items.filter { $0.scope == s }
            md += "- \(s.title): \(l.count) (verwaist \(l.filter(\.isOrphaned).count), laufend \(l.filter(\.isRunning).count))\n"
        }
        md += "\n## Einträge\n\n| Name | Bereich | Label | Startart | läuft | verwaist | Ordner | Erklärung |\n|---|---|---|---|---|---|---|---|\n"
        for i in items.sorted(by: { ($0.scope.rawValue, $0.label) < ($1.scope.rawValue, $1.label) }) {
            let note = (i.isOrphaned || i.explanation.contains("nicht gelesen")) ? i.explanation.replacingOccurrences(of: "|", with: "/") : ""
            md += "| \(i.displayName) | \(i.scope.title) | \(i.label) | \(i.startKind.title) | \(i.isRunning ? "ja" : "nein") | \(i.isOrphaned ? "ja" : "nein") | \(folder(i)) | \(note) |\n"
        }
        if let out = env["KLARSCHIFF_LIVE_SCAN_OUT"] {
            try md.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(md)
        }
    }

    private static func kind(_ m: RemovalMethod) -> String {
        switch m {
        case .trash: "trash"
        case .delete: "delete"
        case .tool: "tool"
        case .admin: "admin"
        case .hint: "hint"
        }
    }
}
