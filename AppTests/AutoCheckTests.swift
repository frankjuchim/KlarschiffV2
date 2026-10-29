import Foundation
import Synchronization
import Testing
import KlarschiffCore
@testable import Klarschiff

// MARK: - Fakes

/// Merkt sich An-/Abmeldungen; Status je plist frei setzbar (Standard: nicht angemeldet).
private final class FakeAgentService: AgentService, Sendable {
    private let state: Mutex<(statuses: [String: AgentStatus], registered: [String], unregistered: [String])>
    /// Status, den eine plist nach `register` meldet.
    private let statusAfterRegister: AgentStatus
    private let registerError: (any Error & Sendable)?

    init(statuses: [String: AgentStatus] = [:], statusAfterRegister: AgentStatus = .enabled,
         registerError: (any Error & Sendable)? = nil) {
        state = Mutex((statuses, [], []))
        self.statusAfterRegister = statusAfterRegister
        self.registerError = registerError
    }

    var registered: [String] { state.withLock { $0.registered } }
    var unregistered: [String] { state.withLock { $0.unregistered } }

    func register(_ plist: String) throws {
        if let registerError { throw registerError }
        let after = statusAfterRegister
        state.withLock { s in
            s.registered.append(plist)
            s.statuses[plist] = after
        }
    }

    func unregister(_ plist: String) async throws {
        state.withLock { s in
            s.unregistered.append(plist)
            s.statuses[plist] = .notRegistered
        }
    }

    func status(_ plist: String) -> AgentStatus { state.withLock { $0.statuses[plist] ?? .notRegistered } }
}

private final class FakeNotifier: Notifier, Sendable {
    private let allowed: Bool
    private let sentStore = Mutex<[CheckNotification]>([])
    init(allowed: Bool) { self.allowed = allowed }
    var sent: [CheckNotification] { sentStore.withLock { $0 } }
    func requestAuthorization() async -> Bool { allowed }
    func send(_ n: CheckNotification) async { sentStore.withLock { $0.append(n) } }
}

private struct StubScanner: KlarschiffCore.Scanner {
    let id = "test.scanner"
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

private struct NoRemover: Remover {
    func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] { [] }
}

private struct NoopExecutor: PrivilegedExecutor {
    func run(_ steps: [AdminStep]) async -> AdminRunResult { .completed(steps.map { _ in 0 }) }
}

private struct RegisterFailed: Error {}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "klarschiff-autocheck-\(UUID().uuidString)")
}

