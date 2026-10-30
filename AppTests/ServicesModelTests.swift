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
    var cancel = false
    func run(_ steps: [AdminStep]) async -> AdminRunResult {
        log.add("admin " + steps.map { ([$0.executable] + $0.arguments).joined(separator: " ") }.joined(separator: " ; "))
        return cancel ? .cancelled : .completed(steps.map { _ in 0 })
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
/// `calls`: volles Einlesen (mit `sfltool`), `agentCalls`: nur LaunchAgents/-Daemons.
private final class ServiceSource: Sendable {
    private let state: Mutex<(items: [LaunchItem], failed: Bool, calls: Int, agentCalls: Int)>
    init(_ items: [LaunchItem], failed: Bool = false) { state = Mutex((items, failed, 0, 0)) }
    var calls: Int { state.withLock { $0.calls } }
    var agentCalls: Int { state.withLock { $0.agentCalls } }
    func set(_ items: [LaunchItem], failed: Bool) { state.withLock { $0.items = items; $0.failed = failed } }
    func load() -> ServicesLoad {
        state.withLock {
            $0.calls += 1
            return ServicesLoad(items: $0.items, loginItemsFailed: $0.failed)
        }
    }
    func loadAgents() -> [LaunchItem] {
        state.withLock {
            $0.agentCalls += 1
            return $0.items.filter { $0.scope != .loginItem }
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
    failingBootouts: Set<String> = [], cancelAdmin: Bool = false, orphanedServices: @escaping CheckRunner.OrphanedServices = { _ in [] }
) -> AppModel {
    let disk: @Sendable () throws -> DiskSpace = { DiskSpace(free: 100, total: 1_000) }
    let guardForTests = SafetyGuard(home: home, userCacheDir: home.appending(path: "Caches"), allowedCacheSubdirs: [])
    let runner = RemovalRunner(
        trash: LoggingTrash(log: log), delete: NoRemover(), tool: NoRemover(),
        admin: AdminRemover(executor: LoggingExecutor(log: log, cancel: cancelAdmin), guard: guardForTests),
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
        loadLaunchItems: { _ in source.loadAgents() },
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

    // Benutzer-Agent vor dem Papierkorb stoppen, Alle-Benutzer-Agent erst nach dem Admin-Schritt.
    #expect(log.events == [
        "/bin/launchctl bootout gui/\(uid)/com.example.useragent",
        "trash dryRun=false user/com.example.useragent",
        "admin /bin/rm -f /Library/LaunchAgents/com.example.allagent.plist ; "
            + "/bin/launchctl bootout system/com.example.daemon ; /bin/rm -f /Library/LaunchDaemons/com.example.daemon.plist",
        "/bin/launchctl bootout gui/\(uid)/com.example.allagent",
    ])
    let report = try #require(model.lastRemoval)
    #expect(report.failures.isEmpty)
    #expect(Set(report.results.compactMap(\.itemID)) == removableIDs)
    #expect(model.lastRemovalWasDryRun == false)
    #expect(model.lastRemovalWasLegacy == false)
    #expect(model.lastRemovalWasServices)
    #expect(ResultBanner.headline(report, legacy: model.lastRemovalWasLegacy, services: model.lastRemovalWasServices,
                                  dryRun: model.lastRemovalWasDryRun) == "Hintergrunddienste entfernt.")
    #expect(model.isRemoving == false)
    // Vorher frisch eingelesen (nur Agents, kein sfltool) und danach voll neu geladen; die Auswahl ist leer.
    #expect(source.agentCalls == 1)
    #expect(source.calls == 2)
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
    #expect(model.lastRemovalWasServices)
    #expect(ResultBanner.headline(model.lastRemoval!, legacy: false, services: true, dryRun: true)
        == "Hintergrunddienste entfernt. (Trockenlauf)")
}

// MARK: - Tab-Ansicht

@Test @MainActor func servicesConfirmNeedsAcknowledgementOnlyWithAdminSteps() async {
    let home = tempHome()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)))
    await model.reloadServices()

    // Nur Benutzer-Agent: Papierkorb, kein Häkchen, Return erlaubt.
    model.toggleService("user/com.example.useragent")
    let userPlan = model.makePlan(tab: .services, options: RemovalOptions())
    #expect(ConfirmSheet.isServicesPlan(userPlan))
    #expect(ConfirmSheet.title(userPlan) == "Hintergrunddienste entfernen?")
    #expect(!ConfirmSheet.requiresSystemAcknowledgement(userPlan))
    #expect(ConfirmSheet.allowsDefaultAction(userPlan))
    #expect(ConfirmSheet.systemWarningLines(userPlan).isEmpty)

    // Mit System-Daemon: Admin-Schritte → rotes Häkchen, nie Return.
    model.toggleService("system/com.example.daemon")
    let adminPlan = model.makePlan(tab: .services, options: RemovalOptions())
    #expect(ConfirmSheet.requiresSystemAcknowledgement(adminPlan))
    #expect(!ConfirmSheet.allowsDefaultAction(adminPlan))
    #expect(ConfirmSheet.systemWarningLines(adminPlan) == [ConfirmSheet.servicesAdminWarning])
}

