import Foundation
import Observation
import KlarschiffCore

enum EmptyTrashError: Error, Equatable {
    /// Der Finder hat das Leeren abgelehnt oder es kam zu keinem Ergebnis; Text ist ein kurzer Grund.
    case failed(String)
    /// Apple Events an den Finder sind nicht erlaubt (-1743).
    case automationDenied

    var message: String {
        switch self {
        case .failed(let reason): "Papierkorb konnte nicht geleert werden: \(reason)"
        case .automationDenied:
            "Papierkorb konnte nicht geleert werden: Klarschiff 2 braucht die Erlaubnis, den Finder zu steuern. "
                + "Du erteilst sie unter Systemeinstellungen → Datenschutz & Sicherheit → Automation."
        }
    }
}

/// Freundliche Fehlermeldungen für die Oberfläche.
enum AppErrorText {
    static let keepList = "Konnte die Behalten-Liste nicht speichern."
    static let trashFailed = "Papierkorb konnte nicht geleert werden."
    static let dryRunPlan = "Trockenlauf aktiv – ein Plan ohne Trockenlauf wurde nicht ausgeführt."
    static let checkSchedule = "Konnte den automatischen Check nicht anmelden."
}

/// Alles, was `AppModel` von außen braucht – in Tests durch Attrappen ersetzbar.
struct AppDependencies: Sendable {
    var engine: ScanEngine
    var keepList: KeepList
    var runner: RemovalRunner
    var diskSpace: @Sendable () throws -> DiskSpace
    var makeContext: @Sendable (_ includeSlowChecks: Bool) -> ScanContext
    var bigChunks: @Sendable (ScanContext, [Finding]) async -> [BigChunk]
    var photos: @Sendable (ScanContext) async -> PhotosInfo?
    var trash: @Sendable (ScanContext) async -> Int64?
    var fullDiskAccess: @Sendable () -> Bool
    /// Leert den Papierkorb über den Finder; wirft `EmptyTrashError`.
    var emptyTrash: @Sendable (_ dryRun: Bool) async throws -> RemovalReport
    /// Misst die Systemdaten (nur lesend); meldet Fortschritt als (fertig, gesamt).
    var measureSystemData: @Sendable (ScanContext, @escaping @Sendable (Int, Int) -> Void) async -> SystemDataReport
    var dryRun: Bool
    var terminate: @Sendable (AppRef) async -> Bool
    /// Verlauf des automatischen Checks.
    var history: CheckHistory
    /// Schnelle Messung der Wurzel-Systembereiche für den Check (ohne Home, ohne Aufräum-Scanner).
    var measureSystemRoots: CheckRunner.MeasureSystemRoots
    var notifier: any Notifier
    var agentService: any AgentService

    /// Der löschfreie Teil – dieselben Bausteine wie der normale Scan, ohne Remover.
    var check: CheckDependencies {
        CheckDependencies(
            engine: engine, keepList: keepList, history: history, measureSystemRoots: measureSystemRoots,
            diskSpace: diskSpace, makeContext: makeContext, notifier: notifier)
    }
}

@MainActor @Observable
final class AppModel {
    var selectedTab: AppTab = .storage
    var disk: DiskSpace?
    var isScanning = false
    var scanProgress: Double = 0
    var report: ScanReport?
    var bigChunks: [BigChunk] = []
    var photos: PhotosInfo?
    var trashBytes: Int64?
    var hasFullDiskAccess = false
    /// Gewählte Item-IDs je Fund; enthält nur nicht-leere Mengen.
    var selection: [FindingID: Set<String>] = [:]
    var kept: Set<FindingID> = []
    var lastRemoval: RemovalReport?
    /// War der Lauf hinter `lastRemoval` ein Trockenlauf? Beim Ausführen festgehalten, damit ein späteres
    /// Umschalten die Ergebnis-Anzeige nicht umetikettiert.
    var lastRemovalWasDryRun = false
    /// Läuft gerade eine Entfernung (Aufräumen oder Papierkorb leeren)? Sperrt Scan und weitere Entfernungen.
    var isRemoving = false
    var removalProgress: String?
    /// Letzter Fehler in Alltagssprache (Behalten-Liste, Papierkorb …); die Oberfläche zeigt und löscht ihn.
    var lastError: String?
    /// Letzte Systemdaten-Messung (Tab „Systemdaten“).
    var systemData: SystemDataReport?
    var isMeasuringSystemData = false
    var systemDataProgress: Double = 0
    /// Automatischer Check: Zeitplan, Verlauf (neueste zuerst), Anmeldestatus, Mitteilungs-Erlaubnis.
    private(set) var checkSchedule: CheckSchedule
    var checkHistory: [CheckSnapshot] = []
    var lastCheck: CheckSnapshot? { checkHistory.first }
    var isChecking = false
    /// Gespeicherter Mitteilungs-Entscheid („nie gefragt“ ≠ „abgelehnt“).
    var notificationStatus: NotificationAuthorization = .notDetermined
    /// Mitteilungen ausdrücklich abgelehnt – der Check meldet sich nicht.
    var notificationsDenied: Bool { notificationStatus == .denied }
    var agentStatus: AgentStatus = .notRegistered
    /// Überbleibsel der alten Aufräum-Automatik (Karte oben im Tab „Speicher“, solange etwas existiert).
    var legacyItems: [LegacyItem] = []
    var showsLegacyCard: Bool { !legacyItems.isEmpty }

