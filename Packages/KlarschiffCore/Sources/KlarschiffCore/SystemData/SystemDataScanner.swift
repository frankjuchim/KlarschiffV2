import Foundation
import Synchronization

/// Misst die Katalogbereiche, „Deine Daten“ und das Volume-Inventar zu einem `SystemDataReport` (Spec §3.4).
public struct SystemDataScanner: Sendable {
    public typealias SizeOf = @Sendable (URL) async throws -> (size: Int64, complete: Bool)

    private let areaTimeout: Duration
    private let sizeOf: SizeOf?
    private let cleanupScanners: [any Scanner]

    public init(areaTimeout: Duration = .seconds(120), sizeOf: SizeOf? = nil, cleanupScanners: [any Scanner] = SystemCleanup.scanners()) {
        self.areaTimeout = areaTimeout
        self.sizeOf = sizeOf
        self.cleanupScanners = cleanupScanners
    }

    private enum Unit: Sendable {
        case area(index: Int, SystemArea, [ScanFailure])
        case userData(Int64, Bool, [ScanFailure])
        case inventory(VolumeInventoryResult?, [ScanFailure])
        case snapshots([Finding], [ScanFailure])
        case cleanup([Finding], [ScanFailure])
    }

    public func scan(_ ctx: ScanContext, progress: @Sendable (Int, Int) -> Void) async -> SystemDataReport {
        let measure = Measurer(ctx: ctx, timeout: areaTimeout,
                               sizeOf: sizeOf ?? { try await ctx.sizer.measure($0) })
        let definitions = SystemAreaCatalog.definitions()
        let total = definitions.count + 4
        var completed = 0

        var areaSlots = [SystemArea?](repeating: nil, count: definitions.count)
        var userData: Int64 = 0
        var userDataLower = false
        var inventory: VolumeInventoryResult?
        var snapshotFindings: [Finding] = []
        var cleanupFindings: [Finding] = []
        var failures: [ScanFailure] = []
        let cleanupScanners = self.cleanupScanners
        let timeout = areaTimeout

        await withTaskGroup(of: Unit.self) { group in
            for (i, def) in definitions.enumerated() {
                group.addTask {
                    let (area, f) = await measure.area(def)
                    return .area(index: i, area, f)
                }
            }
            group.addTask {
                var f: [ScanFailure] = []
                var sum: Int64 = 0
                var lower = false
                let app = await measure.single(ctx.absolute("/Applications"), id: "userdata.applications")
                if let s = app.size { sum += s }
                if app.size == nil || !app.complete { lower = true }
                f += app.failures
                // Home je direktem Unterordner (auch versteckte, keine Symlinks), höchstens 8 gleichzeitig.
                let children = Measurer.homeChildren(ctx.home)
                if children.unreadable { lower = true }
                // Ohne Vollzugriff würde das Messen dieser Ordner macOS-Datenschutzabfragen auslösen.
                var homeURLs = children.urls
                if !ctx.hasFullDiskAccess {
                    let protected: Set<String> = ["desktop", "documents", "downloads"]
                    let before = homeURLs.count
                    homeURLs.removeAll { protected.contains($0.lastPathComponent.lowercased()) }
                    if homeURLs.count != before {
                        lower = true
                        f.append(ScanFailure(scannerID: "systemdata.userdata.privacy",
                            message: "Schreibtisch, Dokumente und Downloads werden erst mit Vollzugriff mitgemessen."))
                    }
                }
                let top = await measure.measureAll(homeURLs.map { ($0, "userdata.home.\($0.lastPathComponent)") })
                // Zeitüberschreitung: eine Ebene tiefer – Unterordner einzeln, direkte Dateien per Ressourcenwerte.
                var grandchildren: [(URL, String)] = []
                for r in top {
                    if let size = r.size {
                        sum += size
                        if !r.complete { lower = true }
                        f += r.failures
                        continue
                    }
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: r.url.path, isDirectory: &isDir), isDir.boolValue,
                          let entries = Measurer.splitEntries(r.url) else {
                        lower = true; f += r.failures; continue
                    }
                    sum += entries.filesSize
                    if entries.filesIncomplete { lower = true }
                    let name = r.url.lastPathComponent
                    grandchildren += entries.dirs.map { ($0, "userdata.home.\(name).\($0.lastPathComponent)") }
                    f.append(ScanFailure(scannerID: "systemdata.userdata.home.\(name)",
                        message: "„~/\(name)“ wurde in Unterordnern gemessen (Gesamtmessung lief in die Frist)."))
                }
                for g in await measure.measureAll(grandchildren) {
                    if let size = g.size { sum += size }
                    if g.size == nil || !g.complete { lower = true }
                    f += g.failures
                }
                return .userData(sum, lower, f)
            }
            group.addTask {
                do {
                    return .inventory(try await VolumeInventory.read(runner: ctx.runner), [])
                } catch {
                    return .inventory(nil, [ScanFailure(scannerID: "systemdata.volumes",
                        message: "Die Volumes konnten nicht gelesen werden (\(error.localizedDescription)). Der nicht zugeordnete Anteil bleibt unbekannt.")])
                }
            }
            group.addTask {
                let r = await ScanEngine(scanners: [SnapshotScanner()], perScannerTimeout: timeout).run(ctx) { _, _ in }
                return .snapshots(r.findings, r.failures)
            }
            group.addTask {
                guard !cleanupScanners.isEmpty else { return .cleanup([], []) }
                let r = await ScanEngine(scanners: cleanupScanners, perScannerTimeout: timeout).run(ctx) { _, _ in }
                return .cleanup(r.findings, r.failures)
            }
            for await unit in group {
                switch unit {
                case .area(let i, let a, let f): areaSlots[i] = a; failures += f
                case .userData(let s, let l, let f): userData = s; userDataLower = l; failures += f
                case .inventory(let inv, let f): inventory = inv; failures += f
                case .snapshots(let fs, let f): snapshotFindings = fs; failures += f
                case .cleanup(let fs, let f): cleanupFindings = fs; failures += f
                }
                completed += 1
                progress(completed, total)
            }
        }