@Test @MainActor func servicesCommandPreviewInExecutionOrder() async {
    let home = tempHome()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)))
    await model.reloadServices()
    let uid = getuid()
    let lines = model.serviceCommandLines(for: removableIDs)
    #expect(lines == [
        "/bin/launchctl bootout gui/\(uid)/com.example.useragent",
        "In den Papierkorb: " + home.appending(path: "Library/LaunchAgents/com.example.useragent.plist").path,
        "sudo /bin/rm -f /Library/LaunchAgents/com.example.allagent.plist",
        "sudo /bin/launchctl bootout system/com.example.daemon",
        "sudo /bin/rm -f /Library/LaunchDaemons/com.example.daemon.plist  # nur wenn der Dienst gestoppt wurde",
        "/bin/launchctl bootout gui/\(uid)/com.example.allagent",
    ])
    #expect(model.serviceCommandLines(for: ["user/com.example.fine"]).isEmpty)
}

@Test func servicesSectionsGroupByScope() {
    let home = tempHome()
    let s = ServicesTabView.sections(fixtureItems(home))
    #expect(s.orphaned.map(\.id) == ["user/com.example.useragent", "allUsers/com.example.allagent",
                                     "system/com.example.daemon", "loginItem/com.example.login"])
    #expect(s.active.map(\.scope) == [.user])
    #expect(s.active.first?.items.map(\.id) == ["user/com.example.fine", "user/de.frankjuchim.klarschiff2.check.weekly"])

    let more = [svc("a", .system, home: home, orphaned: false), svc("b", .loginItem, home: home, orphaned: false),
                svc("c", .user, home: home, orphaned: false), svc("d", .allUsers, home: home, orphaned: false)]
    #expect(ServicesTabView.sections(more).active.map(\.scope) == [.user, .allUsers, .system, .loginItem])
    #expect(ServicesTabView.sections([]).orphaned.isEmpty && ServicesTabView.sections([]).active.isEmpty)
}

@Test func servicesHeadlineTexts() {
    #expect(ServicesTabView.headline(orphanedCount: 0) == (nil, "Keine verwaisten Hintergrunddienste"))
    #expect(ServicesTabView.headline(orphanedCount: 1) == ("1", "verwaister Hintergrunddienst"))
    #expect(ServicesTabView.headline(orphanedCount: 3) == ("3", "verwaiste Hintergrunddienste"))
    #expect(ServicesTabView.subtitle == "Dienste, deren App gelöscht wurde, laufen sonst weiter oder starten ins Leere.")
}

@Test func serviceRowTexts() {
    let home = tempHome()
    var installed = svc("com.example.app", .user, home: home, orphaned: false)
    installed.appURL = URL(filePath: "/Applications/Example.app")
    #expect(ServiceRow.statusText(installed) == "App ist installiert.")
    var none = svc("com.example.none", .user, home: home, orphaned: false)
    none.hasNoKnownApp = true
    #expect(ServiceRow.statusText(none) == "Gehört zu keiner App")
    var own = svc("de.frankjuchim.klarschiff2.check.weekly", .user, home: home, orphaned: false, own: true)
    own.explanation = "Das ist der automatische Check von Klarschiff 2. Er bleibt immer erhalten."
    #expect(ServiceRow.statusText(own) == own.explanation)

    var orphan = svc("com.example.gone", .user, home: home)
    orphan.programPath = "/Applications/Gone.app/Contents/MacOS/Gone"
    #expect(ServiceRow.missingText(orphan) == "Programm fehlt: /Applications/Gone.app/Contents/MacOS/Gone")
    #expect(ServiceRow.revealURL(orphan) == orphan.plistURL)

    var login = svc("com.example.login", .loginItem, home: home, orphaned: false)
    login.startKind = .atLogin
    #expect(ServiceRow.startText(login) == "startet bei der Anmeldung")
    login.startKind = .onDemand
    #expect(ServiceRow.startText(login) == "ausgeschaltet")
    #expect(ServiceRow.revealURL(login) == nil)
    #expect(ServiceRow.notRemovableText("Gehört zu macOS.") == "nicht entfernbar – Gehört zu macOS.")
    #expect(ServiceRow.startText(none) == "startet bei Bedarf")
}

