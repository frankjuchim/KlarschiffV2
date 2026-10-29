import Testing
import Foundation
import Synchronization
@testable import KlarschiffCore

private final class Log: @unchecked Sendable {
    private let m = Mutex<[String]>([])
    func append(_ s: String) { m.withLock { $0.append(s) } }
    var entries: [String] { m.withLock { $0 } }
}

private final class RecordingRemover: Remover {
    let label: String
    let log: Log
    let onCall: (@Sendable () -> Void)?
    let seen = Mutex<[(FindingID, [String], Bool)]>([])

    init(_ label: String, log: Log, onCall: (@Sendable () -> Void)? = nil) {
        self.label = label; self.log = log; self.onCall = onCall
    }

    var calls: [(FindingID, [String], Bool)] { seen.withLock { $0 } }

    func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] {
        log.append("\(label):\(finding.id.key)")
        seen.withLock { $0.append((finding.id, items.map(\.id), dryRun)) }
        onCall?()
        return items.map { ItemResult(findingID: finding.id, itemID: $0.id, outcome: .removed(freed: $0.size)) }
    }
}

private final class LoggingExecutor: PrivilegedExecutor {
    let log: Log
    let result: AdminRunResult
    private let state = Mutex<[[AdminStep]]>([])
    init(log: Log, result: AdminRunResult) { self.log = log; self.result = result }
    var runs: [[AdminStep]] { state.withLock { $0 } }
    func run(_ steps: [AdminStep]) async -> AdminRunResult {
        log.append("admin")
        state.withLock { $0.append(steps) }
        return result
    }
}

private let xcode = AppRef(bundleID: "com.apple.dt.Xcode", processName: nil, displayName: "Xcode")
private let toolCmd = ToolCommand(tool: "brew", arguments: ["uninstall", "--cask", "foo"], timeout: .seconds(10))

private func item(_ id: String, size: Int64 = 100, blocking: AppRef? = nil) -> FindingItem {
    FindingItem(id: id, url: URL(filePath: "/Users/x/Library/Caches/\(id)"), name: id, size: size, blockingApp: blocking)
}

private func finding(
    _ key: String, _ method: RemovalMethod, risk: Risk = .safe, items: [FindingItem]? = nil,
    size: Int64? = nil, watched: [AppRef] = [], blocking: [AppRef] = []
) -> Finding {
    Finding(id: FindingID(scannerID: "t", key: key), category: .appCaches, title: "T-\(key)", summary: "S", risk: risk,
            method: method, items: items ?? [item("\(key)-1")], size: size, blockingApps: blocking, keepSuggested: false,
            commandPreview: [], needsFullDiskAccess: false, watchedApps: watched)
}

private func selectAll(_ fs: [Finding]) -> [FindingID: Set<String>] {
    Dictionary(uniqueKeysWithValues: fs.map { ($0.id, Set($0.items.map(\.id))) })
}

private func plan(_ fs: [Finding], zap: Set<FindingID> = [], direct: Set<FindingID> = [], dry: Bool = false) -> RemovalPlan {
    RemovalPlan(findings: fs, selection: selectAll(fs),
                options: RemovalOptions(deleteDirectly: direct, zap: zap, dryRun: dry))
}

private struct Rig {
    let log = Log()
    let trash: RecordingRemover, delete: RecordingRemover, tool: RecordingRemover
    let exec: LoggingExecutor
    let apps: FakeRunningApps
    let runner: RemovalRunner

    init(adminResult: AdminRunResult = .completed([0]), apps: FakeRunningApps = FakeRunningApps(),
         disk: @escaping @Sendable () throws -> DiskSpace = { DiskSpace(free: 0, total: 0) }) throws {
        let tree = try FixtureTree()
        let home = tree.root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let g = SafetyGuard(home: home, userCacheDir: tree.root.appending(path: "C"), allowedCacheSubdirs: [])
        let log = self.log
        trash = RecordingRemover("trash", log: log)
        delete = RecordingRemover("delete", log: log)
        tool = RecordingRemover("tool", log: log)
        exec = LoggingExecutor(log: log, result: adminResult)
        self.apps = apps
        runner = RemovalRunner(trash: trash, delete: delete, tool: tool,
                               admin: AdminRemover(executor: exec, guard: g), runningApps: apps, diskSpace: disk)
    }
}

