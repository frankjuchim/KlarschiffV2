import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct ActivityAggregatorTests {
    private func p(_ pid: Int32, _ name: String, path: String? = nil, uid: uid_t = 501,
                   start: UInt64 = 1, cpu: UInt64 = 0, ram: UInt64 = 1000) -> ProcessSample {
        ProcessSample(pid: pid, startTime: start, name: name, path: path, uid: uid, cpuTimeNs: cpu, residentBytes: ram)
    }
    private let sec: UInt64 = 1_000_000_000

    @Test func groupsHelpersIntoOutermostApp() {
        let app = "/Applications/Foo.app/Contents/MacOS/Foo"
        let helper = "/Applications/Foo.app/Contents/Frameworks/X.app/Contents/MacOS/Helper"
        var agg = ActivityAggregator()
        let cur = [p(1, "Foo", path: app, ram: 100), p(2, "Helper", path: helper, ram: 50), p(3, "zsh", path: "/bin/zsh")]
        let out = agg.update(previous: [], current: cur, interval: 2, apps: [])
        let foo = out.first { $0.id == "/Applications/Foo.app" }
        #expect(foo?.processCount == 2)
        #expect(foo?.residentBytes == 150)
        #expect(foo?.name == "Foo")
        #expect(foo?.appPath == "/Applications/Foo.app")
        #expect(out.contains { $0.id == "zsh" && $0.appPath == nil })
    }

    @Test func cpuPercentFromDeltasCanExceed100() {
        var agg = ActivityAggregator()
        let path = "/Applications/Foo.app/Contents/MacOS/Foo"
        let prev = [p(1, "Foo", path: path, cpu: 10 * sec), p(2, "Foo", path: path, cpu: 10 * sec)]
        let cur = [p(1, "Foo", path: path, cpu: 12 * sec), p(2, "Foo", path: path, cpu: 13 * sec)]
        let out = agg.update(previous: prev, current: cur, interval: 2, apps: [])
        #expect(abs(out[0].cpuPercent - 250) < 0.001)
    }

    @Test func pidReuseGivesNoDelta() {
        var agg = ActivityAggregator()
        let prev = [p(1, "a", start: 1, cpu: 100 * sec)]
        let cur = [p(1, "a", start: 2, cpu: 1 * sec)]
        #expect(agg.update(previous: prev, current: cur, interval: 2, apps: [])[0].cpuPercent == 0)
    }

    @Test func endedAndNewProcessesDoNotCount() {
        var agg = ActivityAggregator()
        let prev = [p(1, "gone", cpu: 5 * sec), p(2, "a", cpu: 1 * sec)]
        let cur = [p(2, "a", cpu: 2 * sec), p(3, "new", cpu: 50 * sec)]
        let out = agg.update(previous: prev, current: cur, interval: 2, apps: [])
        #expect(out.first { $0.id == "gone" } == nil)
        #expect(out.first { $0.id == "new" }?.cpuPercent == 0)
        #expect(abs((out.first { $0.id == "a" }?.cpuPercent ?? 0) - 50) < 0.001)
    }

    @Test func systemDetection() {
        var agg = ActivityAggregator()
        let cur = [p(1, "root", uid: 0), p(2, "daemon", path: "/usr/libexec/foo", uid: 501),
                   p(3, "_acct", uid: 241), p(4, "mine", path: "/Users/x/bin/mine")]
        let out = agg.update(previous: [], current: cur, interval: 2, apps: [])
        func sys(_ id: String) -> Bool? { out.first { $0.id == id }?.isSystem }
        #expect(sys("root") == true)
        #expect(sys("daemon") == true)
        #expect(sys("_acct") == true)
        #expect(sys("mine") == false)
    }

    @Test func canQuitRules() {
        var agg = ActivityAggregator()
        let cur = [
            p(1, "Foo", path: "/Applications/Foo.app/Contents/MacOS/Foo"),
            p(2, "Klarschiff 2", path: "/Applications/Klarschiff 2.app/Contents/MacOS/K"),
            p(3, "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            p(4, "Agent", path: "/Applications/Bar.app/Contents/MacOS/Agent"),
            p(5, "Safari", path: "/System/Applications/Safari.app/Contents/MacOS/Safari"),
            p(6, "rootapp", path: "/Applications/R.app/Contents/MacOS/R", uid: 0),
        ]
        let apps = [
            RunningAppInfo(pid: 1, bundleID: "com.foo", name: "Foo", bundlePath: "/Applications/Foo.app", isRegular: true),
            RunningAppInfo(pid: 2, bundleID: "de.frankjuchim.klarschiff2", name: "Klarschiff 2", bundlePath: "/Applications/Klarschiff 2.app", isRegular: true),
            RunningAppInfo(pid: 3, bundleID: "com.apple.finder", name: "Finder", bundlePath: "/System/Library/CoreServices/Finder.app", isRegular: true),
            RunningAppInfo(pid: 4, bundleID: "com.bar", name: "Bar", bundlePath: "/Applications/Bar.app", isRegular: false),
            RunningAppInfo(pid: 5, bundleID: "com.apple.Safari", name: "Safari", bundlePath: "/System/Applications/Safari.app", isRegular: true),
            RunningAppInfo(pid: 6, bundleID: "com.r", name: "R", bundlePath: "/Applications/R.app", isRegular: true),
        ]
        let out = agg.update(previous: [], current: cur, interval: 2, apps: apps)
        func e(_ id: String) -> ActivityEntry? { out.first { $0.id == id } }
        #expect(e("/Applications/Foo.app")?.canQuit == true)
        #expect(e("/Applications/Foo.app")?.bundleID == "com.foo")
        #expect(e("/Applications/Klarschiff 2.app")?.canQuit == false)
        #expect(e("/System/Library/CoreServices/Finder.app")?.canQuit == false)
        #expect(e("/Applications/Bar.app")?.canQuit == false)
        #expect(e("/System/Applications/Safari.app")?.canQuit == true)
        #expect(e("/System/Applications/Safari.app")?.isSystem == false)
        #expect(e("/Applications/R.app")?.canQuit == false)
    }

    @Test func historyCappedAt60AndPruned() {
        var agg = ActivityAggregator()
        var prev: [ProcessSample] = []
        var out: [ActivityEntry] = []
        for i in 0..<70 {
            let cur = [p(1, "a", cpu: UInt64(i) * sec)]
            out = agg.update(previous: prev, current: cur, interval: 1, apps: [])
            prev = cur
        }
        #expect(out[0].history.count == 60)
        #expect(abs(out[0].history.last! - 100) < 0.001)
        _ = agg.update(previous: prev, current: [], interval: 1, apps: [])
        out = agg.update(previous: [], current: [p(1, "a")], interval: 1, apps: [])
        #expect(out[0].history.count == 1)
    }

    @Test func top12SortedByCpuThenRamThenName() {
        var agg = ActivityAggregator()
        var prev: [ProcessSample] = [], cur: [ProcessSample] = []
        for i in 0..<15 {
            prev.append(p(Int32(i + 1), "p\(String(format: "%02d", i))", cpu: 0))
            cur.append(p(Int32(i + 1), "p\(String(format: "%02d", i))", cpu: UInt64(i % 3) * sec, ram: UInt64(i % 2) * 10))
        }
        let out = agg.update(previous: prev, current: cur, interval: 1, apps: [])
        #expect(out.count == 12)
        for (a, b) in zip(out, out.dropFirst()) {
            if a.cpuPercent == b.cpuPercent {
                if a.residentBytes == b.residentBytes { #expect(a.name < b.name) }
                else { #expect(a.residentBytes > b.residentBytes) }
            } else { #expect(a.cpuPercent > b.cpuPercent) }
        }
    }

    @Test func liveSamplerPlausible() {
        let start = Date()
        let procs = LiveProcessSampler().sample()
        let dur = Date().timeIntervalSince(start)
        #expect(procs.count >= 50)
        #expect(procs.contains { $0.pid == getpid() })
        #expect(dur < 0.2)
        let me = procs.first { $0.pid == getpid() }
        #expect((me?.residentBytes ?? 0) > 0)
        #expect((me?.startTime ?? 0) > 0)
    }
}
