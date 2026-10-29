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

    /// Alle Prozesse samt Namen. `proc_name` liefert für fremde (root-)Prozesse nichts, daher kommt die
    /// Liste samt `p_comm` aus sysctl (KERN_PROC_ALL). `p_comm` ist auf 16 Zeichen gekürzt; bei
    /// gekürzten Namen wird, soweit lesbar, der volle Name über `proc_name`/`proc_pidpath` ergänzt.
    private static func allProcesses() -> [(pid: pid_t, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let n = min(size / stride, procs.count)
        var out: [(pid_t, String)] = []
        var buf = [CChar](repeating: 0, count: 256)
        var pathBuf = [CChar](repeating: 0, count: 4 * 1024)
        for info in procs.prefix(n) {
            let pid = info.kp_proc.p_pid
            guard pid > 0 else { continue }
            var name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw -> String in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            if name.utf8.count >= 15 {
                let len = proc_name(pid, &buf, UInt32(buf.count))
                if len > 0 { name = String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
                if len >= 31 {
                    let plen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
                    if plen > 0 {
                        let path = String(decoding: pathBuf.prefix(Int(plen)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        name = (path as NSString).lastPathComponent
                    }
                }
            }
            out.append((pid, name))
        }
        return out
    }
}
