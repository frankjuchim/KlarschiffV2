import Foundation
import Synchronization
import Testing
import KlarschiffCore
@testable import Klarschiff

// MARK: - Attrappen

/// Gemeinsames Ereignisprotokoll für Befehle, Papierkorb und Admin – zeigt die Reihenfolge.
private final class ServiceLog: Sendable {
    private let store = Mutex<[String]>([])
    var events: [String] { store.withLock { $0 } }
    func add(_ e: String) { store.withLock { $0.append(e) } }
}

/// `bootout` → Erfolg (außer für `failing`); alles wird protokolliert.
private struct ServiceCommands: CommandRunner {
    let log: ServiceLog
    var failing: Set<String> = []
    func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]) async throws -> CommandResult {
        log.add(([executable] + arguments).joined(separator: " "))
        if arguments.first == "bootout", let target = arguments.last,
           failing.contains(where: { target.hasSuffix("/\($0)") }) {
            return CommandResult(exitCode: 5, stdout: "", stderr: "Input/output error")
        }
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private struct LoggingTrash: Remover {
    let log: ServiceLog
    func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] {
        log.add("trash dryRun=\(dryRun) " + items.map(\.id).sorted().joined(separator: ","))
        return items.map {
            ItemResult(findingID: finding.id, itemID: $0.id, outcome: dryRun ? .skipped("Trockenlauf") : .removed(freed: nil))
        }
    }
}

private struct LoggingExecutor: PrivilegedExecutor {
    let log: ServiceLog
    func run(_ steps: [AdminStep]) async -> AdminRunResult {
        log.add("admin " + steps.map { ([$0.executable] + $0.arguments).joined(separator: " ") }.joined(separator: " ; "))
        return .completed(steps.map { _ in 0 })
    }
}

private struct NoRemover: Remover {
    func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] { [] }
}

private struct NoRunningApps: RunningApps {
    func running(_ refs: [AppRef]) -> [AppRef] { [] }
    func terminate(_ ref: AppRef) async -> Bool { false }
}

private struct SilentNotifier: Notifier {
    func requestAuthorization() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func authorizationStatus() async -> NotificationAuthorization { .notDetermined }
    func send(_ n: CheckNotification) async {}
}

private struct NoAgents: AgentService {
    func register(_ plist: String) throws {}
    func unregister(_ plist: String) async throws {}
    func status(_ plist: String) -> AgentStatus { .notRegistered }
}

/// Liefert die aktuelle Dienstliste und zählt die Aufrufe; die Liste lässt sich zwischen Aufrufen ändern.
private final class ServiceSource: Sendable {
    private let state: Mutex<(items: [LaunchItem], failed: Bool, calls: Int)>
    init(_ items: [LaunchItem], failed: Bool = false) { state = Mutex((items, failed, 0)) }
    var calls: Int { state.withLock { $0.calls } }
    func load() -> ServicesLoad {
        state.withLock {
            $0.calls += 1
            return ServicesLoad(items: $0.items, loginItemsFailed: $0.failed)
        }
    }
}

private func tempHome() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "klarschiff-services-\(UUID().uuidString)")
}

private func tempDefaults() -> UserDefaults {
    let name = "klarschiff-services-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func svc(_ label: String, _ scope: LaunchScope, home: URL, orphaned: Bool = true, running: Bool = true,
                 own: Bool = false) -> LaunchItem {
    let plist: URL? = switch scope {
    case .user: home.appending(path: "Library/LaunchAgents/\(label).plist")
    case .allUsers: URL(filePath: "/Library/LaunchAgents/\(label).plist")
    case .system: URL(filePath: "/Library/LaunchDaemons/\(label).plist")
    case .loginItem: nil
    }
    return LaunchItem(id: "\(scope.rawValue)/\(label)", label: label, scope: scope, plistURL: plist,
                      isRunning: running, isOrphaned: orphaned, isOwnAgent: own,
                      displayName: label, explanation: "Test")
}

/// Drei entfernbare (Benutzer, Alle Benutzer, System) und drei nicht entfernbare Dienste.
private func fixtureItems(_ home: URL) -> [LaunchItem] {
    [
        svc("com.example.useragent", .user, home: home),
        svc("com.example.allagent", .allUsers, home: home),
        svc("com.example.daemon", .system, home: home),
        svc("com.example.fine", .user, home: home, orphaned: false),
        svc("com.example.login", .loginItem, home: home),
        svc("de.frankjuchim.klarschiff2.check.weekly", .user, home: home, own: true),
    ]
}