    /// UserDefaults-Schlüssel des Schalters „Trockenlauf“ im Menü „Entwickler“.
    static let dryRunDefaultsKey = "dryRun"
    /// UserDefaults-Schlüssel des Zeitplans für den automatischen Check.
    static let checkScheduleDefaultsKey = "checkSchedule"

    /// Vom Start erzwungener Trockenlauf (`--dry-run` / `KLARSCHIFF_DRY_RUN=1`); der Schalter kann ihn nicht abschalten.
    let isDryRunForced: Bool
    /// Schalter „Trockenlauf“ (Entwicklermenü), in UserDefaults gespeichert.
    private(set) var dryRunSetting: Bool
    /// Wirksamer Trockenlauf: Startargument ODER Schalter. Wird in jeden Plan erzwungen.
    var dryRun: Bool { isDryRunForced || dryRunSetting }

    @ObservationIgnored private let deps: AppDependencies
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var findingsByID: [FindingID: Finding] = [:]
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var systemFindingsByID: [FindingID: Finding] = [:]
    @ObservationIgnored private var hasStartedSystemMeasurement = false
    @ObservationIgnored private var systemGeneration = 0
    /// Anzeigenamen (Fund-Titel, Item-Namen) des zuletzt ausgeführten Plans – bleiben auch nach dem Neu-Scan lesbar.
    @ObservationIgnored private var removalLabels: [FindingID: (title: String, items: [String: String])] = [:]

    init(dependencies: AppDependencies, defaults: UserDefaults = .standard) {
        deps = dependencies
        self.defaults = defaults
        isDryRunForced = dependencies.dryRun
        dryRunSetting = defaults.bool(forKey: Self.dryRunDefaultsKey)
        checkSchedule = defaults.string(forKey: Self.checkScheduleDefaultsKey).flatMap(CheckSchedule.init) ?? .off
        refreshAgentStatus()
    }

    private var scheduler: CheckScheduler { CheckScheduler(service: deps.agentService) }

    // MARK: - Automatischer Check

    /// Meldet den passenden LaunchAgent an (die anderen ab) und merkt sich die Wahl. Nur hier – beim Einschalten,
    /// mit offenem Fenster – wird nach der Mitteilungs-Erlaubnis gefragt, nie im Hintergrund. Fehler landen in `lastError`, der Status in `agentStatus`.
    func setCheckSchedule(_ schedule: CheckSchedule) async {
        checkSchedule = schedule
        defaults.set(schedule.rawValue, forKey: Self.checkScheduleDefaultsKey)
        if schedule != .off {
            if await deps.notifier.requestAuthorization() {
                notificationStatus = .authorized
            } else {
                await refreshNotificationStatus()
            }
        }
        do {
            try await scheduler.apply(schedule)
        } catch {
            lastError = AppErrorText.checkSchedule
        }
        refreshAgentStatus()
    }

    func refreshAgentStatus() {
        agentStatus = scheduler.status(for: checkSchedule)
    }

