import Foundation

/// Von der App aus NSWorkspace geliefert (Core kennt kein AppKit-Objekt).
public struct RunningAppInfo: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String?
    public let name: String
    public let bundlePath: String?
    public let isRegular: Bool
    public init(pid: Int32, bundleID: String?, name: String, bundlePath: String?, isRegular: Bool) {
        self.pid = pid; self.bundleID = bundleID; self.name = name
        self.bundlePath = bundlePath; self.isRegular = isRegular
    }
}

public struct ActivityEntry: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let appPath: String?
    public let bundleID: String?
    public let processCount: Int
    public let residentBytes: UInt64
    /// Summe über alle Kerne, kann wie in der Aktivitätsanzeige über 100 liegen.
    public let cpuPercent: Double
    public let isSystem: Bool
    public let canQuit: Bool
    /// PID des einen regulären App-Prozesses, den „Beenden“ treffen darf; nil, wenn canQuit false ist.
    public let quitPID: Int32?
    public let history: [Double]
}

public struct ActivityAggregator: Sendable {
    public static let historyLimit = 60
    public static let topCount = 12
    static var protectedBundleIDs: Set<String> {
        var ids: Set<String> = ["de.frankjuchim.klarschiff2", "com.apple.finder"]
        if let own = Bundle.main.bundleIdentifier { ids.insert(own) }
        return ids
    }
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    private var histories: [String: [Double]] = [:]

    public init() {}

    /// Äußerstes `*.app` im Pfad (Helfer innerhalb eines Bundles zählen zur App).
    static func outermostApp(_ path: String) -> String? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let i = comps.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) else { return nil }
        return "/" + comps[0...i].joined(separator: "/")
    }

    static func isSystemProcess(_ p: ProcessSample, regularApp: Bool = false) -> Bool {
        if p.uid < 500 { return true }   // root und _-Dienstkonten
        // Reguläre Apps unter /System/Applications (z. B. Safari) sind keine Systemdienste,
        // alles andere unter /System (z. B. CoreServices) schon.
        if regularApp, p.path?.hasPrefix("/System/Applications/") == true { return false }
        if let path = p.path, systemPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        return false
    }

    private struct Group {
        var name: String
        var appPath: String?
        var bundleID: String?
        var count = 0
        var ram: UInt64 = 0
        var cpuNs: UInt64 = 0
        var allSystem = true
        var regularInfos: [RunningAppInfo] = []
        var protected = false
    }

    public mutating func update(previous: [ProcessSample], current: [ProcessSample],
                                interval: TimeInterval, apps: [RunningAppInfo]) -> [ActivityEntry] {
        let appByPid = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var prevByPid: [Int32: ProcessSample] = [:]
        for p in previous { prevByPid[p.pid] = p }

        var groups: [String: Group] = [:]
        for p in current {
            let info = appByPid[p.pid]
            // Eine reguläre App bildet ihre eigene Gruppe (z. B. Simulator in Xcode); Helfer ohne
            // RunningAppInfo gehören zum äußersten .app im Pfad.
            let appPath: String?
            if let info, info.isRegular, let bp = info.bundlePath { appPath = bp }
            else { appPath = p.path.flatMap(Self.outermostApp) ?? info?.bundlePath }
            let id = appPath ?? p.name
            var g = groups[id] ?? Group(
                name: appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? p.name,
                appPath: appPath)
            if let info {
                if g.bundleID == nil { g.bundleID = info.bundleID }
                if info.isRegular { g.regularInfos.append(info) }
                if let b = info.bundleID, Self.protectedBundleIDs.contains(b) { g.protected = true }
            }
            if p.pid == getpid() { g.protected = true }
            g.count += 1
            g.ram += p.residentBytes
            if let old = prevByPid[p.pid], old.startTime == p.startTime, p.cpuTimeNs >= old.cpuTimeNs {
                g.cpuNs += p.cpuTimeNs - old.cpuTimeNs
            }
            if !Self.isSystemProcess(p, regularApp: info?.isRegular ?? false) { g.allSystem = false }
            groups[id] = g
        }

        let seconds = max(interval, 0.001)
        var entries: [ActivityEntry] = []
        var newHistories: [String: [Double]] = [:]
        for (id, g) in groups {
            let cpu = Double(g.cpuNs) / (seconds * 1_000_000_000) * 100
            var h = histories[id] ?? []
            h.append(cpu)
            if h.count > Self.historyLimit { h.removeFirst(h.count - Self.historyLimit) }
            newHistories[id] = h
            let isSystem = g.allSystem
            // Genau ein regulärer Prozess, dessen Bundle-Pfad die Gruppe ist; sonst nie beenden.
            let mains = g.regularInfos.filter { $0.bundlePath == g.appPath }
            let main = mains.count == 1 ? mains[0] : nil
            let protected = g.protected || (g.appPath?.hasSuffix("Finder.app") ?? false)
            let quitPID = (main != nil && !isSystem && !protected) ? main?.pid : nil
            let name = main?.name ?? g.name
            let bundleID = main?.bundleID ?? g.bundleID
            entries.append(ActivityEntry(id: id, name: name, appPath: g.appPath, bundleID: bundleID,
                                         processCount: g.count, residentBytes: g.ram, cpuPercent: cpu,
                                         isSystem: isSystem, canQuit: quitPID != nil, quitPID: quitPID, history: h))
        }
        histories = newHistories   // beendete Apps verlieren ihren Verlauf
        entries.sort {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
        return Array(entries.prefix(Self.topCount))
    }
}