private let adminStep = AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive/2022"])

@Suite struct RemovalRunnerTests {
    @Test func orderIsToolTrashDeleteAdmin() async throws {
        let fs = [
            finding("a", .admin([adminStep])),
            finding("d", .delete),
            finding("t", .trash),
            finding("x", .tool([toolCmd], fallback: nil)),
        ]
        let rig = try Rig()
        let report = await rig.runner.run(plan(fs)) { _ in }
        #expect(rig.log.entries == ["tool:x", "trash:t", "delete:d", "admin"])
        #expect(rig.exec.runs.count == 1)
        #expect(report.results.count == 4)
        #expect(report.failures.isEmpty)
    }

    @Test func skipsFindingWhoseAppStartedMeanwhile() async throws {
        let apps = FakeRunningApps()
        let rig = try Rig(apps: apps)
        let fs = [
            finding("instr", .delete, watched: [xcode]),
            finding("other", .trash),
        ]
        apps.setRunning(["com.apple.dt.Xcode"]) // erst nach dem Scan
        let report = await rig.runner.run(plan(fs)) { _ in }
        let instr = report.results.filter { $0.findingID.key == "instr" }
        #expect(instr.map(\.outcome) == [.skipped("Xcode läuft – vorher beenden")])
        #expect(rig.delete.calls.isEmpty)
        #expect(rig.trash.calls.count == 1)
        #expect(report.failures.count == 1)
    }

    @Test func recheckHappensImmediatelyBeforeEachFinding() async throws {
        let apps = FakeRunningApps()
        let log = Log()
        let tree = try FixtureTree()
        let g = SafetyGuard(home: tree.root, userCacheDir: tree.root.appending(path: "C"), allowedCacheSubdirs: [])
        // Xcode startet, während der erste Fund (Trash) läuft.
        let trash = RecordingRemover("trash", log: log) { apps.setRunning(["com.apple.dt.Xcode"]) }
        let delete = RecordingRemover("delete", log: log)
        let runner = RemovalRunner(trash: trash, delete: delete, tool: RecordingRemover("tool", log: log),
                                   admin: AdminRemover(executor: FakeExecutor(fixed: .cancelled), guard: g),
                                   runningApps: apps, diskSpace: { DiskSpace(free: 0, total: 0) })
        let fs = [finding("t", .trash), finding("d", .delete, watched: [xcode])]
        let report = await runner.run(plan(fs)) { _ in }
        #expect(delete.calls.isEmpty)
        #expect(report.results.last?.outcome == .skipped("Xcode läuft – vorher beenden"))
    }

    @Test func blockingAppAtScanTimeAlsoBlocks() async throws {
        let apps = FakeRunningApps(running: ["com.apple.dt.Xcode"])
        let rig = try Rig(apps: apps)
        let report = await rig.runner.run(plan([finding("a", .trash, blocking: [xcode])])) { _ in }
        #expect(report.results.map(\.outcome) == [.skipped("Xcode läuft – vorher beenden")])
        #expect(rig.trash.calls.isEmpty)
    }

    @Test func itemLevelBlockingAppSkipsOnlyThatItem() async throws {
        let apps = FakeRunningApps(running: ["com.apple.dt.Xcode"])
        let rig = try Rig(apps: apps)
        let f = finding("a", .trash, items: [item("i1", blocking: xcode), item("i2")])
        let report = await rig.runner.run(plan([f])) { _ in }
        #expect(rig.trash.calls.first?.1 == ["i2"])
        let byItem = Dictionary(uniqueKeysWithValues: report.results.map { ($0.itemID ?? "", $0.outcome) })
        #expect(byItem["i1"] == .skipped("Xcode läuft – vorher beenden"))
        #expect(byItem["i2"] == .removed(freed: 100))
    }