        let areas = areaSlots.compactMap { $0 }
        let systemTotal = areas.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var unaccounted: Int64 = 0
        if let data = inventory?.volumes.first(where: { $0.role == .data }) {
            unaccounted = max(0, data.consumed - userData - systemTotal)
        } else if inventory != nil {
            failures.append(ScanFailure(scannerID: "systemdata.volumes",
                message: "Das Daten-Volume wurde nicht gefunden. Der nicht zugeordnete Anteil bleibt unbekannt."))
        }
        let upperBound = userDataLower || areas.contains { $0.size == nil || $0.isLowerBound }
        if upperBound {
            failures.append(ScanFailure(scannerID: "systemdata.unaccounted",
                message: "Einige Bereiche konnten nicht vollständig gemessen werden – „nicht zugeordnet“ ist daher eher zu hoch."))
        }
        return SystemDataReport(
            measuredAt: ctx.now, inventory: inventory, areas: areas, userData: userData, userDataIsLowerBound: userDataLower,
            systemAreasTotal: systemTotal, unaccounted: unaccounted, unaccountedIsUpperBound: upperBound,
            snapshotFindings: snapshotFindings, cleanupFindings: cleanupFindings, failures: failures)
    }
}

// MARK: - Messung

private struct Measurer: Sendable {
    let ctx: ScanContext
    let timeout: Duration
    let sizeOf: SystemDataScanner.SizeOf

    /// Misst einen Bereich samt Unterbereichen rekursiv.
    func area(_ def: SystemAreaDefinition) async -> (SystemArea, [ScanFailure]) {
        var failures: [ScanFailure] = []
        let url = ctx.absolute(def.path)

        async let own = ownSize(def)
        var children: [SystemArea] = []
        if def.id == "assets" {
            let r = await assetChildren(of: url)
            children = r.0; failures += r.1
        } else {
            var slots = [SystemArea?](repeating: nil, count: def.children.count)
            await withTaskGroup(of: (Int, SystemArea, [ScanFailure]).self) { group in
                for (i, c) in def.children.enumerated() {
                    group.addTask { let (a, f) = await self.area(c); return (i, a, f) }
                }
                for await (i, a, f) in group { slots[i] = a; failures += f }
            }
            children = slots.compactMap { $0 }
        }
        var (size, ownLower, ownFailures) = await own
        failures += ownFailures

        if size == nil, children.contains(where: { $0.size != nil }) {
            // Eigene Messung fehlt, Kinder sind bekannt: Summe der Kinder als Untergrenze.
            size = children.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        }
        if let restTitle = def.restTitle, let size, ownFailures.isEmpty, !children.contains(where: { $0.size == nil }) {
            let named = children.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            children.append(SystemArea(
                id: "\(def.id).other", url: url, title: restTitle,
                summary: "Alles in „\(def.title)“, was nicht zu den Bereichen darüber gehört.",
                verdict: .keep, size: max(0, size - named),
                isLowerBound: ownLower))
        }

        var verdict = def.verdict
        if def.id == "usrlocal", !FileManager.default.fileExists(atPath: ctx.absolute("/usr/local/texlive").path) {
            verdict = .keep
        }
        let lower = ownLower || children.contains { $0.isLowerBound }
        return (SystemArea(id: def.id, url: url, title: def.title, summary: def.summary, verdict: verdict,
                           size: size, isLowerBound: lower, children: children), failures)
    }

