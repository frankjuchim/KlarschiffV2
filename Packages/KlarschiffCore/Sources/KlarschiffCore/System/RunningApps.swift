import AppKit
import Foundation
import Darwin

public protocol RunningApps: Sendable {
    func running(_ refs: [AppRef]) -> [AppRef]
    func terminate(_ ref: AppRef) async -> Bool
}

/// Produktion: Bundle-IDs über NSWorkspace, Prozessnamen über libproc (ohne Shell, exakter Namensvergleich).
public struct WorkspaceRunningApps: RunningApps {
    public init() {}

    public func running(_ refs: [AppRef]) -> [AppRef] {
        let bundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let needsProcs = refs.contains { $0.processName != nil }
        let procNames = needsProcs ? Set(Self.allProcesses().map(\.name)) : []
        return refs.filter { ref in
            if let b = ref.bundleID, bundleIDs.contains(b) { return true }
            if let p = ref.processName, procNames.contains(p) { return true }
            return false
        }
    }

    public func terminate(_ ref: AppRef) async -> Bool {
        if let b = ref.bundleID {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: b)
            if !apps.isEmpty {
                var sent = false
                for app in apps where app.terminate() { sent = true }
                return sent
            }
        }
        if let p = ref.processName {
            var sent = false
            for proc in Self.allProcesses() where proc.name == p {
                if kill(proc.pid, SIGTERM) == 0 { sent = true }
            }
            return sent
        }
        return false
    }

    private static func allProcesses() -> [(pid: pid_t, name: String)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let n = Int(bytes) / MemoryLayout<pid_t>.size
        var out: [(pid_t, String)] = []
        var buf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(n) where pid > 0 {
            let len = proc_name(pid, &buf, UInt32(buf.count))
            if len > 0 { out.append((pid, String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self))) }
        }
        return out
    }
}