@MainActor
private func makeModel(
    home: URL, source: ServiceSource, log: ServiceLog = ServiceLog(), dryRun: Bool = false,
    failingBootouts: Set<String> = [], orphanedServices: @escaping CheckRunner.OrphanedServices = { _ in [] }
) -> AppModel {
    let disk: @Sendable () throws -> DiskSpace = { DiskSpace(free: 100, total: 1_000) }
    let guardForTests = SafetyGuard(home: home, userCacheDir: home.appending(path: "Caches"), allowedCacheSubdirs: [])
    let runner = RemovalRunner(
        trash: LoggingTrash(log: log), delete: NoRemover(), tool: NoRemover(),
        admin: AdminRemover(executor: LoggingExecutor(log: log), guard: guardForTests),
        runningApps: NoRunningApps(), diskSpace: disk)
    let commands = ServiceCommands(log: log, failing: failingBootouts)
    let deps = AppDependencies(
        engine: ScanEngine(scanners: []),
        keepList: KeepList(fileURL: home.appending(path: "keep.json")),
        runner: runner,
        diskSpace: disk,
        makeContext: { slow in
            ScanContext(
                home: home, userCacheDir: home, rootPrefix: home, runner: commands,
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
        dryRun: dryRun,
        terminate: { _ in false },
        history: CheckHistory(fileURL: home.appending(path: "history.json")),
        measureSystemRoots: { _ in [:] },
        notifier: SilentNotifier(),
        agentService: NoAgents(),
        loadServices: { _ in source.load() },
        orphanedServices: orphanedServices)
    return AppModel(dependencies: deps, defaults: tempDefaults())
}

private let removableIDs: Set<String> = ["user/com.example.useragent", "allUsers/com.example.allagent", "system/com.example.daemon"]

// MARK: - Laden und Auswahl

@Test @MainActor func servicesLoadedOnceAndNothingPreselected() async {
    let home = tempHome()
    let source = ServiceSource(fixtureItems(home), failed: true)
    let model = makeModel(home: home, source: source)

    await model.loadServicesIfNeeded()
    await model.loadServicesIfNeeded()

    #expect(source.calls == 1)
    #expect(model.services.count == 6)
    #expect(model.loginItemsFailed)
    #expect(model.isLoadingServices == false)
    #expect(model.selectedServices.isEmpty)
    #expect(model.makePlan(tab: .services, options: RemovalOptions()).allSteps.isEmpty)

    await model.reloadServices()
    #expect(source.calls == 2)
}

@Test @MainActor func servicesLoadBlockedWhileBusy() async {
    let home = tempHome()
    let source = ServiceSource(fixtureItems(home))
    let model = makeModel(home: home, source: source)
    model.isScanning = true
    await model.loadServicesIfNeeded()
    #expect(source.calls == 0)
    model.isScanning = false
    // Blockiert zählt nicht als „schon geladen“.
    await model.loadServicesIfNeeded()
    #expect(source.calls == 1)
    model.isChecking = true
    await model.reloadServices()
    #expect(source.calls == 1)
}

@Test @MainActor func onlyRemovableOrphansSelectable() async {
    let home = tempHome()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)))
    await model.reloadServices()

    for item in model.services { model.toggleService(item.id) }
    #expect(model.selectedServices == removableIDs)
    #expect(Set(model.services.filter(model.isServiceSelectable).map(\.id)) == removableIDs)

    model.toggleService("system/com.example.daemon")
    #expect(model.selectedServices == removableIDs.subtracting(["system/com.example.daemon"]))
}

@Test @MainActor func servicesPlanUsesRemovalFindings() async {
    let home = tempHome()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)), dryRun: true)
    await model.reloadServices()
    for id in removableIDs { model.toggleService(id) }

    let plan = model.makePlan(tab: .services, options: RemovalOptions())
    #expect(plan.options.dryRun)
    #expect(plan.trashSteps.map { $0.1.map(\.id) } == [["user/com.example.useragent"]])
    #expect(plan.adminSteps.map { Set($0.1.map(\.id)) } == [["allUsers/com.example.allagent", "system/com.example.daemon"]])
    #expect(plan.needsAdmin)
    #expect(plan.allSteps.allSatisfy { $0.0.category == .services })
}

// MARK: - Entfernen

@Test @MainActor func removeServicesBootoutThenPlanThenReload() async throws {
    let home = tempHome()
    let log = ServiceLog()
    let source = ServiceSource(fixtureItems(home))
    let model = makeModel(home: home, source: source, log: log)
    await model.reloadServices()
    let uid = getuid()
    for id in removableIDs { model.toggleService(id) }

    await model.removeServices(removableIDs)

    #expect(log.events == [
        "/bin/launchctl bootout gui/\(uid)/com.example.useragent",
        "/bin/launchctl bootout gui/\(uid)/com.example.allagent",
        "trash dryRun=false user/com.example.useragent",
        "admin /bin/rm -f /Library/LaunchAgents/com.example.allagent.plist ; "
            + "/bin/launchctl bootout system/com.example.daemon ; /bin/rm -f /Library/LaunchDaemons/com.example.daemon.plist",
    ])
    let report = try #require(model.lastRemoval)
    #expect(report.failures.isEmpty)
    #expect(Set(report.results.compactMap(\.itemID)) == removableIDs)
    #expect(model.lastRemovalWasDryRun == false)
    #expect(model.lastRemovalWasLegacy == false)
    #expect(model.isRemoving == false)
    // Vorher frisch eingelesen und danach neu geladen; die Auswahl ist leer.
    #expect(source.calls == 3)
    #expect(model.selectedServices.isEmpty)
    // Ergebnis-Banner kennt die Namen.
    let first = try #require(report.results.first)
    #expect(model.label(for: first).hasPrefix("Verwaiste Hintergrunddienste"))
}

