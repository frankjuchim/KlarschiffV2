import Foundation
import Testing
import KlarschiffCore
@testable import Klarschiff

// MARK: - Fakes

private struct StubScanner: KlarschiffCore.Scanner {
    let id: String
    let findings: [Finding]
    func scan(_ ctx: ScanContext) async throws -> [Finding] { findings }
}

private struct NoRunningApps: RunningApps {
    func running(_ refs: [AppRef]) -> [AppRef] { [] }
    func terminate(_ ref: AppRef) async -> Bool { false }
}

private struct NoCommands: CommandRunner {
    func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]) async throws -> CommandResult {
        CommandResult(exitCode: 127, stdout: "", stderr: "")
    }
}

private struct RecordingRemover: Remover {
    func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] {
        items.map {
            ItemResult(findingID: finding.id, itemID: $0.id, outcome: dryRun ? .skipped("Trockenlauf") : .removed(freed: $0.size))
        }
    }
}

private struct NoopExecutor: PrivilegedExecutor {
    func run(_ steps: [AdminStep]) async -> AdminRunResult { .completed(steps.map { _ in 0 }) }
}

private func item(_ id: String, size: Int64, blocking: AppRef? = nil) -> FindingItem {
    FindingItem(id: id, url: URL(filePath: "/tmp/klarschiff-test/\(id)"), name: id, size: size, blockingApp: blocking)
}

private func finding(
    _ key: String, category: KlarschiffCore.Category, risk: Risk, items: [FindingItem],
    method: RemovalMethod = .trash, scanner: String = "test.scanner"
) -> Finding {
    Finding(
        id: FindingID(scannerID: scanner, key: key), category: category, title: key, summary: "", risk: risk,
        method: method, items: items, size: items.reduce(0) { $0 + ($1.size ?? 0) }, blockingApps: [],
        keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)
}

private func tempKeepFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "klarschiff-apptests-\(UUID().uuidString)")
        .appending(path: "keep.json")
}

@MainActor
private func makeModel(_ findings: [Finding], keepFile: URL = tempKeepFile(), dryRun: Bool = false) -> AppModel {
    let disk: @Sendable () throws -> DiskSpace = { DiskSpace(free: 100, total: 1_000) }
    let safety = SafetyGuard.production()
    let runner = RemovalRunner(
        trash: RecordingRemover(), delete: RecordingRemover(), tool: RecordingRemover(),
        admin: AdminRemover(executor: NoopExecutor(), guard: safety),
        runningApps: NoRunningApps(), diskSpace: disk)
    let home = FileManager.default.temporaryDirectory.appending(path: "klarschiff-apptests-home")
    let deps = AppDependencies(
        engine: ScanEngine(scanners: [StubScanner(id: "test.scanner", findings: findings)]),
        keepList: KeepList(fileURL: keepFile),
        runner: runner,
        diskSpace: disk,
        makeContext: { slow in
            ScanContext(
                home: home, userCacheDir: home, rootPrefix: home, runner: NoCommands(),
                tools: ToolLocator(searchPaths: [], fileExists: { _ in false }), sizer: SizeMeter(),
                runningApps: NoRunningApps(), claims: PathClaims(), now: Date(), hasFullDiskAccess: false,
                includeSlowChecks: slow)
        },
        bigChunks: { _, _ in [] },
        photos: { _ in nil },
        trash: { _ in 0 },
        fullDiskAccess: { true },
        emptyTrash: { _ in RemovalReport(results: [], freedBytes: 0, failures: []) },
        dryRun: dryRun,
        terminate: { _ in false })
    return AppModel(dependencies: deps)
}

// MARK: - Tests

@Test @MainActor func scanPreselectsOnlySafe() async {
    let safe = finding("safe", category: .appCaches, risk: .safe, items: [item("a", size: 10), item("b", size: 20)])
    let review = finding("review", category: .appCaches, risk: .review, items: [item("c", size: 30)])
    let model = makeModel([safe, review])

    await model.scan(includeSlowChecks: false)

    #expect(model.selection == [safe.id: ["a", "b"]])
    #expect(model.isScanning == false)
    #expect(model.scanProgress == 1)
    #expect(model.disk == DiskSpace(free: 100, total: 1_000))
    #expect(model.hasFullDiskAccess)
}

@Test @MainActor func keptFindingDeselectedAndPersisted() async throws {
    let keepFile = tempKeepFile()
    let safe = finding("safe", category: .appCaches, risk: .safe, items: [item("a", size: 10)])
    let other = finding("other", category: .appCaches, risk: .safe, items: [item("b", size: 5)])
    let model = makeModel([safe, other], keepFile: keepFile)
    await model.scan(includeSlowChecks: false)
    #expect(model.selection[safe.id] == ["a"])

    await model.keep(safe.id)

    #expect(model.kept == [safe.id])
    #expect(model.selection[safe.id] == nil)
    #expect(await KeepList(fileURL: keepFile).contains(safe.id))
    #expect(model.findings(in: .storage).flatMap(\.1).map(\.id) == [other.id])
    #expect(model.keptFindings(in: .storage).map(\.id) == [safe.id])
    #expect(model.selectedSize(in: .storage) == 5)
    #expect(model.foundSize(in: .storage) == 5)

    // Neuer Lauf mit bestehender Behalten-Liste: bleibt abgewählt.
    let reloaded = makeModel([safe, other], keepFile: keepFile)
    await reloaded.scan(includeSlowChecks: false)
    #expect(reloaded.kept == [safe.id])
    #expect(reloaded.selection[safe.id] == nil)

    await reloaded.unkeep(safe.id)
    #expect(reloaded.kept.isEmpty)
    #expect(await KeepList(fileURL: keepFile).contains(safe.id) == false)
    #expect(reloaded.findings(in: .storage).flatMap(\.1).count == 2)
}

