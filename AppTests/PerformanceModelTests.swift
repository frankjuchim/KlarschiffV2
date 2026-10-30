import Foundation
import Testing
import KlarschiffCore
@testable import Klarschiff

private final class FakeSystem: SystemSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var n: UInt64 = 0
    private var gate: DispatchSemaphore?
    func blockNext(_ g: DispatchSemaphore) { lock.lock(); gate = g; lock.unlock() }
    func sample() -> SystemSample? {
        lock.lock(); n += 1; let i = n; let g = gate; gate = nil; lock.unlock()
        g?.wait()
        return SystemSample(
            date: Date(timeIntervalSince1970: Double(i) * 2),
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

private func entry(canQuit: Bool = true, pid: Int32? = 42) -> ActivityEntry {
    ActivityEntry(
        id: "x", name: "Beispiel", appPath: "/Applications/Beispiel.app", bundleID: "b", processCount: 1,
        residentBytes: 1, cpuPercent: 1, isSystem: false, canQuit: canQuit, quitPID: pid, history: [])
}

@MainActor
private func makeModel(system: FakeSystem = FakeSystem(), calls: Calls = Calls(), terminateResult: Bool = true)
    -> PerformanceModel
{
    PerformanceModel(dependencies: PerformanceDependencies(
        systemSampler: system, processSampler: FakeProcesses(), runningApps: { [] },
        terminate: { calls.terminate($0); return terminateResult },
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
    let m = makeModel()
    m.start(); m.start()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(m.memoryTotal == 16)
    m.stop()
    m.stop()
}

@Test @MainActor func quitOnlyWhenAllowed() async {
    let calls = Calls()
    let m = makeModel(calls: calls)
    #expect(m.requestQuit(entry()))
    #expect(!m.requestQuit(entry(canQuit: false)))
    #expect(!m.requestQuit(entry(pid: nil)))
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
