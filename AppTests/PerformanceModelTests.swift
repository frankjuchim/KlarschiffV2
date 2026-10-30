import Foundation
import Testing
import KlarschiffCore
@testable import Klarschiff

private final class FakeSystem: SystemSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var n: UInt64 = 0
    private var gate: DispatchSemaphore?
    private var offset: Double = 0
    func jump(_ seconds: Double) { lock.lock(); offset += seconds; lock.unlock() }
    var count: UInt64 { lock.lock(); defer { lock.unlock() }; return n }
    func blockNext(_ g: DispatchSemaphore) { lock.lock(); gate = g; lock.unlock() }
    func sample() -> SystemSample? {
        lock.lock(); n += 1; let i = n; let g = gate; gate = nil; let off = offset; lock.unlock()
        g?.wait()
        return SystemSample(
            date: Date(timeIntervalSince1970: Double(i) * 2 + off),
            cpu: CPUTicks(user: i * 50, system: i * 10, idle: i * 40, nice: 0),
            memoryUsed: 8, memoryTotal: 16, pressureLevel: 1, swapUsed: 0, bootTime: Date(timeIntervalSince1970: 0))
    }
}

private struct FakeProcesses: ProcessSampling {
    func sample() -> [ProcessSample] { [] }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [Int32] = []
    private var scans = 0
    var terminated: [Int32] { lock.lock(); defer { lock.unlock() }; return pids }
    var scanCount: Int { lock.lock(); defer { lock.unlock() }; return scans }
    func terminate(_ p: Int32) { lock.lock(); pids.append(p); lock.unlock() }
    func scan() { lock.lock(); scans += 1; lock.unlock() }
}

private func entry(canQuit: Bool = true, pid: Int32? = 42, bundleID: String? = "b") -> ActivityEntry {
    ActivityEntry(
        id: "x", name: "Beispiel", appPath: "/Applications/Beispiel.app", bundleID: bundleID, processCount: 1,
        residentBytes: 1, cpuPercent: 1, isSystem: false, canQuit: canQuit, quitPID: pid, history: [])
}

@MainActor
private func makeModel(system: FakeSystem = FakeSystem(), calls: Calls = Calls(), terminateResult: Bool = true)
    -> PerformanceModel
{
    PerformanceModel(dependencies: PerformanceDependencies(
        systemSampler: system, processSampler: FakeProcesses(), runningApps: { [] },
        terminate: { pid, _ in calls.terminate(pid); return terminateResult },
        spotlightScan: { calls.scan(); return [] },
        sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, now: { Date() }))
}

@Test @MainActor func firstTickHasNoCpuHistoryThenFillsAndCaps() async {
    let m = makeModel()
    await m.tick()
    #expect(m.cpuHistory.isEmpty)
    #expect(m.cpuLoad == 0)
    #expect(m.memoryTotal == 16)
    await m.tick()
    #expect(m.cpuHistory.count == 1)
    #expect(abs(m.cpuLoad - 0.6) < 0.001)
    for _ in 0..<70 { await m.tick() }
    #expect(m.cpuHistory.count == 60)
}

@Test @MainActor func staleTickAfterStopPublishesNothing() async {
    let system = FakeSystem()
    let m = makeModel(system: system)
    await m.tick()
    let gate = DispatchSemaphore(value: 0)
    system.blockNext(gate)
    let t = Task { await m.tick() }
    try? await Task.sleep(for: .milliseconds(100))
    m.stop()
    gate.signal()
    await t.value
    #expect(m.cpuHistory.isEmpty)
    #expect(m.cpuLoad == 0)
}

@Test @MainActor func startIsIdempotentAndStopCancels() async {
    let system = FakeSystem()
    let m = makeModel(system: system)
    m.start(); m.start()
    try? await Task.sleep(for: .milliseconds(300))
    #expect(system.count == 1)
    m.stop()
    let after = system.count
    try? await Task.sleep(for: .milliseconds(200))
    #expect(system.count == after)
}

