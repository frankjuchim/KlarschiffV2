import Foundation
import Darwin

/// Liest die Systemwerte (nur lesend). Liefert nil, wenn eine Abfrage scheitert.
public struct LiveSystemSampler: SystemSampling {
    public init() {}

    public func sample() -> SystemSample? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard let cpu = Self.cpuTicks(host),
              let used = Self.memoryUsed(host),
              let pressure = Self.sysctlInt32("kern.memorystatus_vm_pressure_level"),
              let swap = Self.swapUsed(),
              let boot = Self.bootTime() else { return nil }
        return SystemSample(
            date: Date(), cpu: cpu, memoryUsed: used,
            memoryTotal: ProcessInfo.processInfo.physicalMemory,
            pressureLevel: Int(pressure), swapUsed: swap, bootTime: boot)
    }

    static func cpuTicks(_ host: mach_port_t) -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Index: USER, SYSTEM, IDLE, NICE
        let t = info.cpu_ticks
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    static func memoryUsed(_ host: mach_port_t) -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // vm_kernel_page_size ist unter Swift 6 nicht nebenläufigkeitssicher; gleicher Wert per sysctl.
        guard let size = sysctlInt32("vm.pagesize"), size > 0 else { return nil }
        let pageSize = UInt64(size)
        // Wie die Aktivitätsanzeige: App-Speicher + fest belegt + komprimiert.
        let appPages = UInt64(stats.internal_page_count) &- min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        let pages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * pageSize
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