    @Test func itemWatchedAppStartingMidRunSkipsOnlyThatItem() async throws {
        let apps = FakeRunningApps()
        let rig = try Rig(apps: apps)
        let cache = AppRef(bundleID: "com.x.app", processName: nil, displayName: "X")
        let w = FindingItem(id: "w", url: URL(filePath: "/Users/x/Library/Caches/w"), name: "w", size: 5, watchedApp: cache)
        let f = finding("a", .trash, items: [w, item("i2")])
        apps.setRunning(["com.x.app"])
        let report = await rig.runner.run(plan([f])) { _ in }
        #expect(rig.trash.calls.first?.1 == ["i2"])
        #expect(report.results.contains { $0.itemID == "w" && $0.outcome == .skipped("X läuft – vorher beenden") })
    }

    @Test func blockedItemSkipsWholeToolFinding() async throws {
        let apps = FakeRunningApps(running: ["com.apple.dt.Xcode"])
        let rig = try Rig(apps: apps)
        let f = finding("x", .tool([toolCmd], fallback: nil), items: [item("i1", blocking: xcode), item("i2")])
        let report = await rig.runner.run(plan([f])) { _ in }
        #expect(rig.tool.calls.isEmpty)
        #expect(report.results.count == 2)
        #expect(report.results.allSatisfy { $0.outcome == .skipped("Xcode läuft – vorher beenden") })
    }

    @Test func untrustedTapHintKeepsCaskNameAfterZap() async throws {
        let f = finding("x", .tool([toolCmd], fallback: nil))
        let p = plan([f], zap: [f.id])
        guard case .tool(let cmds, _) = p.toolSteps[0].0.method else { Issue.record("tool"); return }
        let fake = FakeCommandRunner()
        fake.stub("/x/brew", cmds[0].arguments, result: CommandResult(exitCode: 1, stdout: "", stderr: "Error: Refusing to load cask from untrusted tap foo/bar"))
        let remover = ToolRemover(runner: fake, tools: ToolLocator(searchPaths: ["/x"], fileExists: { _ in true }))
        let r = await remover.remove(p.toolSteps[0].0, items: p.toolSteps[0].1, dryRun: false)
        guard case .failed(let msg) = r[0].outcome else { Issue.record("failed"); return }
        #expect(msg.contains("brew uninstall --cask foo ·"))
    }

    @Test func hintsAreNeverPlanned() {
        let h = finding("h", .hint(nil), risk: .hintOnly)
        let t = finding("t", .trash)
        let p = plan([h, t])
        #expect(p.trashSteps.count == 1)
        #expect(p.toolSteps.isEmpty && p.deleteSteps.isEmpty && p.adminSteps.isEmpty)
        #expect(p.totalSize == 100)
    }

    @Test func unselectedFindingsAndItemsAreNotPlanned() {
        let f = finding("a", .trash, items: [item("i1"), item("i2"), item("i3")])
        let g = finding("b", .trash)
        let p = RemovalPlan(findings: [f, g], selection: [f.id: ["i1", "i3"]],
                            options: RemovalOptions(deleteDirectly: [], zap: [], dryRun: false))
        #expect(p.trashSteps.count == 1)
        #expect(p.trashSteps[0].1.map(\.id) == ["i1", "i3"])
        #expect(p.totalSize == 200)
    }

    @Test func bigReviewItemsOfferDirectDelete() {
        let big = finding("big", .trash, risk: .review, size: 12_000_000_000)
        let small = finding("small", .trash, risk: .review, size: 1_000)
        let safeBig = finding("sb", .trash, risk: .safe, size: 12_000_000_000)
        let p1 = plan([big, small, safeBig])
        #expect(p1.directDeleteCandidates.map(\.id.key) == ["big"])
        #expect(p1.trashSteps.count == 3 && p1.deleteSteps.isEmpty)
        let p2 = plan([big, small, safeBig], direct: [big.id, small.id])
        #expect(p2.deleteSteps.map { $0.0.id.key } == ["big"])
        #expect(p2.trashSteps.map { $0.0.id.key } == ["small", "sb"])
        #expect(p2.commandPreview.contains { $0.hasPrefix("rm -rf ") })
    }

