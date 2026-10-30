import Foundation
import Darwin

public struct ProcessSample: Sendable, Equatable {
    public let pid: Int32
    /// Startzeit in Mikrosekunden seit 1970 (erkennt PID-Wiederverwendung); 0, wenn nicht lesbar.
    public let startTime: UInt64
    public let name: String
    public let path: String?
    public let uid: uid_t
    /// Gesamte CPU-Zeit (User + System) in Nanosekunden; 0, wenn nicht lesbar.
    public let cpuTimeNs: UInt64
    public let residentBytes: UInt64

    public init(pid: Int32, startTime: UInt64, name: String, path: String?, uid: uid_t,
                cpuTimeNs: UInt64, residentBytes: UInt64) {
        self.pid = pid; self.startTime = startTime; self.name = name; self.path = path
        self.uid = uid; self.cpuTimeNs = cpuTimeNs; self.residentBytes = residentBytes
    }
}

public protocol ProcessSampling: Sendable {
    func sample() -> [ProcessSample]
}

/// Liest alle Prozesse über libproc (nur lesend). Fremde (root-)Prozesse verweigern oft `proc_pidinfo`:
/// sie werden trotzdem aufgeführt, aber ohne CPU/RAM.
public struct LiveProcessSampler: ProcessSampling {
    public init() {}

    /// Mach-Absolutzeit -> Nanosekunden (Apple Silicon: 125/3), ohne Überlauf.
    static func machToNanoseconds(_ ticks: UInt64, numer: UInt64, denom: UInt64) -> UInt64 {
        let r = UInt128(ticks) * UInt128(numer) / UInt128(max(denom, 1))
        return r > UInt128(UInt64.max) ? UInt64.max : UInt64(r)
    }

    /// PID 0 (Kernel) wird übersprungen. Ist `proc_bsdinfo` nicht lesbar, ist `startTime` 0 (dann gibt es
    /// keine PID-Wiederverwendungsprüfung über Zeit, aber auch keine CPU-Daten) und `uid` 0.
    public func sample() -> [ProcessSample] {
        // proc_listallpids liefert die ANZAHL der PIDs, nicht Bytes.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return [] }

        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let numer = UInt64(max(tb.numer, 1)), denom = UInt64(max(tb.denom, 1))

        var out: [ProcessSample] = []
        out.reserveCapacity(count)
        var nameBuf = [CChar](repeating: 0, count: 256)
        var pathBuf = [CChar](repeating: 0, count: 4 * 1024)
        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            var bsd = proc_bsdinfo()
            let bsdOK = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
                == Int32(MemoryLayout<proc_bsdinfo>.size)
            var task = proc_taskinfo()
            let taskOK = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
                == Int32(MemoryLayout<proc_taskinfo>.size)

            var path: String?
            let plen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            if plen > 0 {
                path = String(decoding: pathBuf.prefix(Int(plen)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            var name = ""
            let nlen = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            if nlen > 0 {
                name = String(decoding: nameBuf.prefix(Int(nlen)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            } else if let p = path {
                name = (p as NSString).lastPathComponent
            } else if bsdOK {
                name = withUnsafeBytes(of: bsd.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            if name.isEmpty { continue }   // beendet oder nicht lesbar

            let start = bsdOK ? UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec) : 0
            let uid: uid_t = bsdOK ? bsd.pbi_uid : 0
            var cpu: UInt64 = 0
            var resident: UInt64 = 0
            if taskOK {
                // Auf Apple Silicon sind die Zeiten Mach-Absolutzeit: in Nanosekunden umrechnen.
                let ticks = task.pti_total_user &+ task.pti_total_system
                cpu = Self.machToNanoseconds(ticks, numer: numer, denom: denom)
                resident = task.pti_resident_size
            }
            // Speicher wie die Aktivitätsanzeige (phys_footprint), sonst Resident Size.
            var usage = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            if rc == 0, usage.ri_phys_footprint > 0 { resident = usage.ri_phys_footprint }

            out.append(ProcessSample(pid: pid, startTime: start, name: name, path: path, uid: uid,
                                     cpuTimeNs: cpu, residentBytes: resident))
        }
        return out
    }
}
