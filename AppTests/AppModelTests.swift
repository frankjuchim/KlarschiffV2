import Foundation
import Synchronization
import Testing
import KlarschiffCore
@testable import Klarschiff

// MARK: - Fakes

private struct StubScanner: KlarschiffCore.Scanner {
    let id: String
    let findings: [Finding]
    func scan(_ ctx: ScanContext) async throws -> [Finding] { findings }
}

/// Liefert beim n-ten Aufruf `rounds[min(n, rounds.count - 1)]` und zählt die Aufrufe.
private final class SequencedScanner: KlarschiffCore.Scanner, Sendable {
    let id = "test.scanner"
    private let rounds: [[Finding]]
    private let count = Mutex(0)
    init(_ rounds: [[Finding]]) { self.rounds = rounds }
    var calls: Int { count.withLock { $0 } }
    func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let n = count.withLock { c in defer { c += 1 }; return c }
        return rounds[min(n, rounds.count - 1)]
    }
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
private func makeModel(
    _ findings: [Finding], keepFile: URL = tempKeepFile(), dryRun: Bool = false,
    defaults: UserDefaults = tempDefaults(),
    scanner: (any KlarschiffCore.Scanner)? = nil,
    emptyTrash: @escaping @Sendable (Bool) async throws -> RemovalReport = { _ in
        RemovalReport(results: [], freedBytes: 0, failures: [])
    }
) -> AppModel {
    let disk: @Sendable () throws -> DiskSpace = { DiskSpace(free: 100, total: 1_000) }
    let safety = SafetyGuard.production()
    let runner = RemovalRunner(
        trash: RecordingRemover(), delete: RecordingRemover(), tool: RecordingRemover(),
        admin: AdminRemover(executor: NoopExecutor(), guard: safety),
        runningApps: NoRunningApps(), diskSpace: disk)
    let home = FileManager.default.temporaryDirectory.appending(path: "klarschiff-apptests-home")
    let deps = AppDependencies(
        engine: ScanEngine(scanners: [scanner ?? StubScanner(id: "test.scanner", findings: findings)]),
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
        emptyTrash: emptyTrash,
        dryRun: dryRun,
        terminate: { _ in false })
    return AppModel(dependencies: deps, defaults: defaults)
}

