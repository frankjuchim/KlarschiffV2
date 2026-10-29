import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct GrowthWatcherTests {
    static let gb: Int64 = 1_000_000_000

    func snap(sizes: [String: Int64] = [:], cleanable: Int64 = 0,
              free: Int64 = 100 * gb, total: Int64 = 500 * gb) -> CheckSnapshot {
        CheckSnapshot(date: Date(), cleanableTotal: cleanable, freeBytes: free, totalBytes: total,
                      sizes: sizes, titles: Dictionary(uniqueKeysWithValues: sizes.keys.map { ($0, "T-\($0)") }),
                      alerts: [])
    }
    static var gbv: Int64 { gb }

    @Test func firstCheckNoGrowth() {
        let a = GrowthWatcher.alerts(previous: nil, current: snap(sizes: ["a/x": 50 * Self.gb]))
        #expect(a.isEmpty)
    }

    @Test func growthAbove5GB() {
        let a = GrowthWatcher.alerts(previous: snap(sizes: ["a/x": 10 * Self.gb]),
                                     current: snap(sizes: ["a/x": 16 * Self.gb]))
        #expect(a == [.growth(id: "a/x", title: "T-a/x", from: 10 * Self.gb, to: 16 * Self.gb)])
    }

    @Test func growthAbove2GBAndDoubled() {
        let g = Self.gb
        let p = snap(sizes: ["a": 2_100_000_000, "b": 3 * g])
        let c = snap(sizes: ["a": 4_300_000_000, "b": 5_500_000_000])
        let a = GrowthWatcher.alerts(previous: p, current: c)
        #expect(a == [.growth(id: "a", title: "T-a", from: 2_100_000_000, to: 4_300_000_000)])
    }

    @Test func exactThresholds() {
        let p = snap(sizes: ["a": 20_000_000_000, "b": 20_000_000_000])
        let c = snap(sizes: ["a": 25_000_000_000, "b": 24_999_999_999])
        let a = GrowthWatcher.alerts(previous: p, current: c)
        #expect(a.count == 1)
        if case .growth(let id, _, _, _) = a[0] { #expect(id == "a") } else { Issue.record("kein growth") }
    }

    @Test func newIDNoGrowth() {
        let a = GrowthWatcher.alerts(previous: snap(sizes: ["a": 1]),
                                     current: snap(sizes: ["a": 1, "new": 90 * Self.gb]))
        #expect(a.isEmpty)
    }

    @Test func cleanableAtLeast1GB() {
        #expect(GrowthWatcher.alerts(previous: nil, current: snap(cleanable: 1_000_000_000))
                == [.cleanable(total: 1_000_000_000)])
        #expect(GrowthWatcher.alerts(previous: nil, current: snap(cleanable: 999_999_999)).isEmpty)
    }

    @Test func lowSpaceByPercentOrAbsolute() {
        let g = Self.gb
        // 9 % frei bei 2 TB (180 GB frei, > 20 GB) -> meldet
        #expect(GrowthWatcher.alerts(previous: nil, current: snap(free: 180 * g, total: 2000 * g))
                == [.lowSpace(free: 180 * g, total: 2000 * g)])
        // 19 GB frei bei 100 GB (19 %) -> meldet (absolut)
        #expect(GrowthWatcher.alerts(previous: nil, current: snap(free: 19 * g, total: 100 * g))
                == [.lowSpace(free: 19 * g, total: 100 * g)])
        // genau 10 % und genau 20 GB -> meldet nicht
        #expect(GrowthWatcher.alerts(previous: nil, current: snap(free: 20 * g, total: 200 * g)).isEmpty)
        // total unbekannt (0) -> keine Warnung
        #expect(GrowthWatcher.alerts(previous: nil, current: snap(free: 0, total: 0)).isEmpty)
    }

    @Test func orderGrowthDescendingThenLowSpaceThenCleanable() {
        let g = Self.gb
        let p = snap(sizes: ["a": 10 * g, "b": 10 * g])
        let c = snap(sizes: ["a": 16 * g, "b": 30 * g], cleanable: 5 * g, free: 5 * g, total: 100 * g)
        let a = GrowthWatcher.alerts(previous: p, current: c)
        #expect(a.count == 4)
        if case .growth(let id, _, _, _) = a[0] { #expect(id == "b") } else { Issue.record("0") }
        if case .growth(let id, _, _, _) = a[1] { #expect(id == "a") } else { Issue.record("1") }
        if case .lowSpace = a[2] {} else { Issue.record("2") }
        if case .cleanable = a[3] {} else { Issue.record("3") }
    }
}
