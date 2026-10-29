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
