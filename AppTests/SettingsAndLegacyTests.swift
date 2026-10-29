import Foundation
import Synchronization
import Testing
import KlarschiffCore
@testable import Klarschiff

// MARK: - Statuszeile

private func snapshot(date: Date, cleanable: Int64, alerts: [CheckAlert] = []) -> CheckSnapshot {
    CheckSnapshot(date: date, cleanableTotal: cleanable, freeBytes: 100_000_000_000, totalBytes: 500_000_000_000,
                  sizes: [:], titles: [:], alerts: alerts)
}

@Test func statusLineTexts() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(AppModel.statusLine(nil, now: now) == nil)

    let threeDays = snapshot(date: now.addingTimeInterval(-3 * 86_400), cleanable: 45_600_000_000,
                             alerts: [.cleanable(total: 45_600_000_000)])
    #expect(AppModel.statusLine(threeDays, now: now) == "Letzter Check vor 3 Tagen: 45,6 GB aufräumbar")

    // Ohne Auffälligkeit: trotzdem die aufräumbare Menge.
    let tenMinutes = snapshot(date: now.addingTimeInterval(-600), cleanable: 500_000_000)
    #expect(AppModel.statusLine(tenMinutes, now: now) == "Letzter Check vor 10 Minuten: 500 MB aufräumbar")

    // Wachstum hat Vorrang (gleiche Kurzfassung wie die Mitteilung).
    let growth = snapshot(date: now.addingTimeInterval(-86_400), cleanable: 2_000_000_000, alerts: [
        .cleanable(total: 2_000_000_000),
        .growth(id: "systemdata.library", title: "Bibliothek", from: 1_000_000_000, to: 7_000_000_000),
    ])
    #expect(AppModel.statusLine(growth, now: now)
        == "Letzter Check vor 1 Tag: Bibliothek +6 GB seit dem letzten Check · 2 GB aufräumbar")

    // Gerade eben (oder Uhr leicht verstellt): immer „vor …“, nie „in 0 Sekunden“.
    let justNow = snapshot(date: now.addingTimeInterval(5), cleanable: 0)
    #expect(AppModel.statusLine(justNow, now: now)?.hasPrefix("Letzter Check vor 1 Sekunde: ") == true)
}

@Test func historyRowTexts() {
    let date = try! Date("2026-11-02T10:00:00+01:00", strategy: .iso8601)
    let s = CheckSnapshot(date: date, cleanableTotal: 45_600_000_000, freeBytes: 120_000_000_000,
                          totalBytes: 500_000_000_000, sizes: [:], titles: [:], alerts: [
                            .lowSpace(free: 120_000_000_000, total: 500_000_000_000),
                            .growth(id: "x", title: "Xcode", from: 1_000_000_000, to: 8_000_000_000),
                          ])
    let row = CheckHistoryRow(s, timeZone: TimeZone(identifier: "Europe/Berlin")!)
    #expect(row.date.contains("2. Nov. 2026"))
    #expect(row.date.contains("10:00"))
    #expect(row.cleanable == "45,6 GB aufräumbar")
    #expect(row.free == "120 GB frei")
    #expect(row.alerts == ["Xcode +7 GB", "Nur noch 120 GB frei"])
}

@Test func historyNewestFirst() {
    let old = snapshot(date: Date(timeIntervalSince1970: 1), cleanable: 1)
    let new = snapshot(date: Date(timeIntervalSince1970: 2), cleanable: 2)
    #expect(CheckHistoryRow.sorted([old, new]).map(\.cleanableTotal) == [2, 1])
}

// MARK: - Migration der alten Automatik

/// Gemeinsames Ereignisprotokoll für Befehle und Papierkorb – zeigt die Reihenfolge.
private final class EventLog: Sendable {
    private let store = Mutex<[String]>([])
    var events: [String] { store.withLock { $0 } }
    func add(_ e: String) { store.withLock { $0.append(e) } }
}

/// `launchctl print` → geladen (Exit 0); `bootout` → Erfolg. Alles wird protokolliert.
private struct RecordingCommands: CommandRunner {
    let log: EventLog
    func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]) async throws -> CommandResult {
        log.add(([executable] + arguments).joined(separator: " "))
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

/// Papierkorb-Attrappe: protokolliert und entfernt (nur echt, nicht im Trockenlauf) die Fixture-Dateien.
private struct FixtureTrash: Remover {
    let log: EventLog
    func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] {
        log.add("trash dryRun=\(dryRun) " + items.map(\.id).sorted().joined(separator: ","))
        return items.map { item in
            if dryRun { return ItemResult(findingID: finding.id, itemID: item.id, outcome: .skipped("Trockenlauf")) }
            if let url = item.url { try? FileManager.default.removeItem(at: url) }
            return ItemResult(findingID: finding.id, itemID: item.id, outcome: .removed(freed: nil))
        }
    }
}

private struct NoRemover: Remover {
    func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] { [] }
}

private struct NoRunningApps: RunningApps {
    func running(_ refs: [AppRef]) -> [AppRef] { [] }
    func terminate(_ ref: AppRef) async -> Bool { false }
}

