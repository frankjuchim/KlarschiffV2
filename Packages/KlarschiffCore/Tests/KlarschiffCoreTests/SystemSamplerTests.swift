import Testing
import Foundation
@testable import KlarschiffCore

struct SystemSamplerTests {
    @Test func cpuWordsBoundaries() {
        #expect(PerformanceWords.cpu(0.299) == "kühl")
        #expect(PerformanceWords.cpu(0.30) == "beschäftigt")
        #expect(PerformanceWords.cpu(0.699) == "beschäftigt")
        #expect(PerformanceWords.cpu(0.70) == "unter Last")
    }

    @Test func memoryWords() {
        #expect(PerformanceWords.memory(pressure: 1) == "entspannt")
        #expect(PerformanceWords.memory(pressure: 2) == "angespannt")
        #expect(PerformanceWords.memory(pressure: 4) == "knapp")
        #expect(PerformanceWords.memory(pressure: 0) == "entspannt")
        #expect(PerformanceWords.memory(pressure: 3) == "angespannt")
    }

    @Test func swapWords() {
        #expect(PerformanceWords.swap(0) == "nichts")
        #expect(PerformanceWords.swap(1) == "wenig")
        #expect(PerformanceWords.swap(2_147_483_647) == "wenig")
        #expect(PerformanceWords.swap(2_147_483_648) == "viel")
    }

    @Test func uptimeTexts() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        func up(_ s: TimeInterval) -> (value: String, word: String) {
            PerformanceWords.uptime(since: now.addingTimeInterval(-s), now: now)
        }
        #expect(up(5 * 3600).value == "5 Stunden")
        #expect(up(60).value == "1 Minute")
        #expect(up(30 * 60).value == "30 Minuten")
        #expect(up(-100).value == "0 Minuten")
        #expect(up(3600).value == "1 Stunde")
        #expect(up(86_400).value == "1 Tag")
        #expect(up(3 * 86_400).value == "3 Tage")
        #expect(up(3 * 86_400).word == "frisch genug")
        #expect(up(6.99 * 86_400).word == "frisch genug")
        #expect(up(7 * 86_400).word == "läuft schon eine Weile")
        #expect(up(20.9 * 86_400).word == "läuft schon eine Weile")
        #expect(up(21 * 86_400).word == "Neustart würde guttun")
    }

    @Test func cpuLoadDelta() {
        let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUTicks(user: 150, system: 70, idle: 955, nice: 0)
        #expect(abs(PerformanceMath.cpuLoad(a, b) - 0.4) < 1e-9)
        #expect(PerformanceMath.cpuLoad(a, a) == 0)
        // Überlauf/Rücksetzen: kein Absturz, 0
        #expect(PerformanceMath.cpuLoad(b, a) == 0)
        let wrapped = CPUTicks(user: 10, system: 0, idle: 10, nice: 0)
        let nearEnd = CPUTicks(user: UInt64(UInt32.max) - 5, system: 0, idle: UInt64(UInt32.max) - 5, nice: 0)
        #expect(abs(PerformanceMath.cpuLoad(nearEnd, wrapped) - 0.5) < 1e-9)
    }

    @Test func liveSampleIsPlausible() throws {
        let s = try #require(LiveSystemSampler().sample())
        #expect(s.memoryTotal == ProcessInfo.processInfo.physicalMemory)
        #expect(s.memoryUsed > 0 && s.memoryUsed <= s.memoryTotal)
        #expect(s.bootTime < s.date)
        #expect([1, 2, 4].contains(s.pressureLevel))
        #expect(s.cpu.user + s.cpu.system + s.cpu.idle > 0)
        let s2 = try #require(LiveSystemSampler().sample())
        #expect(PerformanceMath.cpuLoad(s.cpu, s2.cpu) <= 1)
    }
}
