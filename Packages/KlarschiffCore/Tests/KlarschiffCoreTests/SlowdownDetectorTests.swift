import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct SlowdownDetectorTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func sample(_ at: Date, pressure: Int = 1, swap: UInt64 = 0) -> SystemSample {
        SystemSample(date: at, cpu: CPUTicks(user: 0, system: 0, idle: 0, nice: 0), memoryUsed: 1, memoryTotal: 2,
                     pressureLevel: pressure, swapUsed: swap, bootTime: t0)
    }

    func entry(_ id: String = "app", name: String = "Xcode", cpu: Double) -> ActivityEntry {
        ActivityEntry(id: id, name: name, appPath: nil, bundleID: nil, processCount: 1, residentBytes: 0,
                      cpuPercent: cpu, isSystem: false, canQuit: true, quitPID: nil, history: [])
    }

    @Test func cpuHintAppearsAtExactly180Seconds() {
        var d = SlowdownDetector()
        #expect(d.update(sample: sample(t0), top: [entry(cpu: 95)], now: t0).isEmpty)
        #expect(d.update(sample: sample(t0.addingTimeInterval(179)), top: [entry(cpu: 95)], now: t0.addingTimeInterval(179)).isEmpty)
        let hints = d.update(sample: sample(t0.addingTimeInterval(180)), top: [entry(cpu: 95)], now: t0.addingTimeInterval(180))
        #expect(hints.map(\.id) == ["cpu.app"])
        #expect(hints[0].title.contains("Xcode"))
        #expect(hints[0].title == "Xcode rechnet seit Minuten stark")
    }

    @Test func cpuInterruptionResets() {
        var d = SlowdownDetector()
        _ = d.update(sample: sample(t0), top: [entry(cpu: 95)], now: t0)
        _ = d.update(sample: sample(t0.addingTimeInterval(100)), top: [entry(cpu: 10)], now: t0.addingTimeInterval(100))
        let t = t0.addingTimeInterval(200)
        #expect(d.update(sample: sample(t), top: [entry(cpu: 95)], now: t).isEmpty)
        let later = t0.addingTimeInterval(379)
        #expect(d.update(sample: sample(later), top: [entry(cpu: 95)], now: later).isEmpty)
        let ok = t0.addingTimeInterval(380)
        #expect(d.update(sample: sample(ok), top: [entry(cpu: 95)], now: ok).count == 1)
    }

    @Test func cpuThresholdIsStrictAndEntryDisappearingResets() {
        var d = SlowdownDetector()
        _ = d.update(sample: sample(t0), top: [entry(cpu: 80)], now: t0)
        let t = t0.addingTimeInterval(200)
        #expect(d.update(sample: sample(t), top: [entry(cpu: 80)], now: t).isEmpty)
        _ = d.update(sample: sample(t0.addingTimeInterval(210)), top: [entry(cpu: 90)], now: t0.addingTimeInterval(210))
        _ = d.update(sample: sample(t0.addingTimeInterval(300)), top: [], now: t0.addingTimeInterval(300))
        let u = t0.addingTimeInterval(400)
        #expect(d.update(sample: sample(u), top: [entry(cpu: 90)], now: u).isEmpty)
    }

    @Test func pressureRule() {
        var d = SlowdownDetector()
        _ = d.update(sample: sample(t0, pressure: 2), top: [], now: t0)
        #expect(d.update(sample: sample(t0.addingTimeInterval(179), pressure: 4), top: [], now: t0.addingTimeInterval(179)).isEmpty)
        let hints = d.update(sample: sample(t0.addingTimeInterval(180), pressure: 2), top: [], now: t0.addingTimeInterval(180))
        #expect(hints.map(\.id) == ["pressure"])
        #expect(hints[0].title.contains("Arbeitsspeicher"))
        // Unterbrechung
        _ = d.update(sample: sample(t0.addingTimeInterval(200), pressure: 1), top: [], now: t0.addingTimeInterval(200))
        #expect(d.update(sample: sample(t0.addingTimeInterval(300), pressure: 2), top: [], now: t0.addingTimeInterval(300)).isEmpty)
    }

    @Test func pressureLevelOneNeverHints() {
        var d = SlowdownDetector()
        _ = d.update(sample: sample(t0), top: [], now: t0)
        #expect(d.update(sample: sample(t0.addingTimeInterval(600)), top: [], now: t0.addingTimeInterval(600)).isEmpty)
    }

    @Test func swapGrowthRule() {
        var d = SlowdownDetector()
        _ = d.update(sample: sample(t0, swap: 1_000_000_000), top: [], now: t0)
        let a = t0.addingTimeInterval(179)
        #expect(d.update(sample: sample(a, swap: 3_000_000_000), top: [], now: a).isEmpty)
        let b = t0.addingTimeInterval(180)
        let hints = d.update(sample: sample(b, swap: 2_000_000_001), top: [], now: b)
        #expect(hints.map(\.id) == ["swap"])
    }

    @Test func swapGrowthExactlyOneGBDoesNotHint() {
        var d = SlowdownDetector()
        _ = d.update(sample: sample(t0, swap: 0), top: [], now: t0)
        let b = t0.addingTimeInterval(180)
        #expect(d.update(sample: sample(b, swap: 1_000_000_000), top: [], now: b).isEmpty)
    }

    @Test func swapUsesSlidingWindow() {
        var d = SlowdownDetector()
        // Große Zunahme früh, danach Plateau: Fenster schiebt sich weiter, kein Hinweis mehr.
        _ = d.update(sample: sample(t0, swap: 0), top: [], now: t0)
        _ = d.update(sample: sample(t0.addingTimeInterval(60), swap: 5_000_000_000), top: [], now: t0.addingTimeInterval(60))
        let t = t0.addingTimeInterval(400)
        #expect(d.update(sample: sample(t, swap: 5_000_000_000), top: [], now: t).isEmpty)
        let u = t0.addingTimeInterval(500)
        #expect(d.update(sample: sample(u, swap: 5_000_000_000), top: [], now: u).isEmpty)
    }

    @Test func swapShrinkingDoesNotHintAndNothingHintsInitially() {
        var d = SlowdownDetector()
        #expect(d.update(sample: sample(t0, swap: 9_000_000_000), top: [entry(cpu: 99)], now: t0).isEmpty)
        let b = t0.addingTimeInterval(200)
        #expect(d.update(sample: sample(b, swap: 1_000), top: [], now: b).isEmpty)
    }
}
