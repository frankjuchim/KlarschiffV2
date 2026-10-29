import Foundation
import Observation
import KlarschiffCore

enum TrashError: Error, Equatable {
    case unreadable
}

/// Freundliche Fehlermeldungen für die Oberfläche.
enum AppErrorText {
    static let keepList = "Konnte die Behalten-Liste nicht speichern."
    static let trashUnreadable = "Papierkorb konnte nicht gelesen werden – braucht Vollzugriff."
    static let trashFailed = "Papierkorb konnte nicht geleert werden."
    static let dryRunPlan = "Trockenlauf aktiv – ein Plan ohne Trockenlauf wurde nicht ausgeführt."
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
    /// Wirft `TrashError.unreadable`, wenn der Papierkorb nicht gelesen werden kann (z. B. ohne Vollzugriff).
    var emptyTrash: @Sendable (_ dryRun: Bool) async throws -> RemovalReport
    var dryRun: Bool
    var terminate: @Sendable (AppRef) async -> Bool
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
    /// Läuft gerade eine Entfernung (Aufräumen oder Papierkorb leeren)? Sperrt Scan und weitere Entfernungen.
    var isRemoving = false
    var removalProgress: String?
    /// Letzter Fehler in Alltagssprache (Behalten-Liste, Papierkorb …); die Oberfläche zeigt und löscht ihn.
    var lastError: String?

    /// UserDefaults-Schlüssel des Schalters „Trockenlauf“ im Menü „Entwickler“.
    static let dryRunDefaultsKey = "dryRun"

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
    /// Anzeigenamen (Fund-Titel, Item-Namen) des zuletzt ausgeführten Plans – bleiben auch nach dem Neu-Scan lesbar.
    @ObservationIgnored private var removalLabels: [FindingID: (title: String, items: [String: String])] = [:]

    init(dependencies: AppDependencies, defaults: UserDefaults = .standard) {
        deps = dependencies
        self.defaults = defaults
        isDryRunForced = dependencies.dryRun
        dryRunSetting = defaults.bool(forKey: Self.dryRunDefaultsKey)
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
        guard !isScanning, !isRemoving else { return }
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
    }