@Test func servicesBannerHeadline() {
    let ok = RemovalReport(results: [], freedBytes: 0, failures: [])
    #expect(ResultBanner.headline(ok, legacy: false, services: true, dryRun: false) == "Hintergrunddienste entfernt.")
    let failed = ItemResult(findingID: FindingID(scannerID: "services.orphaned", key: "user"), itemID: "x", outcome: .failed("nein"))
    let partial = RemovalReport(results: [failed], freedBytes: 0, failures: [failed])
    #expect(ResultBanner.headline(partial, legacy: false, services: true, dryRun: false) == "Hintergrunddienste nicht entfernt.")
    let cancelled = ItemResult(findingID: failed.findingID, itemID: "y", outcome: .cancelled)
    let none = RemovalReport(results: [failed, cancelled], freedBytes: 0, failures: [failed, cancelled])
    #expect(ResultBanner.headline(none, legacy: false, services: true, dryRun: false) == "Hintergrunddienste nicht entfernt.")
    let removed = ItemResult(findingID: failed.findingID, itemID: "z", outcome: .removed(freed: nil))
    let some = RemovalReport(results: [removed, failed], freedBytes: 0, failures: [failed])
    #expect(ResultBanner.headline(some, legacy: false, services: true, dryRun: false) == "Hintergrunddienste nur teilweise entfernt.")
    #expect(ResultBanner.headline(ok, legacy: false, services: false, dryRun: false) == "\(ByteFormat.string(0)) frei geworden.")
}

@Test @MainActor func failedBootoutKeepsServicePlist() async throws {
    let home = tempHome()
    let log = ServiceLog()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)), log: log,
                          failingBootouts: ["com.example.useragent", "com.example.allagent"])
    await model.reloadServices()

    await model.removeServices(removableIDs)

    // Kein Papierkorb für den Benutzer-Agent; der Alle-Benutzer-Agent wird erst nach dem Admin-Schritt gestoppt –
    // scheitert das, wird er als Fehler gemeldet (seine plist ist schon weg, er startet nicht wieder).
    #expect(!log.events.contains { $0.hasPrefix("trash") })
    #expect(log.events.dropFirst() == [
        "admin /bin/rm -f /Library/LaunchAgents/com.example.allagent.plist ; "
            + "/bin/launchctl bootout system/com.example.daemon ; /bin/rm -f /Library/LaunchDaemons/com.example.daemon.plist",
        "/bin/launchctl bootout gui/\(getuid())/com.example.allagent",
    ])
    let report = try #require(model.lastRemoval)
    #expect(Set(report.failures.compactMap(\.itemID)) == ["user/com.example.useragent", "allUsers/com.example.allagent"])
    // Je Dienst genau ein Ergebnis.
    #expect(report.results.compactMap(\.itemID).sorted() == removableIDs.sorted())
    #expect(ResultBanner.headline(report, legacy: false, services: true, dryRun: false)
        == "Hintergrunddienste nur teilweise entfernt.")
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
    #expect(model.lastError == AppErrorText.servicesNoLongerOrphaned)
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

@Test @MainActor func servicesPlanWithDryRunOptionMakesNoCalls() async {
    let home = tempHome()
    let log = ServiceLog()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)), log: log, dryRun: false)
    await model.reloadServices()
    for id in removableIDs { model.toggleService(id) }

    await model.execute(model.makePlan(tab: .services, options: RemovalOptions(dryRun: true)))

    #expect(log.events == ["trash dryRun=true user/com.example.useragent"])
    #expect(model.lastRemovalWasDryRun)
}