@Test @MainActor func restartBeginsFresh() async {
    let m = makeModel()
    await m.tick()
    await m.tick()
    #expect(m.cpuHistory.count == 1)
    m.stop()
    m.start()
    try? await Task.sleep(for: .milliseconds(300))
    m.stop()
    // Erster Tick nach dem Neustart hat noch kein Delta: wieder „–“ statt alter Werte.
    #expect(m.cpuHistory.isEmpty)
    #expect(m.cpuLoad == 0)
}

/// Ein Prozess, der pro Tick 2 s Rechenzeit verbraucht (100 % bei 2-s-Takt).
private final class BusyProcesses: ProcessSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var n: UInt64 = 0
    func sample() -> [ProcessSample] {
        lock.lock(); n += 1; let i = n; lock.unlock()
        return [ProcessSample(pid: 4242, startTime: 1, name: "busy", path: "/Users/x/bin/busy", uid: 501,
                              cpuTimeNs: i * 2_000_000_000, residentBytes: 1)]
    }
}

@Test @MainActor func restartClearsTopAndDetectorSeesNoStaleTop() async {
    let clock = Clock()
    let system = FakeSystem()
    let m = PerformanceModel(dependencies: PerformanceDependencies(
        systemSampler: system, processSampler: BusyProcesses(), runningApps: { [] },
        terminate: { _, _ in false }, spotlightScan: { [] },
        sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, now: { clock.now }))
    await m.tick()
    clock.advance(2)
    await m.tick()
    #expect(m.top.first?.name == "busy")
    #expect((m.top.first?.cpuPercent ?? 0) > 90)

    // Jeder Tick nach einer Messlücke hat kein Delta: `top` ist dann nicht frisch und darf
    // über 180 s keinen CPU-Hinweis auslösen.
    for _ in 0..<100 {
        system.jump(60)
        clock.advance(2)
        await m.tick()
    }
    #expect(!m.hints.contains { $0.id.hasPrefix("cpu.") })

    m.stop()
    m.start()
    #expect(m.top.isEmpty)
    #expect(m.cpuLoad == 0)
    #expect(m.cpuHistory.isEmpty)
    m.stop()
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 0)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: Double) { lock.lock(); t += s; lock.unlock() }
}

@Test @MainActor func largeClockGapAddsNoEntry() async {
    let system = FakeSystem()
    let m = makeModel(system: system)
    await m.tick()
    await m.tick()
    #expect(m.cpuHistory.count == 1)
    system.jump(60)
    await m.tick()
    #expect(m.cpuHistory.count == 1)
    await m.tick()
    #expect(m.cpuHistory.count == 2)
}

@Test @MainActor func quitOnlyWhenAllowed() async {
    let calls = Calls()
    let m = makeModel(calls: calls)
    #expect(m.requestQuit(entry()))
    #expect(!m.requestQuit(entry(canQuit: false)))
    #expect(!m.requestQuit(entry(pid: nil)))
    #expect(!m.requestQuit(entry(bundleID: nil)))
    #expect(await m.quit(entry(bundleID: nil), dryRun: false) == "Beispiel kann nicht beendet werden.")
    let text = await m.quit(entry(canQuit: false), dryRun: false)
    #expect(text == "Beispiel kann nicht beendet werden.")
    #expect(calls.terminated.isEmpty)
    #expect(await m.quit(entry(), dryRun: false) == "Beispiel wird beendet.")
    #expect(calls.terminated == [42])
}

@Test @MainActor func quitFailureText() async {
    let m = makeModel(terminateResult: false)
    #expect(await m.quit(entry(), dryRun: false) == "Beispiel konnte nicht beendet werden.")
}

@Test @MainActor func dryRunNeverTerminates() async {
    let calls = Calls()
    let m = makeModel(calls: calls)
    #expect(await m.quit(entry(), dryRun: true) == "Trockenlauf: Beispiel würde jetzt beendet.")
    #expect(calls.terminated.isEmpty)
}

@Test @MainActor func spotlightScansOncePerLifetime() async {
    let calls = Calls()
    let m = makeModel(calls: calls)
    await m.scanSpotlightIfNeeded()
    await m.scanSpotlightIfNeeded()
    #expect(calls.scanCount == 1)
    await m.rescanSpotlight()
    #expect(calls.scanCount == 2)
    #expect(!m.isScanningSpotlight)
}