    @Test func adminCancelKeepsOtherResults() async throws {
        let rig = try Rig(adminResult: .cancelled)
        let fs = [finding("t", .trash), finding("a", .admin([adminStep]))]
        let report = await rig.runner.run(plan(fs)) { _ in }
        #expect(report.results.contains { $0.findingID.key == "t" && $0.outcome == .removed(freed: 100) })
        #expect(report.results.contains { $0.findingID.key == "a" && $0.outcome == .cancelled })
        #expect(report.failures.map(\.outcome) == [.cancelled])
    }

    @Test func adminBatchSkipsRunningAppsAndRunsOnce() async throws {
        let apps = FakeRunningApps(running: ["com.apple.dt.Xcode"])
        let rig = try Rig(apps: apps)
        let step2 = AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive/2023"])
        let fs = [finding("a", .admin([adminStep]), watched: [xcode]), finding("b", .admin([step2]))]
        let report = await rig.runner.run(plan(fs)) { _ in }
        #expect(rig.exec.runs.count == 1 && rig.exec.runs[0] == [step2])
        #expect(report.results.contains { $0.findingID.key == "a" && $0.outcome == .skipped("Xcode läuft – vorher beenden") })
    }

    @Test func zapAppendsFlag() {
        let f = finding("x", .tool([toolCmd], fallback: nil))
        let p = plan([f], zap: [f.id])
        guard case .tool(let cmds, _) = p.toolSteps[0].0.method else { Issue.record("tool"); return }
        #expect(cmds[0].arguments == ["uninstall", "--cask", "--zap", "foo"])
        #expect(p.commandPreview == ["brew uninstall --cask --zap foo"])
        let q = plan([f])
        #expect(q.commandPreview == ["brew uninstall --cask foo"])
    }

    @Test func commandPreviewCoversAllMethodsWithoutHash() {
        let fs = [
            finding("a", .admin([adminStep])), finding("d", .delete), finding("t", .trash),
            finding("x", .tool([toolCmd], fallback: nil)),
        ]
        let p = plan(fs)
        #expect(p.needsAdmin)
        #expect(p.commandPreview == [
            "brew uninstall --cask foo",
            "In den Papierkorb: /Users/x/Library/Caches/t-1",
            "rm -rf /Users/x/Library/Caches/d-1",
            "sudo /bin/rm -rf /usr/local/texlive/2022",
        ])
        #expect(!p.commandPreview.contains { $0.contains("#") })
    }

    @Test func dryRunIsPassedAndFreesNothing() async throws {
        let n = Mutex(0)
        let rig = try Rig(disk: { DiskSpace(free: Int64(n.withLock { $0 += 1_000; return $0 }), total: 0) })
        let report = await rig.runner.run(plan([finding("t", .trash)], dry: true)) { _ in }
        #expect(rig.trash.calls.first?.2 == true)
        #expect(report.freedBytes == 0)
    }

    @Test func failuresExcludeTrockenlauf() async throws {
        let rig = try Rig(adminResult: .completed([0]))
        let f = finding("a", .admin([adminStep]))
        let report = await rig.runner.run(plan([f], dry: true)) { _ in }
        #expect(report.results.map(\.outcome) == [.skipped("Trockenlauf")])
        #expect(report.failures.isEmpty)
    }

    @Test func freedBytesFromDiskDifference() async throws {
        let n = Mutex(0)
        let rig = try Rig(disk: { DiskSpace(free: n.withLock { $0 += 1; return $0 == 1 ? 1_000 : 5_000 }, total: 0) })
        let report = await rig.runner.run(plan([finding("t", .trash)])) { _ in }
        #expect(report.freedBytes == 4_000)
    }

    @Test func freedBytesFallsBackToSumWhenDiskSpaceThrows() async throws {
        let rig = try Rig(disk: { throw DiskInfoError.capacityUnavailable })
        let fs = [finding("t", .trash), finding("d", .delete)]
        let report = await rig.runner.run(plan(fs)) { _ in }
        #expect(report.freedBytes == 200)
    }

    @Test func progressIsReported() async throws {
        let rig = try Rig()
        let msgs = Mutex<[String]>([])
        _ = await rig.runner.run(plan([finding("t", .trash), finding("a", .admin([adminStep]))])) { m in msgs.withLock { $0.append(m) } }
        #expect(msgs.withLock { $0 } == ["Entferne: T-t", "Admin-Schritte (eine Passwortabfrage)"])
    }
}