/// Frische, leere UserDefaults-Suite je Test.
private func tempDefaults() -> UserDefaults {
    let name = "klarschiff-apptests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
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

@Test @MainActor func toolFindingIsAllOrNothing() async {
    let app = AppRef(bundleID: "com.example.app", processName: nil, displayName: "Beispiel")
    let cmd = ToolCommand(tool: "brew", arguments: ["cleanup"], timeout: .seconds(5))
    let tool = finding("t", category: .homebrew, risk: .review,
                       items: [item("a", size: 1), item("b", size: 2, blocking: app)],
                       method: .tool([cmd], fallback: nil))
    let model = makeModel([tool])
    await model.scan(includeSlowChecks: false)
    #expect(model.selection[tool.id] == nil)

    model.toggleItem(tool.id, item: "a")
    #expect(model.selection[tool.id] == nil)
    model.toggle(tool.id)
    #expect(model.selection[tool.id] == ["a", "b"])
    model.toggleItem(tool.id, item: "a")
    #expect(model.selection[tool.id] == ["a", "b"])
    model.toggle(tool.id)
    #expect(model.selection[tool.id] == nil)
}

@Test func confirmDefaultActionOnlyWithoutDeleteOrAdmin() {
    func f(_ key: String, _ method: RemovalMethod) -> Finding {
        finding(key, category: .appCaches, risk: .safe, items: [item(key, size: 1)], method: method)
    }
    let cmd = ToolCommand(tool: "brew", arguments: ["cleanup"], timeout: .seconds(5))
    let step = AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive/2022"])
    func plan(_ fs: [Finding]) -> RemovalPlan {
        RemovalPlan(findings: fs, selection: Dictionary(uniqueKeysWithValues: fs.map { ($0.id, Set($0.items.map(\.id))) }),
                    options: RemovalOptions())
    }
    #expect(ConfirmSheet.allowsDefaultAction(plan([f("t", .trash), f("x", .tool([cmd], fallback: nil))])))
    #expect(!ConfirmSheet.allowsDefaultAction(plan([f("t", .trash), f("d", .delete)])))
    #expect(!ConfirmSheet.allowsDefaultAction(plan([f("a", .admin([step]))])))
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
    let after = finding("after", category: .appCaches, risk: .review, items: [item("z", size: 3)])
    let scanner = SequencedScanner([[safe], [after]])
    let model = makeModel([], dryRun: true, scanner: scanner)
    await model.scan(includeSlowChecks: false)
    #expect(scanner.calls == 1)

    await model.execute(model.makePlan(tab: .storage, options: RemovalOptions()))

    #expect(model.lastRemoval?.results.count == 1)
    #expect(model.lastRemoval?.failures.isEmpty == true)
    #expect(model.removalProgress == nil)
    #expect(model.isRemoving == false)
    #expect(scanner.calls == 2)
    #expect(model.report?.findings.map(\.id) == [after.id])
    #expect(model.selection.isEmpty)
    #expect(model.lastError == nil)
}

@Test @MainActor func executeRefusesLivePlanInDryRun() async {
    let safe = finding("safe", category: .appCaches, risk: .safe, items: [item("a", size: 10)])
    let scanner = SequencedScanner([[safe]])
    let model = makeModel([], dryRun: true, scanner: scanner)
    await model.scan(includeSlowChecks: false)

    let livePlan = RemovalPlan(findings: [safe], selection: model.selection, options: RemovalOptions(dryRun: false))
    await model.execute(livePlan)

    #expect(model.lastRemoval == nil)
    #expect(model.lastError != nil)
    #expect(scanner.calls == 1)       // kein Neu-Scan, nichts ausgeführt
}

@Test @MainActor func removalBlockedWhileScanningOrRemoving() async {
    let safe = finding("safe", category: .appCaches, risk: .safe, items: [item("a", size: 10)])
    let scanner = SequencedScanner([[safe]])
    let model = makeModel([], dryRun: true, scanner: scanner)
    await model.scan(includeSlowChecks: false)
    let plan = model.makePlan(tab: .storage, options: RemovalOptions())

    model.isScanning = true
    await model.execute(plan)
    await model.emptyTrash()
    #expect(model.lastRemoval == nil)
    model.isScanning = false

    model.isRemoving = true
    await model.execute(plan)
    await model.emptyTrash()
    await model.scan(includeSlowChecks: false)
    #expect(model.lastRemoval == nil)
    #expect(scanner.calls == 1)       // kein Scan während einer Entfernung
}

@Test @MainActor func keepFailurePublishesError() async throws {
    // Elternpfad ist eine Datei → Verzeichnis kann nicht angelegt werden.
    let blocker = FileManager.default.temporaryDirectory.appending(path: "klarschiff-apptests-blocker-\(UUID().uuidString)")
    try Data().write(to: blocker)
    let safe = finding("safe", category: .appCaches, risk: .safe, items: [item("a", size: 10)])
    let model = makeModel([safe], keepFile: blocker.appending(path: "keep.json"))
    await model.scan(includeSlowChecks: false)

    await model.keep(safe.id)

    #expect(model.kept.isEmpty)
    #expect(model.selection[safe.id] == ["a"])
    #expect(model.lastError == "Konnte die Behalten-Liste nicht speichern.")

    model.lastError = nil
    await model.unkeep(safe.id)
    #expect(model.lastError == "Konnte die Behalten-Liste nicht speichern.")
}

@Test @MainActor func emptyTrashFailurePublishesError() async {
    let model = makeModel([], emptyTrash: { _ in throw EmptyTrashError.failed("Boom") })
    await model.emptyTrash()
    #expect(model.lastRemoval == nil)
    #expect(model.lastError == "Papierkorb konnte nicht geleert werden: Boom")
    #expect(model.isRemoving == false)
}

private final class RecordingRunner: CommandRunner {
    private let calls = Mutex<[[String]]>([])
    let result: CommandResult
    init(_ result: CommandResult) { self.result = result }
    var recorded: [[String]] { calls.withLock { $0 } }
    func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]) async throws -> CommandResult {
        calls.withLock { $0.append([executable] + arguments + ["\(timeout)"]) }
        return result
    }
}