    private func apply(_ newReport: ScanReport) {
        report = newReport
        findingsByID = Dictionary(newReport.findings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [FindingID: Set<String>] = [:]
        for f in newReport.findings where !kept.contains(f.id) && !Self.isHint(f) {
            guard f.isPreselected(isKept: false) else { continue }
            let ids = Self.selectableItemIDs(f)
            if !ids.isEmpty { next[f.id] = ids }
        }
        selection = next
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
        let prefix = id.split(separator: ".", maxSplits: 1).first.map(String.init) ?? id
        switch prefix {
        case "system": return .system
        case "ai": return .aiLeftovers
        case "appCaches": return .appCaches
        case "personal": return .personalData
        case "apps": return .apps
        case "xcode": return .xcode
        case "sim", "simulators": return .simulators
        case "brew": return .homebrew
        case "languages": return .languages
        case "toolchains": return .toolchains
        default: return nil
        }
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
        guard let f = findingsByID[id], !Self.isHint(f), !kept.contains(id) else { return }
        if isSelected(id) {
            selection[id] = nil
        } else {
            let ids = Self.selectableItemIDs(f)
            selection[id] = ids.isEmpty ? nil : ids
        }
    }

    /// Werkzeug-Funde sind ganz oder gar nicht wählbar – ihre Befehle wirken auf alle Items.
    func toggleItem(_ id: FindingID, item: String) {
        guard let f = findingsByID[id], !Self.isHint(f), !Self.isTool(f), !kept.contains(id),
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
        guard !isRemoving, !isScanning else { return }
        // Schutz in der Tiefe: ein anderswo gebauter Plan darf im Trockenlauf nie echt laufen.
        if dryRun, !plan.options.dryRun {
            lastError = AppErrorText.dryRunPlan
            return
        }
        isRemoving = true
        removalProgress = "Bereite vor …"
        var labels: [FindingID: (title: String, items: [String: String])] = [:]
        for (f, _) in plan.toolSteps + plan.trashSteps + plan.deleteSteps + plan.adminSteps {
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
        isRemoving = false
        removalProgress = nil
        refreshSystemState()
        await scan(includeSlowChecks: false)
    }

    func emptyTrash() async {
        guard !isRemoving, !isScanning else { return }
        isRemoving = true
        removalLabels = [:]
        removalProgress = "Papierkorb wird geleert …"
        do {
            lastRemoval = try await deps.emptyTrash(dryRun)
        } catch TrashError.unreadable {
            lastError = AppErrorText.trashUnreadable
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

    private func allFindings(in tab: AppTab) -> [Finding] {
        (report?.findings ?? []).filter { $0.tab == tab }
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
        let home = URL(filePath: NSHomeDirectory())
        let cacheDir = SafetyGuard.userCacheDirectory() ?? SafetyGuard.missingUserCacheDirectory
        let commands = ProcessCommandRunner()
        let tools = ToolLocator.standard
        let apps = WorkspaceRunningApps()
        let safety = SafetyGuard.production(home: home)
        let disk: @Sendable () throws -> DiskSpace = { try DiskInfo.current() }
        let fda: @Sendable () -> Bool = { FullDiskAccess.isGranted(home: home) }
        let deleter = DeleteRemover(guard: safety)
        let runner = RemovalRunner(
            trash: TrashRemover(guard: safety),
            delete: deleter,
            tool: ToolRemover(runner: commands, tools: tools),
            admin: AdminRemover(executor: AppleScriptPrivilegedExecutor(runner: commands), guard: safety),
            runningApps: apps,
            diskSpace: disk)
        let bigChunks = BigChunksScanner()

        return AppDependencies(
            engine: ScanEngine(scanners: Catalog.allScanners()),
            keepList: KeepList(fileURL: KeepList.defaultFileURL(home: home)),
            runner: runner,
            diskSpace: disk,
            makeContext: { slow in
                ScanContext(
                    home: home, userCacheDir: cacheDir, rootPrefix: URL(filePath: "/"), runner: commands,
                    tools: tools, sizer: SizeMeter(), runningApps: apps, claims: PathClaims(), now: Date(),
                    hasFullDiskAccess: fda(), includeSlowChecks: slow)
            },
            bigChunks: { ctx, findings in await bigChunks.scan(ctx, findings: findings) },
            photos: { ctx in await photosInfo(ctx) },
            trash: { ctx in await trashSize(ctx) },
            fullDiskAccess: fda,
            emptyTrash: { dryRun in try await emptyTrashContents(home: home, remover: deleter, disk: disk, dryRun: dryRun) },
            dryRun: isDryRunRequested,
            terminate: { ref in
                guard await apps.terminate(ref) else { return false }
                // Kurz warten, bis die App wirklich weg ist (höchstens ca. 5 s).
                for _ in 0..<20 where !apps.running([ref]).isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                return true
            })
    }

    /// Löscht jedes Kind von `~/.Trash` über `DeleteRemover` (also mit SafetyGuard).
    /// Fehlt der Ordner, ist nichts zu tun; ist er nicht lesbar, wirft die Funktion `TrashError.unreadable`.
    static func emptyTrashContents(
        home: URL, remover: DeleteRemover, disk: @Sendable () throws -> DiskSpace, dryRun: Bool
    ) async throws -> RemovalReport {
        let trashDir = home.appending(path: ".Trash")
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashDir.path) else { return RemovalReport(results: [], freedBytes: 0, failures: []) }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: trashDir.path)
        } catch {
            throw TrashError.unreadable
        }
        guard !names.isEmpty else { return RemovalReport(results: [], freedBytes: 0, failures: []) }
        let items = names.sorted().map { FindingItem(id: $0, url: trashDir.appending(path: $0), name: $0) }
        let finding = Finding(
            id: FindingID(scannerID: "system.trash", key: "all"), category: .system, title: "Papierkorb",
            summary: "", risk: .review, method: .delete, items: items, size: nil, blockingApps: [],
            keepSuggested: false, commandPreview: [], needsFullDiskAccess: true)
        let before = try? disk()
        let results = await remover.remove(finding, items: items, dryRun: dryRun)
        var freed: Int64 = 0
        if !dryRun, let before, let after = try? disk() { freed = max(0, after.free - before.free) }
        let failures = results.filter {
            switch $0.outcome {
            case .failed, .cancelled: true
            case .skipped, .removed: false
            }
        }
        return RemovalReport(results: results, freedBytes: freed, failures: failures)
    }
}