    /// Größe von `path` + `extraPaths` unter Timeout; bei Timeout/Fehler `size == nil`.
    private func ownSize(_ def: SystemAreaDefinition) async -> (Int64?, Bool, [ScanFailure]) {
        let ctx = ctx, sizeOf = sizeOf
        let paths = [def.path] + def.extraPaths
        let result = await Deadline.run(timeout) { () async throws -> (Int64, Bool) in
            var sum: Int64 = 0
            var complete = true
            for p in paths {
                let (urls, resolved) = Self.expand(p, ctx: ctx)
                if !resolved { complete = false }
                for u in urls {
                    let r = try await sizeOf(u)
                    sum += r.size
                    if !r.complete { complete = false }
                }
            }
            return (sum, complete)
        }
        switch result {
        case .success(let (s, complete)): return (s, !complete, [])
        case .failure(let e): return (nil, true, [e.failure(id: "systemdata.\(def.id)")])
        }
    }

    /// Direkte Kinder von Home, ohne Symlinks. `unreadable`: Home selbst war nicht lesbar.
    static func homeChildren(_ home: URL) -> (urls: [URL], unreadable: Bool) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: home.path) else { return ([], fm.fileExists(atPath: home.path)) }
        let urls = names.sorted().map { home.appending(path: $0) }
            .filter { (try? fm.destinationOfSymbolicLink(atPath: $0.path)) == nil }
        return (urls, false)
    }

    /// Misst die Einträge parallel (höchstens 8 gleichzeitig), je mit eigener Frist; Reihenfolge wie `items`.
    func measureAll(_ items: [(url: URL, id: String)]) async -> [(url: URL, size: Int64?, complete: Bool, failures: [ScanFailure])] {
        var results = [(url: URL, size: Int64?, complete: Bool, failures: [ScanFailure])?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, Int64?, Bool, [ScanFailure]).self) { group in
            var next = 0
            func add() {
                guard next < items.count else { return }
                let i = next
                next += 1
                group.addTask {
                    let r = await self.single(items[i].url, id: items[i].id)
                    return (i, r.size, r.complete, r.failures)
                }
            }
            for _ in 0..<min(8, items.count) { add() }
            for await (i, size, complete, f) in group {
                results[i] = (items[i].url, size, complete, f)
                add()
            }
        }
        return results.compactMap { $0 }
    }

    /// Teilt ein Verzeichnis in Unterordner und direkte Nicht-Verzeichnis-Einträge (ohne Symlinks, lstat-Semantik).
    /// nil, wenn das Verzeichnis nicht lesbar ist.
    static func splitEntries(_ dir: URL) -> (dirs: [URL], filesSize: Int64, filesIncomplete: Bool)? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        var dirs: [URL] = []
        var size: Int64 = 0
        var incomplete = false
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        for n in names.sorted() {
            let u = dir.appending(path: n)
            guard let v = try? u.resourceValues(forKeys: keys) else { incomplete = true; continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true { dirs.append(u); continue }
            if let b = v.totalFileAllocatedSize ?? v.fileAllocatedSize { size += Int64(b) } else { incomplete = true }
        }
        return (dirs, size, incomplete)
    }

    func single(_ url: URL, id: String) async -> (size: Int64?, complete: Bool, failures: [ScanFailure]) {
        let sizeOf = sizeOf
        switch await Deadline.run(timeout, { try await sizeOf(url) }) {
        case .success(let r): return (r.size, r.complete, [])
        case .failure(let e): return (nil, false, [e.failure(id: "systemdata.\(id)")])
        }
    }

    private func assetChildren(of root: URL) async -> ([SystemArea], [ScanFailure]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return ([], []) }
        var dirs: [String] = []
        for n in names.sorted() {
            var isDir: ObjCBool = false
            let p = root.appending(path: n).path
            if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue,
               (try? fm.destinationOfSymbolicLink(atPath: p)) == nil { dirs.append(n) }
        }
        var areas: [SystemArea] = []
        var failures: [ScanFailure] = []
        await withTaskGroup(of: (SystemArea, [ScanFailure]).self) { group in
            for n in dirs {
                group.addTask {
                    let url = root.appending(path: n)
                    let entry = AssetNameMap.entry(forAssetDirectory: n)
                    let sizeOf = self.sizeOf
                    let r = await Deadline.run(self.timeout) { try await sizeOf(url) }
                    var f: [ScanFailure] = []
                    var size: Int64?
                    var lower = false
                    switch r {
                    case .success(let m): size = m.size; lower = !m.complete
                    case .failure(let e): lower = true; f = [e.failure(id: "systemdata.assets.\(n)")]
                    }
                    return (SystemArea(id: "assets.\(n)", url: url, title: entry.title,
                                       summary: AssetNameMap.explanation(forAssetDirectory: n),
                                       verdict: entry.verdict, size: size, isLowerBound: lower), f)
                }
            }
            for await (a, f) in group { areas.append(a); failures += f }
        }
        areas.sort { ($0.size ?? -1, $1.id) > ($1.size ?? -1, $0.id) }
        return (areas, failures)
    }

    /// Löst `*`-Komponenten per Verzeichnisliste auf. `resolved == false`: eine Ebene war nicht lesbar.
    static func expand(_ path: String, ctx: ScanContext) -> (urls: [URL], resolved: Bool) {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.contains("*") else { return ([ctx.absolute(path)], true) }
        let fm = FileManager.default
        var current = [ctx.rootPrefix]
        var resolved = true
        for c in comps {
            if c == "*" {
                var next: [URL] = []
                for dir in current {
                    do {
                        for n in try fm.contentsOfDirectory(atPath: dir.path).sorted() { next.append(dir.appending(path: n)) }
                    } catch {
                        if fm.fileExists(atPath: dir.path) { resolved = false }
                    }
                }
                current = next
            } else {
                current = current.map { $0.appending(path: c) }
            }
        }
        return (current.filter { fm.fileExists(atPath: $0.path) }, resolved)
    }
}

