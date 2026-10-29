import Testing
import Foundation
import Synchronization
@testable import KlarschiffCore

private func finding(_ scanner: String, key: String = "k", urls: [String] = [], size: Int64? = 10,
                     risk: Risk = .safe) -> Finding {
    Finding(
        id: FindingID(scannerID: scanner, key: key), category: .appCaches, title: key, summary: "",
        risk: risk, method: .trash,
        items: urls.map { FindingItem(id: $0, url: URL(filePath: $0), name: $0, size: 5) },
        size: size, blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)
}

private struct StubScanner: KlarschiffCore.Scanner {
    let id: String
    var phase: ScannerPhase = .specific
    var result: @Sendable (ScanContext) async -> [Finding]
    func scan(_ ctx: ScanContext) async throws -> [Finding] { await result(ctx) }
    static func one(id: String, phase: ScannerPhase = .specific, urls: [String] = []) -> StubScanner {
        StubScanner(id: id, phase: phase) { _ in [finding(id, urls: urls)] }
    }
}

private struct ThrowingScanner: KlarschiffCore.Scanner {
    let id: String
    struct Boom: LocalizedError { var errorDescription: String? { "kaputt!" } }
    func scan(_ ctx: ScanContext) async throws -> [Finding] { throw Boom() }
}

/// Ignoriert Cancellation vollständig.
private struct HangingScanner: KlarschiffCore.Scanner {
    let id: String
    func scan(_ ctx: ScanContext) async throws -> [Finding] {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        return []
    }
}

@Suite struct ScanEngineTests {
    @Test func collectorSkipsClaimedPaths() async {
        let specific = StubScanner.one(id: "spec", urls: ["/x/a"])
        let collector = StubScanner(id: "coll", phase: .collector) { ctx in
            var out: [Finding] = []
            for p in ["/x/a", "/x/b"] where !(await ctx.claims.isClaimed(URL(filePath: p))) {
                out.append(finding("coll", key: p, urls: [p]))
            }
            return out
        }
        let r = await ScanEngine(scanners: [collector, specific]).run(.test(), progress: { _, _ in })
        let all = r.findings.flatMap(\.items).map(\.id)
        #expect(all.filter { $0 == "/x/a" }.count == 1)
        #expect(all.contains("/x/b"))
        #expect(r.findings.map(\.id.scannerID) == ["spec", "coll"])
    }

    @Test func lateCollectorSkipsPathsClaimedByCollector() async {
        let collector = StubScanner.one(id: "coll", phase: .collector, urls: ["/x/a"])
        let late = StubScanner(id: "late", phase: .lateCollector) { ctx in
            var out: [Finding] = []
            for p in ["/x/a/sub", "/x/b"] where !(await ctx.claims.isClaimed(URL(filePath: p))) {
                out.append(finding("late", key: p, urls: [p]))
            }
            return out
        }
        let r = await ScanEngine(scanners: [late, collector]).run(.test(), progress: { _, _ in })
        #expect(r.findings.map(\.id.scannerID) == ["coll", "late"])
        #expect(r.findings.flatMap(\.items).map(\.id) == ["/x/a", "/x/b"])
    }

    @Test func failingScannerBecomesFailure() async {
        let r = await ScanEngine(scanners: [ThrowingScanner(id: "kaputt"), StubScanner.one(id: "ok")])
            .run(.test(), progress: { _, _ in })
        #expect(r.failures.map(\.scannerID) == ["kaputt"])
        #expect(r.failures.first?.message == "kaputt!")
        #expect(r.findings.count == 1)
    }

    @Test func hangingScannerTimesOut() async {
        let start = ContinuousClock.now
        let r = await ScanEngine(scanners: [HangingScanner(id: "haengt")], perScannerTimeout: .milliseconds(200))
            .run(.test(), progress: { _, _ in })
        #expect(r.failures.first?.scannerID == "haengt")
        #expect(r.failures.first?.message == "Zeitüberschreitung nach 1 s")
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func claimsCoverDescendants() async {
        let c = PathClaims()
        await c.claim([URL(filePath: "/a/b")])
        #expect(await c.isClaimed(URL(filePath: "/a/b/c")))
        #expect(await c.isClaimed(URL(filePath: "/a/b")))
        #expect(!(await c.isClaimed(URL(filePath: "/a/bc"))))
    }

    @Test func claimedSizeSumsItemsUnderURL() async {
        let items = [
            FindingItem(id: "1", url: URL(filePath: "/a/b/x"), name: "x", size: 7),
            FindingItem(id: "2", url: URL(filePath: "/a/b"), name: "b", size: 3),
            FindingItem(id: "3", url: URL(filePath: "/a/bc"), name: "bc", size: 100),
            FindingItem(id: "4", url: URL(filePath: "/a/b/n"), name: "n", size: nil),
        ]
        let f = Finding(id: FindingID(scannerID: "s", key: "k"), category: .appCaches, title: "", summary: "",
                        risk: .safe, method: .trash, items: items, size: nil, blockingApps: [],
                        keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)
        let n = await PathClaims().claimedSize(under: URL(filePath: "/a/b"), findings: [f])
        #expect(n == 10)
    }

    @Test func discardsEmptyFindingsExceptHints() async {
        let s = StubScanner(id: "s") { _ in [
            finding("s", key: "zero", size: 0),
            finding("s", key: "hint", size: 0, risk: .hintOnly),
            finding("s", key: "nil", size: nil),
            finding("s", key: "zeroItems", urls: ["/q"], size: 0),
        ] }
        let r = await ScanEngine(scanners: [s]).run(.test(), progress: { _, _ in })
        #expect(r.findings.map(\.id.key) == ["hint", "nil", "zeroItems"])
    }

    @Test func progressReportsAcrossPhases() async {
        let calls = Mutex<[[Int]]>([])
        _ = await ScanEngine(scanners: [
            StubScanner.one(id: "a"), StubScanner.one(id: "b", phase: .collector), ThrowingScanner(id: "c"),
            StubScanner.one(id: "d", phase: .lateCollector),
        ]).run(.test(), progress: { c, t in calls.withLock { $0.append([c, t]) } })
        let v = calls.withLock { $0 }
        #expect(v.count == 4)
        #expect(v.map { $0[0] } == [1, 2, 3, 4])
        #expect(v.allSatisfy { $0[1] == 4 })
    }

    @Test func fakeRunningAppsMatchesBundleOrProcess() {
        let f = FakeRunningApps(running: ["com.x", "proc"])
        let a = AppRef(bundleID: "com.x", processName: nil, displayName: "A")
        let b = AppRef(bundleID: nil, processName: "proc", displayName: "B")
        let c = AppRef(bundleID: "no", processName: "no", displayName: "C")
        #expect(f.running([a, b, c]) == [a, b])
    }

    @Test func cancellingRunReturnsPromptlyWithAbgebrochen() async {
        let engine = ScanEngine(scanners: [StubScanner.one(id: "ok"), HangingScanner(id: "haengt")],
                                perScannerTimeout: .seconds(60))
        let start = ContinuousClock.now
        let task = Task { await engine.run(.test(), progress: { _, _ in }) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let r = await task.value
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(r.findings.map(\.id.scannerID) == ["ok"])
        #expect(r.failures.first(where: { $0.scannerID == "haengt" })?.message == "Abgebrochen")
    }

    @Test func workspaceRunningAppsSeesLaunchd() {
        let ref = AppRef(bundleID: nil, processName: "launchd", displayName: "launchd")
        #expect(!WorkspaceRunningApps().running([ref]).isEmpty)
    }
}