@Test @MainActor func sizesPerTab() async {
    let storageSafe = finding("s1", category: .appCaches, risk: .safe, items: [item("a", size: 100)])
    let storageReview = finding("s2", category: .system, risk: .review, items: [item("b", size: 50)])
    let devSafe = finding("d1", category: .xcode, risk: .safe, items: [item("c", size: 30)])
    let model = makeModel([storageSafe, storageReview, devSafe])
    await model.scan(includeSlowChecks: false)

    #expect(model.selectedSize(in: .storage) == 100)
    #expect(model.foundSize(in: .storage) == 150)
    #expect(model.selectedSize(in: .developer) == 30)
    #expect(model.foundSize(in: .developer) == 30)
    #expect(model.foundSize(in: .services) == 0)

    // Kategorien nach sortOrder, Funde nach Größe absteigend.
    let groups = model.findings(in: .storage)
    #expect(groups.map(\.0) == [.system, .appCaches])
    #expect(model.findings(in: .developer).map(\.0) == [.xcode])
}

@Test @MainActor func itemWithBlockingAppNotPreselected() async {
    let app = AppRef(bundleID: "com.example.app", processName: nil, displayName: "Beispiel")
    let f = finding("f", category: .appCaches, risk: .safe,
                    items: [item("blocked", size: 10, blocking: app), item("free", size: 20)])
    let onlyBlocked = finding("g", category: .appCaches, risk: .safe, items: [item("x", size: 1, blocking: app)])
    let model = makeModel([f, onlyBlocked])
    await model.scan(includeSlowChecks: false)

    #expect(model.selection[f.id] == ["free"])
    #expect(model.selection[onlyBlocked.id] == nil)   // leere Mengen werden nicht gespeichert
    #expect(model.selectedSize(in: .storage) == 20)
}

@Test @MainActor func hintOnlyExcludedFromSizes() async {
    let hint = finding("hint", category: .system, risk: .hintOnly, items: [item("h", size: 500)], method: .hint(nil))
    let safe = finding("safe", category: .system, risk: .safe, items: [item("a", size: 10)])
    let model = makeModel([hint, safe])
    await model.scan(includeSlowChecks: false)

    #expect(model.foundSize(in: .storage) == 10)
    #expect(model.selectedSize(in: .storage) == 10)
    model.toggle(hint.id)
    model.toggleItem(hint.id, item: "h")
    #expect(model.selection[hint.id] == nil)
    #expect(model.selectedSize(in: .storage) == 10)
}

@Test @MainActor func toggleSelectsAndClears() async {
    let app = AppRef(bundleID: "com.example.app", processName: nil, displayName: "Beispiel")
    let review = finding("r", category: .personalData, risk: .review,
                         items: [item("a", size: 1), item("b", size: 2, blocking: app)])
    let model = makeModel([review])
    await model.scan(includeSlowChecks: false)
    #expect(model.selection[review.id] == nil)

    model.toggle(review.id)
    #expect(model.selection[review.id] == ["a"])
    model.toggleItem(review.id, item: "b")
    #expect(model.selection[review.id] == ["a", "b"])
    model.toggle(review.id)
    #expect(model.selection[review.id] == nil)
    model.toggleItem(review.id, item: "a")
    #expect(model.selection[review.id] == ["a"])
    model.toggleItem(review.id, item: "a")
    #expect(model.selection[review.id] == nil)
}

@Test @MainActor func dryRunForcedIntoPlan() async {
    let safe = finding("safe", category: .appCaches, risk: .safe, items: [item("a", size: 10)])
    let dev = finding("dev", category: .xcode, risk: .safe, items: [item("b", size: 7)])

    let dry = makeModel([safe, dev], dryRun: true)
    await dry.scan(includeSlowChecks: false)
    let plan = dry.makePlan(tab: .storage, options: RemovalOptions())
    #expect(plan.options.dryRun)
    #expect(plan.totalSize == 10)              // nur Funde dieses Tabs
    #expect(plan.trashSteps.map(\.0.id) == [safe.id])

    let live = makeModel([safe], dryRun: false)
    await live.scan(includeSlowChecks: false)
    #expect(live.makePlan(tab: .storage, options: RemovalOptions()).options.dryRun == false)
}

@Test @MainActor func executeStoresReportAndRescans() async {
    let safe = finding("safe", category: .appCaches, risk: .safe, items: [item("a", size: 10)])
    let model = makeModel([safe], dryRun: true)
    await model.scan(includeSlowChecks: false)

    await model.execute(model.makePlan(tab: .storage, options: RemovalOptions()))

    #expect(model.lastRemoval?.results.count == 1)
    #expect(model.lastRemoval?.failures.isEmpty == true)
    #expect(model.removalProgress == nil)
    #expect(model.report?.findings.count == 1)
}

@Test @MainActor func failuresMapToTabByScannerCategory() {
    #expect(AppModel.category(forScannerID: "xcode.derivedData") == .xcode)
    #expect(AppModel.category(forScannerID: "sim.runtimes") == .simulators)
    #expect(AppModel.category(forScannerID: "brew.cask") == .homebrew)
    #expect(AppModel.category(forScannerID: "personal.backups") == .personalData)
    #expect(AppModel.category(forScannerID: "unknown") == nil)
}