@Test @MainActor func removeServicesDryRunMakesNoCalls() async throws {
    let home = tempHome()
    let log = ServiceLog()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)), log: log, dryRun: true)
    await model.reloadServices()

    await model.removeServices(removableIDs)

    #expect(!log.events.contains { $0.contains("bootout") || $0.hasPrefix("admin") })
    #expect(log.events == ["trash dryRun=true user/com.example.useragent"])
    #expect(model.lastRemovalWasDryRun)
    #expect(model.lastRemoval?.failures.isEmpty == true)
}

@Test @MainActor func failedBootoutKeepsServicePlist() async throws {
    let home = tempHome()
    let log = ServiceLog()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)), log: log,
                          failingBootouts: ["com.example.useragent", "com.example.allagent"])
    await model.reloadServices()

    await model.removeServices(removableIDs)

    // Weder Papierkorb für den Benutzer-Agent noch `rm` für den Alle-Benutzer-Agent – nur der Daemon.
    #expect(!log.events.contains { $0.hasPrefix("trash") })
    #expect(log.events.last == "admin /bin/launchctl bootout system/com.example.daemon ; /bin/rm -f /Library/LaunchDaemons/com.example.daemon.plist")
    #expect(Set(model.lastRemoval?.failures.compactMap(\.itemID) ?? []) == ["user/com.example.useragent", "allUsers/com.example.allagent"])
}

@Test @MainActor func removeServicesIgnoresNonRemovableIDs() async {
    let home = tempHome()
    let log = ServiceLog()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)), log: log)
    await model.reloadServices()

    await model.removeServices(["user/com.example.fine", "loginItem/com.example.login",
                                "user/de.frankjuchim.klarschiff2.check.weekly", "user/unknown"])

    #expect(log.events.isEmpty)
    #expect(model.lastRemoval == nil)
    #expect(model.isRemoving == false)
}

@Test @MainActor func removeServicesBlockedWhileBusy() async {
    let home = tempHome()
    let log = ServiceLog()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)), log: log)
    await model.reloadServices()
    model.isMeasuringSystemData = true

    await model.removeServices(removableIDs)

    #expect(log.events.isEmpty)
    #expect(model.lastRemoval == nil)
}

@Test @MainActor func executeOfServicesPlanTakesBootoutPath() async {
    let home = tempHome()
    let log = ServiceLog()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)), log: log)
    await model.reloadServices()
    model.toggleService("user/com.example.useragent")

    await model.execute(model.makePlan(tab: .services, options: RemovalOptions()))

    #expect(log.events == [
        "/bin/launchctl bootout gui/\(getuid())/com.example.useragent",
        "trash dryRun=false user/com.example.useragent",
    ])
}

// MARK: - Automatischer Check

@Test @MainActor func checkRecordsOrphanedServiceLabels() async {
    let home = tempHome()
    let model = makeModel(home: home, source: ServiceSource([]), orphanedServices: { _ in ["com.example.gone"] })
    await model.runCheckNow()
    #expect(model.lastCheck?.orphanedServiceLabels == ["com.example.gone"])
}

@Test func liveOrphanedServicesOnlyRemovable() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let agents = home.appending(path: "Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    func plist(_ label: String, program: String) throws {
        let dict: [String: Any] = ["Label": label, "Program": program]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: agents.appending(path: "\(label).plist"))
    }
    try plist("com.example.gone", program: "/Applications/Gone.app/Contents/MacOS/gone")
    try plist("com.example.fine", program: "/bin/sh")
    try plist("de.frankjuchim.klarschiff2.check.weekly", program: "/Applications/Gone.app/Contents/MacOS/gone")
    let ctx = ScanContext(
        home: home, userCacheDir: home, rootPrefix: home, runner: ServiceCommands(log: ServiceLog()),
        tools: ToolLocator(searchPaths: [], fileExists: { _ in false }), sizer: SizeMeter(),
        runningApps: NoRunningApps(), claims: PathClaims(), now: Date(), hasFullDiskAccess: false,
        includeSlowChecks: false)

    #expect(await BackgroundCheck.orphanedServicesLive(ctx) == ["com.example.gone"])
}

@Test func historyRowShowsOrphanedServices() {
    let s = CheckSnapshot(date: Date(), cleanableTotal: 0, freeBytes: 10, totalBytes: 100, sizes: [:], titles: [:],
                          alerts: [.lowSpace(free: 10, total: 100), .orphanedServices(labels: ["a", "b"])])
    #expect(CheckHistoryRow(s).alerts == ["2 neue verwaiste Hintergrunddienste", "Nur noch 10 Byte frei"])
}