private let finderCall = ["/usr/bin/osascript", "-e", "tell application \"Finder\" to empty trash", "\(Duration.seconds(600))"]

@Test func finderEmptyTrashCallsOsascriptAndMeasuresFreed() async throws {
    let runner = RecordingRunner(CommandResult(exitCode: 0, stdout: "", stderr: ""))
    let free = Mutex<Int64>(100)
    let disk: @Sendable () throws -> DiskSpace = { DiskSpace(free: free.withLock { defer { $0 += 50 }; return $0 }, total: 1000) }
    let report = try await AppDependencies.emptyTrashViaFinder(runner: runner, disk: disk, dryRun: false)
    #expect(runner.recorded == [finderCall])
    #expect(report.freedBytes == 50)
    #expect(report.failures.isEmpty)
}

@Test func finderEmptyTrashDryRunDoesNothing() async throws {
    let runner = RecordingRunner(CommandResult(exitCode: 0, stdout: "", stderr: ""))
    let report = try await AppDependencies.emptyTrashViaFinder(
        runner: runner, disk: { DiskSpace(free: 1, total: 2) }, dryRun: true)
    #expect(runner.recorded.isEmpty)
    #expect(report.results.isEmpty && report.freedBytes == 0)
}

@Test @MainActor func finderAutomationDeniedPublishesPermissionMessage() async {
    let runner = RecordingRunner(CommandResult(
        exitCode: 1, stdout: "", stderr: "execution error: Nicht erlaubt (-1743)"))
    let model = makeModel([], emptyTrash: { dry in
        try await AppDependencies.emptyTrashViaFinder(runner: runner, disk: { DiskSpace(free: 1, total: 2) }, dryRun: dry)
    })
    await model.emptyTrash()
    #expect(model.lastError?.contains("Klarschiff 2 braucht die Erlaubnis, den Finder zu steuern") == true)
    #expect(model.lastError?.contains("Datenschutz & Sicherheit → Automation") == true)
    #expect(model.lastRemoval == nil)
}

@Test @MainActor func failuresMapToTabByScannerCategory() {
    #expect(AppModel.category(forScannerID: "xcode.derivedData") == .xcode)
    #expect(AppModel.category(forScannerID: "sim.runtimes") == .simulators)
    #expect(AppModel.category(forScannerID: "brew.cask") == .homebrew)
    #expect(AppModel.category(forScannerID: "personal.backups") == .personalData)
    #expect(AppModel.category(forScannerID: "unknown") == nil)
}

@Test @MainActor func failureLabelSurvivesRescan() async {
    let gone = Finding(
        id: FindingID(scannerID: "test.scanner", key: "gone"), category: .appCaches, title: "Alter Cache",
        summary: "", risk: .safe, method: .trash, items: [FindingItem(id: "a", url: URL(filePath: "/tmp/klarschiff-test/a"), name: "Datei A", size: 5)],
        size: 5, blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)
    let scanner = SequencedScanner([[gone], []])
    let model = makeModel([], scanner: scanner)
    await model.scan(includeSlowChecks: false)

    await model.execute(model.makePlan(tab: .storage, options: RemovalOptions()))

    #expect(model.report?.findings.isEmpty == true)
    #expect(model.label(for: ItemResult(findingID: gone.id, itemID: "a", outcome: .failed("x"))) == "Alter Cache – Datei A")
    #expect(model.label(for: ItemResult(findingID: gone.id, itemID: nil, outcome: .failed("x"))) == "Alter Cache")
    let unknown = FindingID(scannerID: "system.trash", key: "all")
    #expect(model.label(for: ItemResult(findingID: unknown, itemID: "foo.txt", outcome: .failed("x"))) == "foo.txt")
}