private func tempDefaults() -> UserDefaults {
    let name = "klarschiff-autocheck-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Ein aufräumbarer Fund von 2 GB → Alert „aufräumbar“; freier Platz 100 von 1000 Byte → „knapper Speicher“.
private func bigFinding() -> Finding {
    let item = FindingItem(id: "a", url: URL(filePath: "/tmp/klarschiff-test/a"), name: "a", size: 2_000_000_000)
    return Finding(
        id: FindingID(scannerID: "test.scanner", key: "big"), category: .appCaches, title: "Groß", summary: "",
        risk: .safe, method: .trash, items: [item], size: 2_000_000_000, blockingApps: [], keepSuggested: false,
        commandPreview: [], needsFullDiskAccess: false)
}

@MainActor
private func makeModel(
    notifier: FakeNotifier = FakeNotifier(allowed: true), agents: FakeAgentService = FakeAgentService(),
    history: CheckHistory = CheckHistory(fileURL: tempDir().appending(path: "history.json")),
    defaults: UserDefaults = tempDefaults()
) -> AppModel {
    let dir = tempDir()
    let disk: @Sendable () throws -> DiskSpace = { DiskSpace(free: 100, total: 1_000) }
    let runner = RemovalRunner(
        trash: NoRemover(), delete: NoRemover(), tool: NoRemover(),
        admin: AdminRemover(executor: NoopExecutor(), guard: SafetyGuard.production()),
        runningApps: NoRunningApps(), diskSpace: disk)
    let deps = AppDependencies(
        engine: ScanEngine(scanners: [StubScanner(findings: [bigFinding()])]),
        keepList: KeepList(fileURL: dir.appending(path: "keep.json")),
        runner: runner,
        diskSpace: disk,
        makeContext: { slow in
            ScanContext(
                home: dir, userCacheDir: dir, rootPrefix: dir, runner: NoCommands(),
                tools: ToolLocator(searchPaths: [], fileExists: { _ in false }), sizer: SizeMeter(),
                runningApps: NoRunningApps(), claims: PathClaims(), now: Date(), hasFullDiskAccess: false,
                includeSlowChecks: slow)
        },
        bigChunks: { _, _ in [] },
        photos: { _ in nil },
        trash: { _ in 0 },
        fullDiskAccess: { true },
        emptyTrash: { _ in RemovalReport(results: [], freedBytes: 0, failures: []) },
        measureSystemData: { _, _ in
            SystemDataReport(measuredAt: Date(), inventory: nil, areas: [], userData: 0, systemAreasTotal: 0,
                             unaccounted: 0, snapshotFindings: [], cleanupFindings: [], failures: [])
        },
        dryRun: true,
        terminate: { _ in false },
        history: history,
        measureSystemRoots: { _ in ["library": (title: "Bibliothek", size: 5_000)] },
        notifier: notifier,
        agentService: agents)
    return AppModel(dependencies: deps, defaults: defaults)
}

// MARK: - Planung

@Test func weeklyRegistersWeeklyUnregistersMonthly() async throws {
    let agents = FakeAgentService(statuses: [CheckScheduler.monthlyPlist: .enabled])
    let scheduler = CheckScheduler(service: agents)

    try await scheduler.apply(.weekly)

    #expect(CheckScheduler.weeklyPlist == "de.frankjuchim.klarschiff2.check.weekly.plist")
    #expect(CheckScheduler.monthlyPlist == "de.frankjuchim.klarschiff2.check.monthly.plist")
    #expect(agents.registered == [CheckScheduler.weeklyPlist])
    #expect(agents.unregistered == [CheckScheduler.monthlyPlist])
    #expect(scheduler.status(for: .weekly) == .enabled)
    #expect(scheduler.status(for: .monthly) == .notRegistered)
}

@Test func offUnregistersBoth() async throws {
    let agents = FakeAgentService(statuses: [
        CheckScheduler.weeklyPlist: .enabled, CheckScheduler.monthlyPlist: .requiresApproval,
    ])
    let scheduler = CheckScheduler(service: agents)

    try await scheduler.apply(.off)

    #expect(agents.registered.isEmpty)
    #expect(Set(agents.unregistered) == [CheckScheduler.weeklyPlist, CheckScheduler.monthlyPlist])
    #expect(scheduler.status(for: .off) == .notRegistered)
}

@Test func offDoesNotUnregisterWhatIsNotRegistered() async throws {
    let agents = FakeAgentService()
    try await CheckScheduler(service: agents).apply(.off)
    #expect(agents.unregistered.isEmpty)
}

@Test @MainActor func requiresApprovalSurfaced() async {
    let defaults = tempDefaults()
    let agents = FakeAgentService(statusAfterRegister: .requiresApproval)
    let model = makeModel(agents: agents, defaults: defaults)
    #expect(model.checkSchedule == .off)

    await model.setCheckSchedule(.weekly)

    #expect(model.checkSchedule == .weekly)
    #expect(model.agentStatus == .requiresApproval)
    #expect(defaults.string(forKey: AppModel.checkScheduleDefaultsKey) == "weekly")
    // Neues Modell liest die gespeicherte Einstellung.
    #expect(makeModel(agents: agents, defaults: defaults).checkSchedule == .weekly)
}

@Test @MainActor func registerFailureSetsErrorAndStatus() async {
    let agents = FakeAgentService(registerError: RegisterFailed())
    let model = makeModel(agents: agents)

    await model.setCheckSchedule(.monthly)

    #expect(model.lastError == AppErrorText.checkSchedule)
    #expect(model.agentStatus == .notRegistered)
}

// MARK: - Jetzt prüfen

@Test @MainActor func runCheckNowAppendsHistoryAndNotifies() async {
    let notifier = FakeNotifier(allowed: true)
    let history = CheckHistory(fileURL: tempDir().appending(path: "history.json"))
    let model = makeModel(notifier: notifier, history: history)

    await model.runCheckNow()

    #expect(await history.all().count == 1)
    #expect(model.checkHistory.count == 1)
    #expect(model.lastCheck?.cleanableTotal == 2_000_000_000)
    #expect(model.lastCheck?.sizes["systemdata.library"] == 5_000)
    #expect(notifier.sent.count == 1)
    #expect(notifier.sent.first?.title == "Klarschiff 2")
    #expect(model.notificationsDenied == false)
    #expect(model.isChecking == false)
}

@Test @MainActor func deniedNotificationsStillWritesHistory() async {
    let notifier = FakeNotifier(allowed: false)
    let history = CheckHistory(fileURL: tempDir().appending(path: "history.json"))
    let model = makeModel(notifier: notifier, history: history)

    await model.runCheckNow()

    #expect(await history.all().count == 1)
    #expect(model.checkHistory.count == 1)
    #expect(notifier.sent.isEmpty)
    #expect(model.notificationsDenied)
}

@Test @MainActor func runCheckNowBlockedWhileScanning() async {
    let history = CheckHistory(fileURL: tempDir().appending(path: "history.json"))
    let model = makeModel(history: history)
    model.isScanning = true

    await model.runCheckNow()

    #expect(await history.all().isEmpty)
}

@Test @MainActor func loadCheckHistoryReadsFile() async throws {
    let history = CheckHistory(fileURL: tempDir().appending(path: "history.json"))
    try await history.append(CheckSnapshot(date: Date(), cleanableTotal: 7, freeBytes: 1, totalBytes: 2,
                                           sizes: [:], titles: [:], alerts: []))
    let model = makeModel(history: history)

    await model.loadCheckHistory()

    #expect(model.lastCheck?.cleanableTotal == 7)
}

// MARK: - Mitteilungs-Klick

@Test @MainActor func notificationClickSetsTab() {
    let model = makeModel()
    model.openTab(fromNotification: "systemData")
    #expect(model.selectedTab == .systemData)
    model.openTab(fromNotification: "unsinn")
    #expect(model.selectedTab == .systemData)
    model.openTab(fromNotification: nil)
    #expect(model.selectedTab == .systemData)
    model.openTab(fromNotification: AppTab.developer.rawValue)
    #expect(model.selectedTab == .developer)
}

@Test func notificationUserInfoCarriesTab() {
    let n = CheckNotification(title: "Klarschiff 2", body: "x", tab: .systemData)
    #expect(UserNotificationCenterNotifier.userInfo(for: n)["tab"] as? String == "systemData")
}