@Test @MainActor func mixedServicesPlanRejected() async {
    let home = tempHome()
    let log = ServiceLog()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)), log: log)
    await model.reloadServices()
    model.toggleService("user/com.example.useragent")
    let services = model.serviceFindings(for: model.selectedServices)
    let other = Finding(
        id: FindingID(scannerID: "appCaches.x", key: "k"), category: .appCaches, title: "Cache", summary: "",
        risk: .safe, method: .trash,
        items: [FindingItem(id: "/x", url: home.appending(path: "x"), name: "x", size: 1)],
        size: 1, blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)
    var selection: [FindingID: Set<String>] = [other.id: ["/x"]]
    for f in services { selection[f.id] = Set(f.items.map(\.id)) }
    let plan = RemovalPlan(findings: services + [other], selection: selection, options: RemovalOptions())

    await model.execute(plan)

    #expect(log.events.isEmpty)
    #expect(model.lastError == AppErrorText.mixedServicesPlan)
    #expect(model.lastRemoval == nil)
    #expect(model.isRemoving == false)
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
    // Eigene Wurzel, damit /Library/LaunchAgents nicht derselbe Ordner wie ~/Library/LaunchAgents ist.
    let ctx = ScanContext(
        home: home, userCacheDir: home, rootPrefix: home.appending(path: "root"), runner: ServiceCommands(log: ServiceLog()),
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

// MARK: - Abschlussreview

@Test @MainActor func nothingLeftAfterFreshReadReportsAndKeepsLoginItems() async {
    let home = tempHome()
    let log = ServiceLog()
    let source = ServiceSource(fixtureItems(home))
    let model = makeModel(home: home, source: source, log: log)
    await model.reloadServices()
    // Inzwischen ist die App wieder da: nichts mehr verwaist.
    source.set(fixtureItems(home).map { var i = $0; i.isOrphaned = false; return i }, failed: false)

    await model.removeServices(removableIDs)

    #expect(log.events.isEmpty)
    #expect(model.lastError == "Inzwischen nicht mehr verwaist – nichts entfernt.")
    #expect(model.lastRemoval == nil)
    #expect(source.calls == 1 && source.agentCalls == 1)
    // Anmeldeobjekte stammen weiter aus dem letzten vollständigen Einlesen.
    #expect(model.services.contains { $0.id == "loginItem/com.example.login" })
    #expect(model.services.filter(model.isServiceSelectable).isEmpty)
}

@Test @MainActor func reloadAfterRemovalKeepsLoginItemsWhenSfltoolFails() async {
    let home = tempHome()
    let source = ServiceSource(fixtureItems(home))
    let model = makeModel(home: home, source: source)
    await model.reloadServices()
    source.set(fixtureItems(home).filter { $0.scope != .loginItem }, failed: true)

    await model.removeServices(["user/com.example.useragent"])

    #expect(model.services.contains { $0.id == "loginItem/com.example.login" })
    #expect(model.loginItemsFailed == false)
}

@Test @MainActor func cancelledAdminLeavesAllUsersAgentsLoaded() async throws {
    let home = tempHome()
    let log = ServiceLog()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)), log: log, cancelAdmin: true)
    await model.reloadServices()

    await model.removeServices(["allUsers/com.example.allagent", "system/com.example.daemon"])

    #expect(log.events == ["admin /bin/rm -f /Library/LaunchAgents/com.example.allagent.plist ; "
        + "/bin/launchctl bootout system/com.example.daemon ; /bin/rm -f /Library/LaunchDaemons/com.example.daemon.plist"])
    #expect(!log.events.contains { $0.contains("bootout gui/") })
    let report = try #require(model.lastRemoval)
    #expect(report.results.map(\.outcome) == [.cancelled, .cancelled])
    #expect(ResultBanner.headline(report, legacy: false, services: true, dryRun: false) == "Hintergrunddienste nicht entfernt.")
}

@Test @MainActor func sharedLabelOrphanNotSelectableAndExplained() async {
    let home = tempHome()
    let log = ServiceLog()
    let items = [
        svc("com.example.shared", .user, home: home),
        svc("com.example.shared", .allUsers, home: home, orphaned: false),
    ]
    let model = makeModel(home: home, source: ServiceSource(items), log: log)
    await model.reloadServices()

    let orphan = model.services[0]
    #expect(!model.isServiceSelectable(orphan))
    #expect(model.serviceNotRemovableReason(orphan)
        == "Ein gleichnamiger, intakter Dienst läuft – bitte über die zugehörige App entfernen.")
    model.toggleService(orphan.id)
    #expect(model.selectedServices.isEmpty)
    await model.removeServices([orphan.id])
    #expect(!log.events.contains { $0.contains("bootout") })
    #expect(model.serviceCommandLines(for: [orphan.id]).isEmpty)
}

@Test @MainActor func servicesWarningCardWording() async {
    let home = tempHome()
    let model = makeModel(home: home, source: ServiceSource(fixtureItems(home)))
    await model.reloadServices()
    model.toggleService("system/com.example.daemon")
    let texts = ConfirmSheet.warningCardTexts(model.makePlan(tab: .services, options: RemovalOptions()))
    #expect(texts.title == "Du entfernst Hintergrunddienste")
    #expect(texts.toggle == "Ich habe verstanden, dass die Hintergrunddienste endgültig entfernt werden.")

    let system = Finding(
        id: FindingID(scannerID: "system.x", key: "k"), category: .systemData, title: "System", summary: "",
        risk: .review, method: .admin([AdminStep(executable: "/usr/bin/log", arguments: ["erase", "--all"])]),
        items: [FindingItem(id: "a", url: nil, name: "a", size: 1)],
        size: 1, blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)
    let sysPlan = RemovalPlan(findings: [system], selection: [system.id: ["a"]], options: RemovalOptions())
    #expect(ConfirmSheet.warningCardTexts(sysPlan) == ("Du entfernst Systemdateien",
                                                        "Ich habe verstanden, dass Systemdateien entfernt werden."))
}