// MARK: - Trockenlauf-Schalter

@Test @MainActor func dryRunToggleForcesPlanAndPersists() async {
    let safe = finding("safe", category: .appCaches, risk: .safe, items: [item("a", size: 10)])
    let defaults = tempDefaults()
    let model = makeModel([safe], dryRun: false, defaults: defaults)
    await model.scan(includeSlowChecks: false)
    #expect(model.dryRun == false)
    #expect(model.isDryRunForced == false)

    model.setDryRunSetting(true)
    #expect(model.dryRun)
    #expect(model.makePlan(tab: .storage, options: RemovalOptions()).options.dryRun)
    #expect(defaults.bool(forKey: AppModel.dryRunDefaultsKey))
    #expect(AppModel.dryRunDefaultsKey == "dryRun")

    // Ein echter Plan wird bei eingeschaltetem Schalter verweigert.
    let livePlan = RemovalPlan(findings: [safe], selection: model.selection, options: RemovalOptions(dryRun: false))
    await model.execute(livePlan)
    #expect(model.lastRemoval == nil)
    #expect(model.lastError == AppErrorText.dryRunPlan)

    // Gespeichert: ein neues Modell mit denselben Defaults startet im Trockenlauf.
    #expect(makeModel([], dryRun: false, defaults: defaults).dryRun)

    model.setDryRunSetting(false)
    #expect(model.dryRun == false)
    #expect(model.makePlan(tab: .storage, options: RemovalOptions()).options.dryRun == false)
}

@Test @MainActor func dryRunForcedByLaunchFlagCannotBeSwitchedOff() async {
    let safe = finding("safe", category: .appCaches, risk: .safe, items: [item("a", size: 10)])
    let defaults = tempDefaults()
    let model = makeModel([safe], dryRun: true, defaults: defaults)
    await model.scan(includeSlowChecks: false)
    #expect(model.isDryRunForced)
    #expect(model.dryRun)

    model.setDryRunSetting(false)
    #expect(model.dryRun)
    #expect(model.makePlan(tab: .storage, options: RemovalOptions()).options.dryRun)
}

@Test @MainActor func emptyTrashUsesToggledDryRun() async {
    let seen = Mutex<Bool?>(nil)
    let model = makeModel([], dryRun: false, emptyTrash: { dry in
        seen.withLock { $0 = dry }
        return RemovalReport(results: [], freedBytes: 0, failures: [])
    })
    model.setDryRunSetting(true)
    await model.emptyTrash()
    #expect(seen.withLock { $0 } == true)
}

// MARK: - Reine UI-Helfer

@Test func hintCardHidesEmptySize() {
    func hint(size: Int64?, fda: Bool = false) -> Finding {
        Finding(
            id: FindingID(scannerID: "test.scanner", key: "h"), category: .appCaches, title: "h", summary: "",
            risk: .hintOnly, method: .hint(nil), items: [], size: size, blockingApps: [], keepSuggested: false,
            commandPreview: [], needsFullDiskAccess: fda)
    }
    #expect(FindingCard.hidesSizeColumn(hint(size: nil)))
    #expect(FindingCard.hidesSizeColumn(hint(size: 0)))
    #expect(!FindingCard.hidesSizeColumn(hint(size: 5_000)))
    #expect(!FindingCard.hidesSizeColumn(hint(size: nil, fda: true)))   // „braucht Vollzugriff“ bleibt sichtbar
    let review = finding("r", category: .appCaches, risk: .review, items: [])
    #expect(!FindingCard.hidesSizeColumn(review))
}

