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

    /// Speist Messungen im 10-s-Takt von `from` bis `to` (Sekunden nach t0) ein; liefert die Hinweise der letzten.
    @discardableResult
    func feed(_ d: inout SlowdownDetector, _ from: Double, _ to: Double, top: [ActivityEntry] = [],
              pressure: Int = 1, swap: UInt64 = 0) -> [SlowdownHint] {
        var last: [SlowdownHint] = []
        var s = from
        while true {
            let t = t0.addingTimeInterval(min(s, to))
            last = d.update(sample: sample(t, pressure: pressure, swap: swap), top: top, now: t)
            if s >= to { break }
            s += 10
        }
        return last
    }

    @Test func cpuHintAppearsAtExactly180Seconds() {
        var d = SlowdownDetector()
        #expect(feed(&d, 0, 179, top: [entry(cpu: 95)]).isEmpty)
        let hints = feed(&d, 180, 180, top: [entry(cpu: 95)])
        #expect(hints.map(\.id) == ["cpu.app"])
        #expect(hints[0].title == "Xcode rechnet seit Minuten stark")
    }

    @Test func cpuInterruptionResets() {
        var d = SlowdownDetector()
        feed(&d, 0, 100, top: [entry(cpu: 95)])
        feed(&d, 110, 120, top: [entry(cpu: 10)])
        #expect(feed(&d, 130, 309, top: [entry(cpu: 95)]).isEmpty)
        #expect(feed(&d, 310, 310, top: [entry(cpu: 95)]).count == 1)
    }

    @Test func cpuThresholdIsStrictAndEntryDisappearingResets() {
        var d = SlowdownDetector()
        #expect(feed(&d, 0, 200, top: [entry(cpu: 80)]).isEmpty)
        feed(&d, 210, 300, top: [entry(cpu: 90)])
        feed(&d, 310, 320, top: [])
        #expect(feed(&d, 330, 490, top: [entry(cpu: 90)]).isEmpty)
    }

    @Test func pressureRule() {
        var d = SlowdownDetector()
        feed(&d, 0, 100, pressure: 2)
        #expect(feed(&d, 110, 179, pressure: 4).isEmpty)
        let hints = feed(&d, 180, 180, pressure: 2)
        #expect(hints.map(\.id) == ["pressure"])
        #expect(hints[0].title.contains("Arbeitsspeicher"))
        feed(&d, 190, 200, pressure: 1)
        #expect(feed(&d, 210, 300, pressure: 2).isEmpty)
    }

    @Test func pressureLevelOneNeverHints() {
        var d = SlowdownDetector()
        #expect(feed(&d, 0, 600).isEmpty)
    }

    @Test func swapGrowthRule() {
        var d = SlowdownDetector()
        feed(&d, 0, 100, swap: 1_000_000_000)
        #expect(feed(&d, 110, 179, swap: 3_000_000_000).isEmpty)
        #expect(feed(&d, 180, 180, swap: 2_000_000_001).map(\.id) == ["swap"])
    }

    @Test func swapGrowthExactlyOneGBDoesNotHint() {
        var d = SlowdownDetector()
        feed(&d, 0, 100, swap: 0)
        #expect(feed(&d, 110, 180, swap: 1_000_000_000).isEmpty)
    }

    @Test func swapUsesSlidingWindow() {
        var d = SlowdownDetector()
        feed(&d, 0, 50, swap: 0)
        feed(&d, 60, 400, swap: 5_000_000_000)
        #expect(feed(&d, 410, 500, swap: 5_000_000_000).isEmpty)
    }

    @Test func swapShrinkingDoesNotHintAndNothingHintsInitially() {
        var d = SlowdownDetector()
        #expect(feed(&d, 0, 0, top: [entry(cpu: 99)], swap: 9_000_000_000).isEmpty)
        #expect(feed(&d, 10, 200, swap: 1_000).isEmpty)
    }
}

extension SlowdownDetectorTests {
    @Test func gapResetsCPU() {
        var d = SlowdownDetector()
        _ = d.update(sample: sample(t0), top: [entry(cpu: 95)], now: t0)
        let t = t0.addingTimeInterval(3600)
        #expect(d.update(sample: sample(t), top: [entry(cpu: 95)], now: t).isEmpty)
    }

    @Test func gapResetsSwapAndPressure() {
        var d = SlowdownDetector()
        _ = d.update(sample: sample(t0, pressure: 2, swap: 0), top: [], now: t0)
        let t = t0.addingTimeInterval(3600)
        #expect(d.update(sample: sample(t, pressure: 2, swap: 5_000_000_000), top: [], now: t).isEmpty)
    }

    @Test func regularCadenceStillFires() {
        var d = SlowdownDetector()
        var last: [SlowdownHint] = []
        for i in 0...90 {
            let t = t0.addingTimeInterval(Double(i) * 2)
            last = d.update(sample: sample(t), top: [entry(cpu: 95)], now: t)
            if i < 90 { #expect(last.isEmpty) }
        }
        #expect(last.count == 1)
    }

    @Test func multipleHintsAtOnce() {
        var d = SlowdownDetector()
        let tops = [entry("a", name: "A", cpu: 90), entry("b", name: "B", cpu: 99)]
        var last: [SlowdownHint] = []
        for i in 0...90 {
            let t = t0.addingTimeInterval(Double(i) * 2)
            last = d.update(sample: sample(t, pressure: 4, swap: UInt64(i) * 50_000_000), top: tops, now: t)
        }
        #expect(Set(last.map(\.id)) == ["cpu.a", "cpu.b", "pressure", "swap"])
    }
}