    /// „Jetzt prüfen“: derselbe Kern wie der LaunchAgent, im laufenden Prozess. Nicht während Scan, Entfernen,
    /// Messen oder eines anderen Checks.
    func runCheckNow() async {
        guard !isChecking, !isScanning, !isRemoving, !isMeasuringSystemData else { return }
        isChecking = true
        let outcome = await BackgroundCheck.run(dependencies: deps.check)
        if outcome.notificationsAllowed {
            notificationStatus = .authorized
        } else if notificationStatus == .authorized {
            // Inzwischen entzogen – genauen Entscheid nachlesen (fragt nicht).
            await refreshNotificationStatus()
        }
        await loadCheckHistory()
        isChecking = false
    }

    func loadCheckHistory() async {
        checkHistory = await deps.history.all()
    }

    /// Liest den gespeicherten Mitteilungs-Entscheid, ohne zu fragen.
    func refreshNotificationStatus() async {
        notificationStatus = await deps.notifier.authorizationStatus()
    }

    /// „Letzter Check vor 3 Tagen: 45,6 GB aufräumbar“ – Kurzfassung wie die Mitteilung, sonst die aufräumbare Menge;
    /// nil ohne Check. Immer „vor …“ (mindestens 1 Sekunde), auch bei leicht verstellter Uhr.
    nonisolated static func statusLine(_ s: CheckSnapshot?, now: Date) -> String? {
        guard let s else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        let elapsed = max(now.timeIntervalSince(s.date), 1)
        let relative = formatter.localizedString(fromTimeInterval: -elapsed)
        return "Letzter Check \(relative): \(shortSummary(s))"
    }

    /// Kurzfassung eines Checks: der Mitteilungstext, ohne Auffälligkeit „<Menge> aufräumbar“.
    nonisolated static func shortSummary(_ s: CheckSnapshot) -> String {
        CheckNotificationText.make(s)?.body ?? "\(ByteFormat.string(s.cleanableTotal)) aufräumbar"
    }

    // MARK: - Alte Automatik (Migration)

    /// Erkennt die alte Aufräum-Automatik (nur lesend: Dateien + `launchctl print`).
    func detectLegacy() async {
        legacyItems = await LegacyAutomation.detect(deps.makeContext(false))
    }

    /// Nach Bestätigung: geladene Agents per `launchctl bootout` stoppen, dann über den bekannten Entfernen-Weg
    /// (RemovalRunner → TrashRemover, SafetyGuard) in den Papierkorb legen. Trockenlauf: kein bootout, nur melden.
    /// Ergebnis im Ergebnis-Banner, danach neu erkennen.
    func removeLegacy(includeExtras: Bool) async {
        guard !isRemoving, !isScanning, !isMeasuringSystemData, !isChecking, !legacyItems.isEmpty else { return }
        isRemoving = true
        removalProgress = "Alte Automatik wird entfernt …"
        let runDry = dryRun
        let ctx = deps.makeContext(false)
        let items = legacyItems
        let finding = LegacyAutomation.removalFinding(items, ctx: ctx, includeExtras: includeExtras)
        removalLabels = [finding.id: (
            finding.title,
            Dictionary(items.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }))]