@Test func confirmGroupsTextsAndDirectDeleteMove() {
    let big = RemovalPlan.directDeleteThreshold + 1
    let trash = finding("trash", category: .appCaches, risk: .safe, items: [item("t", size: 1)])
    let huge = finding("huge", category: .apps, risk: .review, items: [item("h", size: big)])
    let del = finding("del", category: .appCaches, risk: .safe, items: [item("d", size: 2)], method: .delete)
    let step = AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive/2022"])
    let admin = finding("admin", category: .toolchains, risk: .review, items: [item("a", size: 3)], method: .admin([step]))
    let cmd = ToolCommand(tool: "/opt/homebrew/bin/brew", arguments: ["cleanup"], timeout: .seconds(5))
    let tool = finding("tool", category: .homebrew, risk: .safe, items: [item("x", size: 4)], method: .tool([cmd], fallback: nil))
    let all = [trash, huge, del, admin, tool]
    let selection = Dictionary(uniqueKeysWithValues: all.map { ($0.id, Set($0.items.map(\.id))) })

    let groups = ConfirmSheet.groups(for: RemovalPlan(findings: all, selection: selection, options: RemovalOptions()))
    #expect(groups.map(\.text) == [
        "Über brew entfernt – direkt, nicht im Papierkorb", "In den Papierkorb",
        "Wird direkt gelöscht – nicht im Papierkorb", "Braucht dein Admin-Passwort (eine Abfrage)",
    ])
    #expect(groups.first { $0.id == "tool-brew" }?.emphasized == true)
    #expect(groups.first { $0.id == "trash" }?.rows.map(\.title) == ["trash", "huge"])
    #expect(groups.first { $0.id == "delete" }?.rows.map(\.title) == ["del"])
    #expect(groups.first { $0.id == "delete" }?.emphasized == true)
    #expect(groups.first { $0.id == "admin" }?.rows.map(\.size) == [3])

    // „Direkt löschen“ verschiebt den Kandidaten vom Papierkorb in die Lösch-Gruppe.
    let moved = ConfirmSheet.groups(for: RemovalPlan(
        findings: all, selection: selection, options: RemovalOptions(deleteDirectly: [huge.id])))
    #expect(moved.first { $0.id == "trash" }?.rows.map(\.title) == ["trash"])
    #expect(moved.first { $0.id == "delete" }?.rows.map(\.title) == ["huge", "del"])
}

@Test func hintOpenLabelAndFailureText() {
    #expect(HintActionButton.openLabel(for: URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
            == "Softwareupdate öffnen")
    #expect(HintActionButton.openLabel(for: URL(string: "https://example.com")!) == "Öffnen")
    #expect(ResultBanner.failureText(1) == "1 Eintrag konnte nicht entfernt werden.")
    #expect(ResultBanner.failureText(3) == "3 Einträge konnten nicht entfernt werden.")
}

@Test @MainActor func removalDryRunFlagRecordedPerRun() async {
    let safe = finding("safe", category: .appCaches, risk: .safe, items: [item("a", size: 10)])
    let scanner = SequencedScanner([[safe]])

    // Echter Lauf, danach Schalter an → bleibt „kein Trockenlauf“.
    let live = makeModel([], dryRun: false, scanner: scanner)
    await live.scan(includeSlowChecks: false)
    await live.execute(live.makePlan(tab: .storage, options: RemovalOptions()))
    #expect(live.lastRemoval != nil)
    #expect(live.lastRemovalWasDryRun == false)
    live.setDryRunSetting(true)
    #expect(live.lastRemovalWasDryRun == false)

    // Trockenlauf, danach Schalter aus → bleibt „Trockenlauf“.
    let dry = makeModel([safe], dryRun: false)
    dry.setDryRunSetting(true)
    await dry.scan(includeSlowChecks: false)
    await dry.execute(dry.makePlan(tab: .storage, options: RemovalOptions()))
    #expect(dry.lastRemovalWasDryRun)
    dry.setDryRunSetting(false)
    #expect(dry.lastRemovalWasDryRun)

    // Papierkorb leeren übernimmt den Trockenlauf des Laufs.
    dry.setDryRunSetting(false)
    await dry.emptyTrash()
    #expect(dry.lastRemovalWasDryRun == false)
    dry.setDryRunSetting(true)
    await dry.emptyTrash()
    #expect(dry.lastRemovalWasDryRun)
}
