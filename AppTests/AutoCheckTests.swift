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

/// Zählt Erlaubnis-Anfragen (Dialog) und Status-Abfragen getrennt.
private final class FakeNotifier: Notifier, Sendable {
    private let allowed: Bool
    /// Gespeicherter Entscheid; ohne Angabe aus `allowed` abgeleitet (erlaubt / abgelehnt).
    private let status: NotificationAuthorization?
    private let store = Mutex<(sent: [CheckNotification], requests: Int, checks: Int)>(([], 0, 0))
    init(allowed: Bool, status: NotificationAuthorization? = nil) {
        self.allowed = allowed
        self.status = status
    }
    var sent: [CheckNotification] { store.withLock { $0.sent } }
    var requestCalls: Int { store.withLock { $0.requests } }
    var isAuthorizedCalls: Int { store.withLock { $0.checks } }
    func requestAuthorization() async -> Bool {
        store.withLock { $0.requests += 1 }
        return allowed
    }
    func isAuthorized() async -> Bool {
        store.withLock { $0.checks += 1 }
        return allowed
    }
    func authorizationStatus() async -> NotificationAuthorization {
        status ?? (allowed ? .authorized : .denied)
    }
    func send(_ n: CheckNotification) async { store.withLock { $0.sent.append(n) } }
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
    makeModelWith(notifier: notifier, agents: agents, history: history, defaults: defaults)
}

@MainActor
private func makeModelWith(
    notifier: any Notifier, agents: FakeAgentService = FakeAgentService(),
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
        measureSystemRoots: { _ in ["library": (title: "Bibliothek", size: 5_000, isLowerBound: false)] },
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
    #expect(model.checkScheduleError == AppErrorText.checkSchedule)
    #expect(model.agentStatus == .notRegistered)

    // Ausschalten gelingt → Fehler in den Einstellungen verschwindet.
    await model.setCheckSchedule(.off)
    #expect(model.checkScheduleError == nil)
}

/// Hält `requestAuthorization` an, bis `release()` – und merkt sich, was beim Fragen schon angemeldet war.
private final class GatedNotifier: Notifier, Sendable {
    private let agents: FakeAgentService
    private let state = Mutex<(requests: Int, registeredAtRequest: [String], waiting: CheckedContinuation<Void, Never>?, released: Bool)>(
        (0, [], nil, false))
    init(agents: FakeAgentService, released: Bool = false) {
        self.agents = agents
        state.withLock { $0.released = released }
    }
    var requestCalls: Int { state.withLock { $0.requests } }
    var registeredAtRequest: [String] { state.withLock { $0.registeredAtRequest } }
    func release() {
        let c: CheckedContinuation<Void, Never>? = state.withLock { s in
            s.released = true
            defer { s.waiting = nil }
            return s.waiting
        }
        c?.resume()
    }
    func requestAuthorization() async -> Bool {
        let registered = agents.registered
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s in
                s.requests += 1
                s.registeredAtRequest = registered
                if s.released { return true }
                s.waiting = c
                return false
            }
            if resumeNow { c.resume() }
        }
        return true
    }
    func isAuthorized() async -> Bool { true }
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func send(_ n: CheckNotification) async {}
}

@Test @MainActor func registersBeforeAskingForNotifications() async {
    let agents = FakeAgentService()
    let notifier = GatedNotifier(agents: agents, released: true)
    let model = makeModelWith(notifier: notifier, agents: agents)

    await model.setCheckSchedule(.weekly)

    #expect(notifier.requestCalls == 1)
    #expect(notifier.registeredAtRequest == [CheckScheduler.weeklyPlist])
    #expect(model.agentStatus == .enabled)
}

@Test @MainActor func scheduleChangesAreSerialised() async {
    let agents = FakeAgentService()
    let notifier = GatedNotifier(agents: agents)
    let model = makeModelWith(notifier: notifier, agents: agents)

    let first = Task { await model.setCheckSchedule(.weekly) }
    while notifier.requestCalls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
    // Während die Frage offen ist: neuer Wunsch wird nur gemerkt.
    await model.setCheckSchedule(.monthly)
    #expect(agents.registered == [CheckScheduler.weeklyPlist])
    #expect(model.checkSchedule == .monthly)

    notifier.release()
    await first.value

    #expect(agents.registered == [CheckScheduler.weeklyPlist, CheckScheduler.monthlyPlist])
    #expect(agents.unregistered == [CheckScheduler.weeklyPlist])
    #expect(model.agentStatus == .enabled)
    #expect(notifier.requestCalls == 1)
}