// MARK: - Timeout

enum DeadlineError: Error, Sendable {
    case timeout(Duration)
    case cancelled
    case failed(String)

    func failure(id: String) -> ScanFailure {
        switch self {
        case .timeout(let d):
            let c = d.components
            let secs = max(1, c.seconds + (c.attoseconds > 0 ? 1 : 0))
            return ScanFailure(scannerID: id, message: "Zeitüberschreitung nach \(secs) s")
        case .cancelled: return ScanFailure(scannerID: id, message: "Abgebrochen")
        case .failed(let m): return ScanFailure(scannerID: id, message: m)
        }
    }
}

/// Führt `op` mit Frist aus; kehrt nach Ablauf oder Abbruch auch zurück, wenn `op` Cancellation ignoriert.
enum Deadline {
    fileprivate final class Gate<T: Sendable>: Sendable {
        typealias R = Result<T, DeadlineError>
        private struct State {
            var cont: CheckedContinuation<R, Never>?
            var tasks: [Task<Void, Never>] = []
            var result: R?
            var done = false
        }
        private let state = Mutex(State())

        func attach(_ cont: CheckedContinuation<R, Never>, tasks: [Task<Void, Never>]) {
            let early = state.withLock { s -> R? in
                if s.done { return s.result }
                s.cont = cont
                s.tasks = tasks
                return nil
            }
            if let early {
                tasks.forEach { $0.cancel() }
                cont.resume(returning: early)
            }
        }

        func finish(_ r: R) {
            let (cont, tasks) = state.withLock { s -> (CheckedContinuation<R, Never>?, [Task<Void, Never>]) in
                if s.done { return (nil, []) }
                s.done = true
                let out = (s.cont, s.tasks)
                s.cont = nil
                s.tasks = []
                if out.0 == nil { s.result = r }
                return out
            }
            tasks.forEach { $0.cancel() }
            cont?.resume(returning: r)
        }
    }

    static func run<T: Sendable>(_ timeout: Duration, _ op: @escaping @Sendable () async throws -> T) async -> Result<T, DeadlineError> {
        let gate = Gate<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result<T, DeadlineError>, Never>) in
                let work = Task {
                    do { gate.finish(.success(try await op())) }
                    catch is CancellationError { gate.finish(.failure(.cancelled)) }
                    catch { gate.finish(.failure(.failed(error.localizedDescription))) }
                }
                let timer = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    gate.finish(.failure(.timeout(timeout)))
                }
                gate.attach(cont, tasks: [work, timer])
            }
        } onCancel: {
            gate.finish(.failure(.cancelled))
        }
    }
}