private struct NoopExecutor: PrivilegedExecutor {
    func run(_ steps: [AdminStep]) async -> AdminRunResult { .completed(steps.map { _ in 0 }) }
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

private func fixtureHome(withLegacy: Bool) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "klarschiff-legacy-\(UUID().uuidString)")
    let agents = home.appending(path: "Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    guard withLegacy else { return home }
    for label in LegacyAutomation.labels {
        try Data("<plist/>".utf8).write(to: agents.appending(path: "\(label).plist"))
    }
    try Data("#!/bin/sh".utf8).write(to: home.appending(path: "cleanup.sh"))
    try Data("log".utf8).write(to: home.appending(path: "cleanup.log"))
    return home
}

private func tempDefaults() -> UserDefaults {
    let name = "klarschiff-legacy-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
private func makeModel(home: URL, log: EventLog, dryRun: Bool) -> AppModel {
    let disk: @Sendable () throws -> DiskSpace = { DiskSpace(free: 100, total: 1_000) }
    let runner = RemovalRunner(
        trash: FixtureTrash(log: log), delete: NoRemover(), tool: NoRemover(),
        admin: AdminRemover(executor: NoopExecutor(), guard: SafetyGuard.production()),
        runningApps: NoRunningApps(), diskSpace: disk)
    let commands = RecordingCommands(log: log)
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
        agentService: NoAgents())
    return AppModel(dependencies: deps, defaults: tempDefaults())
}

@Test @MainActor func legacyCardHiddenWhenNothingFound() async throws {
    let empty = makeModel(home: try fixtureHome(withLegacy: false), log: EventLog(), dryRun: true)
    await empty.detectLegacy()
    #expect(empty.legacyItems.isEmpty)
    #expect(empty.showsLegacyCard == false)

    let found = makeModel(home: try fixtureHome(withLegacy: true), log: EventLog(), dryRun: true)
    await found.detectLegacy()
    #expect(Set(found.legacyItems.map(\.id)) == Set(LegacyAutomation.labels + ["script", "log"]))
    #expect(found.showsLegacyCard)
}

@Test @MainActor func removeLegacyBootoutThenTrashInOrder() async throws {
    let log = EventLog()
    let home = try fixtureHome(withLegacy: true)
    let model = makeModel(home: home, log: log, dryRun: false)
    await model.detectLegacy()
    let uid = getuid()

    await model.removeLegacy(includeExtras: true)

    let relevant = log.events.filter { !$0.contains(" print ") }
    #expect(relevant == [
        "/bin/launchctl bootout gui/\(uid)/com.frankjuchim.cleanup",
        "/bin/launchctl bootout gui/\(uid)/de.bodendiek.klarschiff.check",
        "trash dryRun=false com.frankjuchim.cleanup,de.bodendiek.klarschiff.check,log,script",
    ])
    #expect(model.lastRemoval != nil)
    #expect(model.lastRemoval?.failures.isEmpty == true)
    #expect(model.lastRemovalWasDryRun == false)
    #expect(model.isRemoving == false)
    // Danach neu erkannt: die Fixture-Dateien sind weg, die Karte verschwindet.
    #expect(model.legacyItems.isEmpty)
    #expect(model.showsLegacyCard == false)
    // Ergebnis-Banner kennt die Namen.
    let bootout = try #require(model.lastRemoval?.results.first)
    #expect(model.label(for: bootout) == "Alte Aufräum-Automatik – Hintergrund-Agent com.frankjuchim.cleanup")
}

@Test @MainActor func removeLegacyWithoutExtrasKeepsScript() async throws {
    let log = EventLog()
    let model = makeModel(home: try fixtureHome(withLegacy: true), log: log, dryRun: false)
    await model.detectLegacy()

    await model.removeLegacy(includeExtras: false)

    #expect(log.events.last == "trash dryRun=false com.frankjuchim.cleanup,de.bodendiek.klarschiff.check")
    #expect(Set(model.legacyItems.map(\.id)) == ["script", "log"])
}

@Test @MainActor func removeLegacyDryRunNoCalls() async throws {
    let log = EventLog()
    let home = try fixtureHome(withLegacy: true)
    let model = makeModel(home: home, log: log, dryRun: true)
    await model.detectLegacy()

    await model.removeLegacy(includeExtras: true)

    #expect(!log.events.contains { $0.contains("bootout") })
    #expect(log.events.filter { $0.hasPrefix("trash") }
        == ["trash dryRun=true com.frankjuchim.cleanup,de.bodendiek.klarschiff.check,log,script"])
    #expect(FileManager.default.fileExists(atPath: home.appending(path: "cleanup.sh").path))
    #expect(model.lastRemovalWasDryRun)
    #expect(model.lastRemoval?.failures.isEmpty == true)
    #expect(model.legacyItems.count == 4)
}

@Test @MainActor func removeLegacyBlockedWhileBusy() async throws {
    let log = EventLog()
    let model = makeModel(home: try fixtureHome(withLegacy: true), log: log, dryRun: false)
    await model.detectLegacy()
    model.isScanning = true

    await model.removeLegacy(includeExtras: true)

    #expect(!log.events.contains { $0.contains("bootout") || $0.hasPrefix("trash") })
    #expect(model.lastRemoval == nil)
}
