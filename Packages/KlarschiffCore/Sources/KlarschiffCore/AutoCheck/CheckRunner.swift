import Foundation

/// Führt den löschfreien Check aus: Scan, Wurzel-Systembereiche, freier Platz, Alerts, Verlauf.
/// Hat bewusst keine Remover-Abhängigkeit – der Check löscht nie.
public struct CheckRunner: Sendable {
    public typealias MeasureSystemRoots = @Sendable (ScanContext) async -> [String: (title: String, size: Int64)]
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
        var cleanable: Int64 = 0
        for f in report.findings {
            let id = "\(f.id.scannerID)/\(f.id.key)"
            if let size = f.size {
                sizes[id] = size
                titles[id] = f.title
            }
            let tab = f.category.tab
            if (tab == .storage || tab == .developer), f.risk != .hintOnly, !kept.contains(f.id) {
                cleanable += f.size ?? 0
            }
        }
        for (rootID, r) in roots {
            sizes["systemdata.\(rootID)"] = r.size
            titles["systemdata.\(rootID)"] = r.title
        }

        let space = (try? diskSpace()) ?? DiskSpace(free: 0, total: 0)
        var snapshot = CheckSnapshot(date: ctx.now, cleanableTotal: cleanable, freeBytes: space.free,
                                     totalBytes: space.total, sizes: sizes, titles: titles, alerts: [])
        snapshot.alerts = GrowthWatcher.alerts(previous: await history.latest(), current: snapshot)
        try? await history.append(snapshot)
        return snapshot
    }
}
