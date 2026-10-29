import Testing
import Foundation
@testable import KlarschiffCore

private func finding(_ scanner: String, key: String = "k", cat: KlarschiffCore.Category = .appCaches,
                     size: Int64? = 10, risk: Risk = .safe) -> Finding {
    Finding(id: FindingID(scannerID: scanner, key: key), category: cat, title: "T-\(key)", summary: "",
            risk: risk, method: .trash, items: [FindingItem(id: "/x/\(scanner)/\(key)", url: URL(filePath: "/x/\(scanner)/\(key)"), name: key, size: size)],
            size: size, blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)
}

private struct Stub: KlarschiffCore.Scanner {
    let id: String
    let findings: [Finding]
    func scan(_ ctx: ScanContext) async throws -> [Finding] { findings }
}

private let gb: Int64 = 1_000_000_000

private func makeRunner(_ t: FixtureTree, _ findings: [Finding], keep: [FindingID] = [],
                        roots: [String: (title: String, size: Int64, isLowerBound: Bool)] = [:],
                        space: DiskSpace? = DiskSpace(free: 500 * gb, total: 1000 * gb),
                        scanners: [any KlarschiffCore.Scanner]? = nil,
                        historyFile: URL? = nil,
                        orphans: [String]? = nil) async throws -> (CheckRunner, CheckHistory) {
    let engine = ScanEngine(scanners: scanners ?? [Stub(id: findings.first?.id.scannerID ?? "x", findings: findings)])
    let kl = KeepList(fileURL: t.root.appending(path: "keep.json"))
    for k in keep { try await kl.add(k) }
    let h = CheckHistory(fileURL: historyFile ?? t.root.appending(path: "h.json"))
    let diskSpace: CheckRunner.DiskSpaceProvider = {
        guard let space else { throw CocoaError(.fileReadUnknown) }
        return space
    }
    if let orphans {
        return (CheckRunner(engine: engine, keepList: kl, history: h, measureSystemRoots: { _ in roots },
                            diskSpace: diskSpace, orphanedServices: { _ in orphans }), h)
    }
    return (CheckRunner(engine: engine, keepList: kl, history: h,
                        measureSystemRoots: { _ in roots }, diskSpace: diskSpace), h)
}

@Suite struct CheckRunnerTests {
    @Test func runBuildsSnapshotWithoutRemovers() async throws {
        let t = try FixtureTree()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (r, h) = try await makeRunner(t, [finding("appCaches.x", key: "a", size: 3 * gb), finding("xcode.dd", key: "b", cat: .xcode, size: 2 * gb)],
                                          roots: ["apps": (title: "Systemprogramme", size: 7 * gb, isLowerBound: false)])
        let s = await r.run(.test(root: t.root, now: now))
        #expect(s.date == now)
        #expect(s.cleanableTotal == 5 * gb)
        #expect(s.freeBytes == 500 * gb && s.totalBytes == 1000 * gb)
        #expect(s.sizes["appCaches.x/a"] == 3 * gb)
        #expect(s.sizes["systemdata.apps"] == 7 * gb)
        #expect(s.titles["appCaches.x/a"] == "T-a")
        #expect(s.titles["systemdata.apps"] == "Systemprogramme")
        #expect(Set(s.titles.keys) == Set(s.sizes.keys))
        #expect(s.alerts == [.cleanable(total: 5 * gb)])
        #expect(await h.latest() == s)
    }

    @Test func keptAndHintsExcluded() async throws {
        let t = try FixtureTree()
        let kept = finding("appCaches.x", key: "kept", size: 4 * gb)
        let (r, _) = try await makeRunner(t, [
            kept, finding("appCaches.x", key: "hint", size: 6 * gb, risk: .hintOnly),
            finding("sysdata.s", key: "sd", cat: .systemData, size: 8 * gb),
            finding("appCaches.x", key: "ok", size: 1 * gb)], keep: [kept.id])
        let s = await r.run(.test(root: t.root))
        #expect(s.cleanableTotal == 1 * gb)
    }

