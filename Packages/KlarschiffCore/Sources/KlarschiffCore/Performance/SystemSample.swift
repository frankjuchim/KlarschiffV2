import Foundation

/// Kumulierte CPU-Ticks des Hosts (Zähler seit Start, 32 Bit breit).
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Eine Momentaufnahme der Systemwerte.
public struct SystemSample: Sendable {
    public var date: Date
    public var cpu: CPUTicks
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    /// 1 = entspannt, 2 = angespannt, 4 = knapp.
    public var pressureLevel: Int
    public var swapUsed: UInt64
    public var bootTime: Date

    public init(date: Date, cpu: CPUTicks, memoryUsed: UInt64, memoryTotal: UInt64,
                pressureLevel: Int, swapUsed: UInt64, bootTime: Date) {
        self.date = date
        self.cpu = cpu
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.pressureLevel = pressureLevel
        self.swapUsed = swapUsed
        self.bootTime = bootTime
    }
}

public protocol SystemSampling: Sendable {
    func sample() -> SystemSample?
}