        let bootouts = await LegacyAutomation.bootout(items, runner: ctx.runner, dryRun: runDry)
        let plan = RemovalPlan(
            findings: [finding], selection: [finding.id: Set(finding.items.map(\.id))],
            options: RemovalOptions(dryRun: runDry))
        let trashed = await deps.runner.run(plan) { _ in }
        let bootoutFailures = bootouts.filter {
            if case .failed = $0.outcome { return true }
            return false
        }
        lastRemoval = RemovalReport(
            results: bootouts + trashed.results, freedBytes: trashed.freedBytes,
            failures: bootoutFailures + trashed.failures)
        lastRemovalWasDryRun = runDry
        isRemoving = false
        removalProgress = nil
        trashBytes = await deps.trash(ctx)
        refreshSystemState()
        await detectLegacy()
    }

    /// Klick auf eine Check-Mitteilung: Ziel-Tab aus `userInfo["tab"]` (`AppTab.rawValue`); Unbekanntes ignorieren.
    func openTab(fromNotification rawTab: String?) {
        guard let rawTab, let tab = AppTab(rawValue: rawTab) else { return }
        selectedTab = tab
    }

    // MARK: - Trockenlauf

    /// Schaltet den Trockenlauf-Schalter; bei erzwungenem Trockenlauf wirkungslos.
    func setDryRunSetting(_ on: Bool) {
        guard !isDryRunForced else { return }
        dryRunSetting = on
        defaults.set(on, forKey: Self.dryRunDefaultsKey)
    }

    // MARK: - Systemzustand

    func refreshSystemState() {
        disk = try? deps.diskSpace()
        hasFullDiskAccess = deps.fullDiskAccess()
    }

    // MARK: - Scan

    func scan(includeSlowChecks: Bool) async {
        guard !isScanning, !isRemoving, !isMeasuringSystemData, !isChecking else { return }
        isScanning = true
        scanProgress = 0
        scanGeneration += 1
        let generation = scanGeneration
        refreshSystemState()
        kept = await deps.keepList.all

        let ctx = deps.makeContext(includeSlowChecks)
        let newReport = await deps.engine.run(ctx) { [weak self] done, total in
            let value = total > 0 ? Double(done) / Double(total) : 1
            Task { @MainActor [weak self] in
                guard let self, self.isScanning, self.scanGeneration == generation else { return }
                self.scanProgress = max(self.scanProgress, value)
            }
        }

        let deps = self.deps
        async let chunks = deps.bigChunks(ctx, newReport.findings)
        async let photoInfo = deps.photos(ctx)
        async let trash = deps.trash(ctx)
        let (c, p, t) = await (chunks, photoInfo, trash)

        apply(newReport)
        bigChunks = c
        photos = p
        trashBytes = t
        scanProgress = 1
        isScanning = false
        refreshSystemState()
        await detectLegacy()
    }

    private func apply(_ newReport: ScanReport) {
        report = newReport
        findingsByID = Dictionary(newReport.findings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Auswahl der Systemfunde gehört zur Messung, nicht zum Scan – bleibt erhalten.
        var next = selection.filter { systemFindingsByID[$0.key] != nil }
        for f in newReport.findings where !kept.contains(f.id) && !Self.isHint(f) {
            guard f.isPreselected(isKept: false) else { continue }
            let ids = Self.selectableItemIDs(f)
            if !ids.isEmpty { next[f.id] = ids }
        }
        selection = next
    }

    // MARK: - Systemdaten

    func measureSystemData() async {
        guard !isMeasuringSystemData, !isScanning, !isRemoving, !isChecking else { return }
        hasStartedSystemMeasurement = true
        isMeasuringSystemData = true
        systemDataProgress = 0
        systemGeneration += 1
        let generation = systemGeneration
        refreshSystemState()
        kept = await deps.keepList.all

        let ctx = deps.makeContext(false)
        let result = await deps.measureSystemData(ctx) { [weak self] done, total in
            let value = total > 0 ? Double(done) / Double(total) : 1
            Task { @MainActor [weak self] in
                guard let self, self.isMeasuringSystemData, self.systemGeneration == generation else { return }
                self.systemDataProgress = max(self.systemDataProgress, value)
            }
        }
        // Abgebrochen (z. B. Tabwechsel): Ergebnis wäre „Abgebrochen“-Müll – verwerfen, später neu versuchen.
        if Task.isCancelled {
            isMeasuringSystemData = false
            hasStartedSystemMeasurement = false
            refreshSystemState()
            return
        }
        // Systemfunde sind nie vorausgewählt; alte Auswahl verfällt mit der neuen Messung.
        for id in systemFindingsByID.keys { selection[id] = nil }
        systemData = result
        systemFindingsByID = Dictionary(
            result.cleanupFindings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        systemDataProgress = 1
        isMeasuringSystemData = false
        refreshSystemState()
    }

    /// Misst beim ersten Öffnen des Tabs, danach nie wieder automatisch (pro App-Start).
    func measureSystemDataIfNeeded() async {
        guard !hasStartedSystemMeasurement else { return }
        await measureSystemData()
    }

    // MARK: - Abfragen

    /// Nicht behaltene Funde des Tabs, nach Kategorie (`sortOrder`) gruppiert, je Kategorie nach Größe absteigend.
    func findings(in tab: AppTab) -> [(KlarschiffCore.Category, [Finding])] {
        group(allFindings(in: tab).filter { !kept.contains($0.id) })
    }

    /// Behaltene Funde des Tabs (für den Bereich „Behalten (n)“), nach Größe absteigend.
    func keptFindings(in tab: AppTab) -> [Finding] {
        allFindings(in: tab).filter { kept.contains($0.id) }.sorted(by: Self.bySizeDescending)
    }

    /// Scanner-Fehler des Tabs. Ohne ableitbare Kategorie landen sie im Speicher-Tab.
    func failures(in tab: AppTab) -> [ScanFailure] {
        (report?.failures ?? []).filter { failure in
            (failureCategory(failure)?.tab ?? .storage) == tab
        }
    }

    /// Kategorie eines Scanner-Fehlers: aus Funden desselben Scanners, sonst aus dem ID-Präfix.
    func failureCategory(_ failure: ScanFailure) -> KlarschiffCore.Category? {
        if let f = report?.findings.first(where: { $0.id.scannerID == failure.scannerID }) { return f.category }
        return Self.category(forScannerID: failure.scannerID)
    }

    nonisolated static func category(forScannerID id: String) -> KlarschiffCore.Category? {
        KlarschiffCore.Category.forScannerID(id)
    }

    func selectedSize(in tab: AppTab) -> Int64 {
        allFindings(in: tab).reduce(0) { sum, f in
            guard !Self.isHint(f), !kept.contains(f.id), let ids = selection[f.id] else { return sum }
            return sum + f.items.filter { ids.contains($0.id) }.reduce(0) { $0 + ($1.size ?? 0) }
        }
    }

    func foundSize(in tab: AppTab) -> Int64 {
        allFindings(in: tab).reduce(0) { sum, f in
            guard !Self.isHint(f), !kept.contains(f.id) else { return sum }
            return sum + (f.size ?? 0)
        }
    }

    func isSelected(_ id: FindingID) -> Bool { !(selection[id]?.isEmpty ?? true) }

    // MARK: - Auswahl

    func toggle(_ id: FindingID) {
        guard let f = lookup(id), !Self.isHint(f), !kept.contains(id) else { return }
        if isSelected(id) {
            selection[id] = nil
        } else {
            let ids = Self.selectableItemIDs(f)
            selection[id] = ids.isEmpty ? nil : ids
        }
    }

    /// Werkzeug-Funde sind ganz oder gar nicht wählbar – ihre Befehle wirken auf alle Items.
    func toggleItem(_ id: FindingID, item: String) {
        guard let f = lookup(id), !Self.isHint(f), !Self.isTool(f), !kept.contains(id),
              f.items.contains(where: { $0.id == item }) else { return }
        var ids = selection[id] ?? []
        if ids.contains(item) { ids.remove(item) } else { ids.insert(item) }
        selection[id] = ids.isEmpty ? nil : ids
    }

    // MARK: - Behalten

    func keep(_ id: FindingID) async {
        do {
            try await deps.keepList.add(id)
        } catch {
            lastError = AppErrorText.keepList
            return
        }
        kept.insert(id)
        selection[id] = nil
    }

    func unkeep(_ id: FindingID) async {
        do {
            try await deps.keepList.remove(id)
        } catch {
            lastError = AppErrorText.keepList
            return
        }
        kept.remove(id)
    }

    // MARK: - Entfernen

    func makePlan(tab: AppTab, options: RemovalOptions) -> RemovalPlan {
        var opts = options
        if dryRun { opts.dryRun = true }
        let candidates = allFindings(in: tab).filter { !kept.contains($0.id) }
        return RemovalPlan(findings: candidates, selection: selection, options: opts)
    }

    func execute(_ plan: RemovalPlan) async {
        guard !isRemoving, !isScanning, !isMeasuringSystemData, !isChecking else { return }
        // Schutz in der Tiefe: ein anderswo gebauter Plan darf im Trockenlauf nie echt laufen.
        if dryRun, !plan.options.dryRun {
            lastError = AppErrorText.dryRunPlan
            return
        }
        isRemoving = true
        removalProgress = "Bereite vor …"
        var labels: [FindingID: (title: String, items: [String: String])] = [:]
        for (f, _) in plan.allSteps {
            labels[f.id] = (f.title, Dictionary(f.items.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
        }
        removalLabels = labels
        let result = await deps.runner.run(plan) { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.isRemoving else { return }
                self.removalProgress = message
            }
        }
        lastRemoval = result
        lastRemovalWasDryRun = plan.options.dryRun
        isRemoving = false
        removalProgress = nil
        refreshSystemState()
        // Pläne gelten je Tab: Systemfunde → Systemdaten neu messen, sonst normaler Scan.
        let touchedSystem = plan.allSteps
            .contains { $0.0.category == .systemData }
        if touchedSystem {
            await measureSystemData()
        } else {
            await scan(includeSlowChecks: false)
        }
    }

    func emptyTrash() async {
        guard !isRemoving, !isScanning, !isMeasuringSystemData, !isChecking else { return }
        isRemoving = true
        removalLabels = [:]
        removalProgress = "Papierkorb wird geleert …"
        let runDry = dryRun
        do {
            lastRemoval = try await deps.emptyTrash(runDry)
            lastRemovalWasDryRun = runDry
        } catch let error as EmptyTrashError {
            lastError = error.message
        } catch {
            lastError = AppErrorText.trashFailed
        }
        isRemoving = false
        removalProgress = nil
        trashBytes = await deps.trash(deps.makeContext(false))
        refreshSystemState()
    }

    func terminate(_ app: AppRef) async {
        guard await deps.terminate(app) else { return }
        await scan(includeSlowChecks: false)
    }

    /// Anzeigename eines Ergebnis-Eintrags für das Ergebnis-Banner: „<Fund> – <Eintrag>“.
    /// Quelle: der zuletzt ausgeführte Plan, sonst der aktuelle Scan, sonst die rohe ID.
    func label(for result: ItemResult) -> String {
        let known = removalLabels[result.findingID]
            ?? findingsByID[result.findingID].map { f in
                (f.title, Dictionary(f.items.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
            }
        guard let itemID = result.itemID else { return known?.title ?? result.findingID.key }
        let name = known?.items[itemID] ?? itemID
        guard let title = known?.title else { return name }
        return "\(title) – \(name)"
    }

    // MARK: - Helfer

    private func lookup(_ id: FindingID) -> Finding? { findingsByID[id] ?? systemFindingsByID[id] }

    private func allFindings(in tab: AppTab) -> [Finding] {
        if tab == .systemData { return systemData?.cleanupFindings ?? [] }
        return (report?.findings ?? []).filter { $0.tab == tab }
    }

    private func group(_ findings: [Finding]) -> [(KlarschiffCore.Category, [Finding])] {
        Dictionary(grouping: findings, by: \.category)
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key, $0.value.sorted(by: Self.bySizeDescending)) }
    }

    private static func bySizeDescending(_ a: Finding, _ b: Finding) -> Bool {
        switch (a.size, b.size) {
        case let (x?, y?): x > y
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    static func isHint(_ f: Finding) -> Bool {
        if f.risk == .hintOnly { return true }
        if case .hint = f.method { return true }
        return false
    }

    nonisolated static func isTool(_ f: Finding) -> Bool {
        if case .tool = f.method { return true }
        return false
    }

    /// Werkzeug-Funde: alle Items (der Runner überspringt den ganzen Fund, falls eine App blockiert).
    private static func selectableItemIDs(_ f: Finding) -> Set<String> {
        if isTool(f) { return Set(f.items.map(\.id)) }
        return Set(f.items.filter { $0.blockingApp == nil }.map(\.id))
    }
}

// MARK: - Produktion

extension AppDependencies {
    static var isDryRunRequested: Bool {
        CommandLine.arguments.contains("--dry-run") || ProcessInfo.processInfo.environment["KLARSCHIFF_DRY_RUN"] == "1"
    }

    static func live() -> AppDependencies {
        let env = LiveEnvironment()
        let safety = SafetyGuard.production(home: env.home)
        let deleter = DeleteRemover(guard: safety)
        let runner = RemovalRunner(
            trash: TrashRemover(guard: safety),
            delete: deleter,
            tool: ToolRemover(runner: env.commands, tools: env.tools),
            admin: AdminRemover(executor: AppleScriptPrivilegedExecutor(runner: env.commands), guard: safety),
            runningApps: env.apps,
            diskSpace: env.disk)
        let bigChunks = BigChunksScanner()
        let commands = env.commands
        let disk = env.disk
        let apps = env.apps
        let check = env.check

        return AppDependencies(
            engine: check.engine,
            keepList: check.keepList,
            runner: runner,
            diskSpace: disk,
            makeContext: check.makeContext,
            bigChunks: { ctx, findings in await bigChunks.scan(ctx, findings: findings) },
            photos: { ctx in await photosInfo(ctx) },
            trash: { ctx in await trashSize(ctx) },
            fullDiskAccess: env.fda,
            emptyTrash: { dryRun in try await emptyTrashViaFinder(runner: commands, disk: disk, dryRun: dryRun) },
            measureSystemData: { ctx, progress in await SystemDataScanner().scan(ctx, progress: progress) },
            dryRun: isDryRunRequested,
            terminate: { ref in
                guard await apps.terminate(ref) else { return false }
                // Kurz warten, bis die App wirklich weg ist (höchstens ca. 5 s).
                for _ in 0..<20 where !apps.running([ref]).isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                return true
            },
            history: check.history,
            measureSystemRoots: check.measureSystemRoots,
            notifier: check.notifier,
            agentService: SMAppAgentService())
    }

    /// Leert alle Papierkörbe, die der Finder zeigt (lokal, iCloud Drive, externe Volumes).
    /// Trockenlauf: nichts tun, leerer Bericht.
    static func emptyTrashViaFinder(
        runner: CommandRunner, disk: @Sendable () throws -> DiskSpace, dryRun: Bool
    ) async throws -> RemovalReport {
        let empty = RemovalReport(results: [], freedBytes: 0, failures: [])
        if dryRun { return empty }
        let before = try? disk()
        let result: CommandResult
        do {
            result = try await runner.run(
                "/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], timeout: .seconds(600))
        } catch CommandError.timeout {
            throw EmptyTrashError.failed("Zeitüberschreitung")
        } catch {
            throw EmptyTrashError.failed(error.localizedDescription)
        }
        if !result.succeeded {
            if result.stderr.contains("-1743") { throw EmptyTrashError.automationDenied }
            let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
            throw EmptyTrashError.failed(reason.isEmpty ? "Exit \(result.exitCode)" : reason)
        }
        var freed: Int64 = 0
        if let before, let after = try? disk() { freed = max(0, after.free - before.free) }
        return RemovalReport(results: [], freedBytes: freed, failures: [])
    }
}

extension CheckDependencies {
    /// Produktion für den `--check`-Lauf: nur lesende Bausteine, kein Remover.
    static func live() -> CheckDependencies { LiveEnvironment().check }
}

/// Gemeinsame Produktions-Bausteine von App und `--check`-Lauf (lesend; Remover baut nur `AppDependencies.live`).
private struct LiveEnvironment {
    let home = URL(filePath: NSHomeDirectory())
    let commands = ProcessCommandRunner()
    let tools = ToolLocator.standard
    let apps = WorkspaceRunningApps()
    let disk: @Sendable () throws -> DiskSpace = { try DiskInfo.current() }
    let fda: @Sendable () -> Bool
    let check: CheckDependencies

    init() {
        let home = self.home
        let cacheDir = SafetyGuard.userCacheDirectory() ?? SafetyGuard.missingUserCacheDirectory
        let tempDir = SafetyGuard.userTempDirectory() ?? URL(filePath: "/var/empty/klarschiff-no-temp-dir")
        let commands = self.commands
        let tools = self.tools
        let apps = self.apps
        let fda: @Sendable () -> Bool = { FullDiskAccess.isGranted(home: home) }
        self.fda = fda
        check = CheckDependencies(
            engine: ScanEngine(scanners: Catalog.allScanners()),
            keepList: KeepList(fileURL: KeepList.defaultFileURL(home: home)),
            history: CheckHistory(fileURL: CheckHistory.defaultFileURL(home: home)),
            measureSystemRoots: { ctx in await BackgroundCheck.measureSystemRootsLive(ctx) },
            diskSpace: disk,
            makeContext: { slow in
                ScanContext(
                    home: home, userCacheDir: cacheDir, rootPrefix: URL(filePath: "/"), runner: commands,
                    tools: tools, sizer: SizeMeter(), runningApps: apps, claims: PathClaims(), now: Date(),
                    hasFullDiskAccess: fda(), includeSlowChecks: slow,
                    userTempDir: tempDir)
            },
            notifier: UserNotificationCenterNotifier())
    }
}