@Test @MainActor func launchReappliesUnregisteredSchedule() async {
    let defaults = tempDefaults()
    defaults.set("weekly", forKey: AppModel.checkScheduleDefaultsKey)
    let agents = FakeAgentService()
    let notifier = FakeNotifier(allowed: true)
    let model = makeModel(notifier: notifier, agents: agents, defaults: defaults)
    #expect(model.agentStatus == .notRegistered)

    await model.reapplyScheduleIfNeeded()
    #expect(agents.registered == [CheckScheduler.weeklyPlist])
    #expect(model.agentStatus == .enabled)
    #expect(notifier.requestCalls == 0)

    // Schon angemeldet bzw. aus: nichts tun.
    await model.reapplyScheduleIfNeeded()
    #expect(agents.registered == [CheckScheduler.weeklyPlist])
    let off = FakeAgentService()
    await makeModel(agents: off).reapplyScheduleIfNeeded()
    #expect(off.registered.isEmpty)
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
    // Der Check fragt nie (kein Dialog aus dem Hintergrund), er liest nur den Entscheid.
    #expect(notifier.requestCalls == 0)
    #expect(notifier.isAuthorizedCalls == 1)
}

@Test @MainActor func onlySwitchingOnRequestsAuthorization() async {
    let notifier = FakeNotifier(allowed: false)
    let model = makeModel(notifier: notifier)

    await model.setCheckSchedule(.off)
    #expect(notifier.requestCalls == 0)

    await model.setCheckSchedule(.weekly)
    #expect(notifier.requestCalls == 1)
    #expect(model.notificationsDenied)

    await model.runCheckNow()
    #expect(notifier.requestCalls == 1)
}

@Test @MainActor func noRemovalOrScanDuringCheck() async {
    let model = makeModel()
    model.isChecking = true

    await model.scan(includeSlowChecks: false)
    #expect(model.report == nil)
    await model.emptyTrash()
    #expect(model.lastRemoval == nil)
    await model.execute(RemovalPlan(findings: [], selection: [:], options: RemovalOptions(dryRun: true)))
    #expect(model.lastRemoval == nil)
}

// MARK: - Wächter

@Test func watchdogEndsHangingRun() async {
    let start = ContinuousClock.now
    // Hängt für immer und ignoriert Abbruch.
    let result: Int? = await BackgroundCheck.withTimeout(.milliseconds(50)) {
        await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in }
    }
    #expect(result == nil)
    #expect(ContinuousClock.now - start < .seconds(5))
}

@Test func watchdogPassesFastRunThrough() async {
    let result = await BackgroundCheck.withTimeout(.seconds(10)) { 42 }
    #expect(result == 42)
}

// MARK: - LaunchAgent-plists

private func plistDict(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

@Test(arguments: [
    (CheckScheduler.weeklyPlist, ["Weekday": 0, "Hour": 10, "Minute": 0]),
    (CheckScheduler.monthlyPlist, ["Day": 1, "Hour": 10, "Minute": 0]),
])
func launchAgentPlistsMatchSpec(name: String, calendar: [String: Int]) throws {
    let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App/LaunchAgents/\(name)")
    let p = try plistDict(source)
    #expect(p["Label"] as? String == String(name.dropLast(".plist".count)))
    #expect(p["BundleProgram"] as? String == "Contents/MacOS/Klarschiff 2")
    #expect(p["ProgramArguments"] as? [String] == ["Klarschiff 2", "--check"])
    #expect(p["StartCalendarInterval"] as? [String: Int] == calendar)
    #expect(p["ProcessType"] as? String == "Background")
    #expect(p["LowPriorityIO"] as? Bool == true)
    #expect(p["Nice"] as? Int == 10)
    #expect(p["AssociatedBundleIdentifiers"] as? [String] == ["de.frankjuchim.klarschiff2"])
    // Dieselbe Datei liegt im gebauten Bundle (Test-Host = App).
    let bundled = Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/\(name)")
    #expect(try Data(contentsOf: bundled) == Data(contentsOf: source))
}

@Test @MainActor func deniedNotificationsStillWritesHistory() async {
    let notifier = FakeNotifier(allowed: false)
    let history = CheckHistory(fileURL: tempDir().appending(path: "history.json"))
    let model = makeModel(notifier: notifier, history: history)
    await model.refreshNotificationStatus()

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
    #expect(UserNotificationCenterNotifier.userInfo(for: n)["tab"] == "systemData")
}

// MARK: - Mitteilungs-Erlaubnis

@Test @MainActor func notificationStatusDistinguishesNotAskedFromDenied() async {
    let notAsked = makeModel(notifier: FakeNotifier(allowed: false, status: .notDetermined))
    await notAsked.refreshNotificationStatus()
    #expect(notAsked.notificationStatus == .notDetermined)
    #expect(notAsked.notificationsDenied == false)
    // Ein Check ohne Erlaubnis macht aus „nie gefragt“ kein „abgelehnt“.
    await notAsked.runCheckNow()
    #expect(notAsked.notificationStatus == .notDetermined)

    let denied = makeModel(notifier: FakeNotifier(allowed: false, status: .denied))
    await denied.refreshNotificationStatus()
    #expect(denied.notificationStatus == .denied)
    #expect(denied.notificationsDenied)

    let allowed = makeModel(notifier: FakeNotifier(allowed: true))
    await allowed.setCheckSchedule(.weekly)
    #expect(allowed.notificationStatus == .authorized)
}
