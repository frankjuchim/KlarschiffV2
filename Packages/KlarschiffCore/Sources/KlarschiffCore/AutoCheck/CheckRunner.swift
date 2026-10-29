import Foundation

/// Führt den löschfreien Check aus: Scan, Wurzel-Systembereiche, freier Platz, Alerts, Verlauf.
/// Hat bewusst keine Remover-Abhängigkeit – der Check löscht nie.
public struct CheckRunner: Sendable {
    /// Bereichs-ID → (Titel, Größe, nur Untergrenze?).
    public typealias MeasureSystemRoots = @Sendable (ScanContext) async -> [String: (title: String, size: Int64, isLowerBound: Bool)]
    public typealias DiskSpaceProvider = @Sendable () throws -> DiskSpace

    private let engine: ScanEngine
    private let keepList: KeepList
    private let history: CheckHistory
    private let measureSystemRoots: MeasureSystemRoots
    private let diskSpace: DiskSpaceProvider

    /// `measureSystemRoots` liefert Bereichs-ID → (Titel, Größe); der Runner stellt `systemdata.` voran.
    public init(engine: ScanEngine, keepList: KeepList, history: CheckHistory,
                measureSystemRoots: @escaping MeasureSystemRoots, diskSpace: @escaping DiskSpaceProvider) {
        self.engine = engine
        self.keepList = keepList
        self.history = history
        self.measureSystemRoots = measureSystemRoots
        self.diskSpace = diskSpace
    }

    public func run(_ ctx: ScanContext) async -> CheckSnapshot {
        let report = await engine.run(ctx) { _, _ in }
        let roots = await measureSystemRoots(ctx)
        let kept = await keepList.all

        var sizes: [String: Int64] = [:]
        var titles: [String: String] = [:]
        var lowerBound: Set<String> = []
        var cleanable: Int64 = 0
        // Behaltene und Funde ohne Größe kommen nicht in den Größenvergleich.
        for f in report.findings where !kept.contains(f.id) {
            let id = "\(f.id.scannerID)/\(f.id.key)"
            if let size = f.size {
                sizes[id] = size
                titles[id] = f.title
            }
            let tab = f.category.tab
            if (tab == .storage || tab == .developer), f.risk != .hintOnly {
                cleanable += f.size ?? 0
            }
        }
        // Fehlgeschlagene Scanner: unbekannt (keine Größe, nie verglichen).
        for failure in report.failures { lowerBound.insert(failure.scannerID) }
        for (rootID, r) in roots {
            let id = "systemdata.\(rootID)"
            sizes[id] = r.size
            titles[id] = r.title
            if r.isLowerBound { lowerBound.insert(id) }
        }

        let space = try? diskSpace()
        var snapshot = CheckSnapshot(date: ctx.now, cleanableTotal: cleanable, freeBytes: space?.free ?? 0,
                                     totalBytes: space?.total ?? 0, sizes: sizes, titles: titles, alerts: [],
                                     lowerBoundIDs: lowerBound)
        snapshot.alerts = GrowthWatcher.alerts(previous: await history.latest(), current: snapshot)
        // Ohne Plattenplatz ist der Lauf unvollständig: zurückgeben, aber nicht in den Verlauf schreiben.
        if space != nil { try? await history.append(snapshot) }
        return snapshot
    }
}