    @Test func alertsAgainstPreviousHistory() async throws {
        let t = try FixtureTree()
        let (r, h) = try await makeRunner(t, [finding("xcode.dd", key: "a", cat: .xcode, size: 40 * gb)])
        try await h.append(CheckSnapshot(date: Date(timeIntervalSince1970: 1_000), cleanableTotal: 0, freeBytes: 500 * gb,
                                         totalBytes: 1000 * gb, sizes: ["xcode.dd/a": 2 * gb], titles: [:], alerts: []))
        let s = await r.run(.test(root: t.root))
        #expect(s.alerts.first == .growth(id: "xcode.dd/a", title: "T-a", from: 2 * gb, to: 40 * gb))
        #expect(await h.all().count == 2)
    }

    @Test func keptAndSizelessNotCompared() async throws {
        let t = try FixtureTree()
        let kept = finding("appCaches.x", key: "kept", size: 40 * gb)
        let (r, h) = try await makeRunner(t, [kept, finding("appCaches.x", key: "nil", size: nil)], keep: [kept.id])
        try await h.append(CheckSnapshot(date: Date(timeIntervalSince1970: 1_000), cleanableTotal: 0, freeBytes: 500 * gb,
                                         totalBytes: 1000 * gb, sizes: ["appCaches.x/kept": 1 * gb], titles: [:], alerts: []))
        let s = await r.run(.test(root: t.root))
        #expect(s.sizes["appCaches.x/kept"] == nil)
        #expect(s.sizes["appCaches.x/nil"] == nil)
        #expect(!s.alerts.contains { if case .growth = $0 { true } else { false } })
    }

    @Test func lowerBoundRootLaterCompleteNoAlert() async throws {
        let t = try FixtureTree()
        let file = t.root.appending(path: "h.json")
        let (r1, _) = try await makeRunner(t, [], roots: ["library": (title: "Bibliothek", size: 1 * gb, isLowerBound: true)],
                                           historyFile: file)
        let s1 = await r1.run(.test(root: t.root, now: Date(timeIntervalSince1970: 1_000)))
        #expect(s1.lowerBoundIDs == ["systemdata.library"])
        let (r2, _) = try await makeRunner(t, [], roots: ["library": (title: "Bibliothek", size: 30 * gb, isLowerBound: false)],
                                           historyFile: file)
        let s2 = await r2.run(.test(root: t.root, now: Date(timeIntervalSince1970: 2_000)))
        #expect(s2.alerts.isEmpty)
    }

    @Test func failedScannerRecordedAsUnknown() async throws {
        struct Failing: KlarschiffCore.Scanner {
            let id = "broken.s"
            func scan(_ ctx: ScanContext) async throws -> [Finding] { throw CocoaError(.fileReadUnknown) }
        }
        let t = try FixtureTree()
        let (r, _) = try await makeRunner(t, [], scanners: [Failing()])
        let s = await r.run(.test(root: t.root))
        #expect(s.lowerBoundIDs.contains("broken.s"))
        #expect(s.sizes.isEmpty)
    }

    @Test func diskSpaceFailureNotAppended() async throws {
        let t = try FixtureTree()
        let (r, h) = try await makeRunner(t, [finding("appCaches.x", size: 2 * gb)], space: nil)
        let s = await r.run(.test(root: t.root))
        #expect(s.cleanableTotal == 2 * gb)
        #expect(s.totalBytes == 0)
        #expect(await h.all().isEmpty)
    }

    @Test func historyWriteFailureStillReturnsSnapshot() async throws {
        let t = try FixtureTree()
        let blocker = try t.file("blocker", bytes: 1)
        let (r, _) = try await makeRunner(t, [finding("appCaches.x", size: 2 * gb)],
                                          historyFile: blocker.appending(path: "sub/h.json"))
        let s = await r.run(.test(root: t.root))
        #expect(s.cleanableTotal == 2 * gb)
    }

