import AppKit
import Foundation
import Observation
import KlarschiffCore

/// Alles, was `PerformanceModel` von außen braucht – in Tests durch Attrappen ersetzbar.
struct PerformanceDependencies: Sendable {
    var systemSampler: any SystemSampling
    var processSampler: any ProcessSampling
    var runningApps: @Sendable () -> [RunningAppInfo]
    /// Bittet die App höflich um das Beenden (nie erzwingen); `expectedBundleID` schützt vor wiederverwendeten PIDs –
    /// ohne Bundle-ID wird nichts beendet.
    var terminate: @Sendable (_ pid: Int32, _ expectedBundleID: String?) async -> Bool
    var spotlightScan: @Sendable () async -> [SpotlightCandidate]
    var sleep: @Sendable (Duration) async throws -> Void
    var now: @Sendable () -> Date

    /// Ohne Messwerte und ohne Wirkung (Vorschau, Tests, die den Tab nicht berühren).
    static var inert: PerformanceDependencies {
        PerformanceDependencies(
            systemSampler: InertSystemSampler(), processSampler: InertProcessSampler(),
            runningApps: { [] }, terminate: { _, _ in false }, spotlightScan: { [] },
            sleep: { try await Task.sleep(for: $0) }, now: { Date() })
    }

    static func live(spotlightScan: @escaping @Sendable () async -> [SpotlightCandidate]) -> PerformanceDependencies {
        PerformanceDependencies(
            systemSampler: LiveSystemSampler(), processSampler: LiveProcessSampler(),
            runningApps: {
                NSWorkspace.shared.runningApplications.map {
                    RunningAppInfo(
                        pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                        name: $0.localizedName ?? $0.bundleIdentifier ?? "Unbekannt",
                        bundlePath: $0.bundleURL?.path, isRegular: $0.activationPolicy == .regular)
                }
            },
            terminate: { pid, expected in
                await MainActor.run {
                    guard let app = NSRunningApplication(processIdentifier: pid),
                          app.activationPolicy == .regular,
                          let expected, app.bundleIdentifier == expected else { return false }
                    return app.terminate()
                }
            },
            spotlightScan: spotlightScan,
            sleep: { try await Task.sleep(for: $0) }, now: { Date() })
    }
}

private struct InertSystemSampler: SystemSampling {
    func sample() -> SystemSample? { nil }
}

private struct InertProcessSampler: ProcessSampling {
    func sample() -> [ProcessSample] { [] }
}

/// Live-Messung für den Tab „Leistung“: alle 2 s ein Tick, nur solange der Tab offen ist (`start`/`stop`).
@MainActor @Observable
final class PerformanceModel {
    static let interval: TimeInterval = 2
    static let historyLimit = 60

    private(set) var cpuLoad: Double = 0
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryUsed: UInt64 = 0
    private(set) var memoryTotal: UInt64 = 0
    private(set) var pressureLevel: Int = 1
    private(set) var swapUsed: UInt64 = 0
    private(set) var bootTime: Date?
    private(set) var top: [ActivityEntry] = []
    private(set) var hints: [SlowdownHint] = []
    private(set) var spotlight: [SpotlightCandidate] = []
    private(set) var isScanningSpotlight = false

    @ObservationIgnored private let deps: PerformanceDependencies
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var previousSystem: SystemSample?
    @ObservationIgnored private var previousProcesses: [ProcessSample]?
    @ObservationIgnored private var aggregator = ActivityAggregator()
    @ObservationIgnored private var detector = SlowdownDetector()
    @ObservationIgnored private var hasScannedSpotlight = false

    init(dependencies: PerformanceDependencies) {
        deps = dependencies
    }

    // MARK: - Messschleife

    func start() {
        guard task == nil else { return }
        // Nach Pause frisch beginnen: alte Messstände ergäben falsche Deltas.
        previousSystem = nil
        previousProcesses = nil
        // Keine veralteten Werte zeigen oder an die Erkennung geben, bis neu gemessen ist.
        top = []
        cpuLoad = 0
        cpuHistory = []
        let sleep = deps.sleep
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await sleep(.seconds(Self.interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        generation += 1
    }

    /// Eine Messung. Veraltete Ticks (nach `stop`) veröffentlichen nichts.
    func tick() async {
        let gen = generation
        let measured = await Self.measure(deps)
        guard gen == generation else { return }
        let apps = deps.runningApps()
        let now = deps.now()

        // Zu große Lücke (Schlaf, Pause): keine Deltas aus dem alten Stand.
        if let a = previousSystem?.date, let b = measured.system?.date,
           b.timeIntervalSince(a) > SlowdownDetector.maxGap || b < a {
            previousSystem = nil
            previousProcesses = nil
        }
        if let sys = measured.system {
            if let prev = previousSystem {
                cpuLoad = PerformanceMath.cpuLoad(prev.cpu, sys.cpu)
                cpuHistory.append(cpuLoad)
                if cpuHistory.count > Self.historyLimit { cpuHistory.removeFirst(cpuHistory.count - Self.historyLimit) }
            }
            memoryUsed = sys.memoryUsed
            memoryTotal = sys.memoryTotal
            pressureLevel = sys.pressureLevel
            swapUsed = sys.swapUsed
            bootTime = sys.bootTime
        }
        var topUpdated = false
        if let prevProcs = previousProcesses {
            topUpdated = true
            var dt = Self.interval
            if let a = previousSystem?.date, let b = measured.system?.date, b > a { dt = b.timeIntervalSince(a) }
            top = aggregator.update(previous: prevProcs, current: measured.processes, interval: dt, apps: apps)
        }
        if let sys = measured.system {
            // Nur frisch gemessene Apps zählen; ohne Delta in diesem Tick gilt keine als beschäftigt.
            hints = detector.update(sample: sys, top: topUpdated ? top : [], now: now)
            previousSystem = sys
        }
        previousProcesses = measured.processes
    }

    private struct Measurement: Sendable {
        var system: SystemSample?
        var processes: [ProcessSample]
    }

    /// Prozess-Abfrage kann einige zehn Millisekunden dauern – nicht auf dem Hauptakteur.
    private nonisolated static func measure(_ deps: PerformanceDependencies) async -> Measurement {
        await Task.detached(priority: .utility) {
            Measurement(system: deps.systemSampler.sample(), processes: deps.processSampler.sample())
        }.value
    }

    // MARK: - Beenden

    /// Nur mit Bundle-ID: sie schützt beim Beenden vor einer inzwischen wiederverwendeten PID.
    func requestQuit(_ e: ActivityEntry) -> Bool {
        e.canQuit && e.quitPID != nil && e.bundleID != nil
    }

    /// Bittet die App höflich um das Beenden. Trockenlauf beendet nichts. Liefert den Ergebnistext.
    func quit(_ e: ActivityEntry, dryRun: Bool) async -> String? {
        guard requestQuit(e), let pid = e.quitPID else { return "\(e.name) kann nicht beendet werden." }
        if dryRun { return "Trockenlauf: \(e.name) würde jetzt beendet." }
        return await deps.terminate(pid, e.bundleID) ? "\(e.name) wird beendet." : "\(e.name) konnte nicht beendet werden."
    }

    // MARK: - Spotlight

    /// Einmal pro App-Start.
    func scanSpotlightIfNeeded() async {
        guard !hasScannedSpotlight else { return }
        await rescanSpotlight()
    }

    func rescanSpotlight() async {
        guard !isScanningSpotlight else { return }
        isScanningSpotlight = true
        hasScannedSpotlight = true
        let result = await deps.spotlightScan()
        spotlight = result
        isScanningSpotlight = false
    }
}