    @Test func notificationPriorityAndTab() {
        func snap(_ alerts: [CheckAlert]) -> CheckSnapshot {
            CheckSnapshot(date: Date(), cleanableTotal: 0, freeBytes: 0, totalBytes: 0, sizes: [:], titles: [:], alerts: alerts)
        }
        let g = CheckAlert.growth(id: "xcode.dd/a", title: "Instruments-Caches", from: 2 * gb, to: 40 * gb)
        let both = CheckNotificationText.make(snap([g, .lowSpace(free: 18 * gb, total: 1000 * gb), .cleanable(total: 52 * gb)]))
        #expect(both == CheckNotification(title: "Klarschiff 2",
            body: "Instruments-Caches +\(ByteFormat.string(38 * gb)) seit dem letzten Check · \(ByteFormat.string(52 * gb)) aufräumbar",
            tab: .developer))
        #expect(CheckNotificationText.make(snap([.lowSpace(free: 18 * gb, total: 1000 * gb), .cleanable(total: 52 * gb)]))
                == CheckNotification(title: "Klarschiff 2", body: "Nur noch \(ByteFormat.string(18 * gb)) frei", tab: .storage))
        #expect(CheckNotificationText.make(snap([.cleanable(total: 52 * gb)]))
                == CheckNotification(title: "Klarschiff 2", body: "\(ByteFormat.string(52 * gb)) aufräumbar", tab: .storage))
        #expect(CheckNotificationText.make(snap([.growth(id: "systemdata.assets", title: "A", from: 0, to: 6 * gb)]))?.tab == .systemData)
        #expect(CheckNotificationText.make(snap([.growth(id: "unbekannt/k", title: "A", from: 0, to: 6 * gb)]))?.tab == .storage)
    }

    @Test func orphanedServicesRecordedAndAlertedWhenNew() async throws {
        let t = try FixtureTree()
        let (r, h) = try await makeRunner(t, [], orphans: ["com.b.agent", "com.a.agent", "com.a.agent"])
        try await h.append(CheckSnapshot(date: Date(timeIntervalSince1970: 1_000), cleanableTotal: 0, freeBytes: 500 * gb,
                                         totalBytes: 1000 * gb, sizes: [:], titles: [:], alerts: [],
                                         orphanedServiceLabels: ["com.a.agent"]))
        let s = await r.run(.test(root: t.root))
        #expect(s.orphanedServiceLabels == ["com.a.agent", "com.b.agent"])
        #expect(s.alerts == [.orphanedServices(labels: ["com.b.agent"])])
    }

    @Test func orphanedServicesDefaultEmpty() async throws {
        let t = try FixtureTree()
        let (r, _) = try await makeRunner(t, [])
        let s = await r.run(.test(root: t.root))
        #expect(s.orphanedServiceLabels == [])
    }

    @Test func orphanedServicesNotificationText() {
        func snap(_ alerts: [CheckAlert]) -> CheckSnapshot {
            CheckSnapshot(date: Date(), cleanableTotal: 0, freeBytes: 0, totalBytes: 0, sizes: [:], titles: [:], alerts: alerts)
        }
        let low = CheckAlert.lowSpace(free: 18 * gb, total: 1000 * gb)
        #expect(CheckNotificationText.make(snap([.orphanedServices(labels: ["a", "b"]), low, .cleanable(total: 52 * gb)]))
                == CheckNotification(title: "Klarschiff 2", body: "2 neue verwaiste Hintergrunddienste", tab: .services))
        #expect(CheckNotificationText.make(snap([.orphanedServices(labels: ["a"])]))
                == CheckNotification(title: "Klarschiff 2", body: "1 neuer verwaister Hintergrunddienst", tab: .services))
        // Wachstum hat Vorrang.
        let g = CheckAlert.growth(id: "xcode.dd/a", title: "X", from: 0, to: 6 * gb)
        #expect(CheckNotificationText.make(snap([g, .orphanedServices(labels: ["a"])]))?.tab == .developer)
        // Leere Liste zählt nicht.
        #expect(CheckNotificationText.make(snap([.orphanedServices(labels: [])])) == nil)
    }

    @Test func noAlertsNoNotification() {
        #expect(CheckNotificationText.make(CheckSnapshot(date: Date(), cleanableTotal: 0, freeBytes: 0, totalBytes: 0,
                                                         sizes: [:], titles: [:], alerts: [])) == nil)
    }

    @Test func measureUserDataFalseSkipsHome() async throws {
        let t = try FixtureTree()
        try t.file("home/big.bin", bytes: 5000)
        let ctx = ScanContext.test(root: t.root)
        let off = await SystemDataScanner(cleanupScanners: [], measureUserData: false).scan(ctx) { _, _ in }
        #expect(off.userData == 0)
        #expect(!off.userDataIsLowerBound)
        #expect(!off.failures.contains { $0.scannerID.hasPrefix("systemdata.userdata") })
        let on = await SystemDataScanner(cleanupScanners: []).scan(ctx) { _, _ in }
        #expect(on.userData > 0)
    }
}
