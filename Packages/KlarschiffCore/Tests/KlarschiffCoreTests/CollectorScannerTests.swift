import Testing
import Foundation
@testable import KlarschiffCore

struct CollectorScannerTests {
    @Test func otherCachesSkipClaimedAndSystemSpecials() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/Caches/com.spotify.client/x", bytes: 1000)
        try t.file("home/Library/Caches/com.apple.bird/x", bytes: 1000)
        try t.file("home/Library/Caches/CloudKit/x", bytes: 1000)
        try t.file("home/Library/Caches/org.swift.swiftpm/x", bytes: 1000)
        let ctx = ScanContext.test(root: t.root)
        await ctx.claims.claim([ctx.homePath("Library/Caches/org.swift.swiftpm")])
        let scanner = OtherCachesScanner()
        let fs = try await scanner.scan(ctx)
        #expect(fs.count == 1)
        #expect(fs[0].id == FindingID(scannerID: "appCaches.other", key: "all"))
        #expect(fs[0].items.map(\.name) == ["com.spotify.client"])
        #expect(fs[0].risk == .safe && fs[0].method == .trash && fs[0].category == .appCaches)
        #expect(fs[0].commandPreview == ["In den Papierkorb: \(ctx.homePath("Library/Caches/com.spotify.client").path)"])
        #expect(scanner.phase == .collector)
    }

    @Test func otherCachesBlockOnItemLevelOnly() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/Caches/com.spotify.client/x", bytes: 1000)
        try t.file("home/Library/Caches/com.other.app/x", bytes: 1000)
        let ctx = ScanContext.test(root: t.root, running: ["com.spotify.client"])
        let fs = try await OtherCachesScanner().scan(ctx)
        #expect(fs.count == 1)
        #expect(fs[0].blockingApps.isEmpty)
        #expect(fs[0].isPreselected(isKept: false))
        let spotify = try #require(fs[0].items.first { $0.name == "com.spotify.client" })
        let other = try #require(fs[0].items.first { $0.name == "com.other.app" })
        #expect(spotify.blockingApp?.bundleID == "com.spotify.client")
        #expect(other.blockingApp == nil)
        #expect(spotify.watchedApp?.bundleID == "com.spotify.client")
        #expect(other.watchedApp?.bundleID == "com.other.app")
    }

    @Test func otherCachesSkipSymlinks() async throws {
        let t = try FixtureTree()
        let target = try t.dir("elsewhere")
        try t.symlink("home/Library/Caches/linked", to: target)
        let fs = try await OtherCachesScanner().scan(.test(root: t.root))
        #expect(fs.isEmpty)
    }

    @Test func appStoreCachesSkipClaimedChild() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/Containers/com.foo.app/Data/Library/Caches/keep/x", bytes: 1000)
        try t.file("home/Library/Containers/com.foo.app/Data/Library/Caches/free/x", bytes: 1000)
        try t.file("home/Library/Containers/com.bar.app/Data/Library/Caches/zzz/x", bytes: 1000)
        let ctx = ScanContext.test(root: t.root)
        await ctx.claims.claim([ctx.homePath("Library/Containers/com.foo.app/Data/Library/Caches/keep")])
        let scanner = AppStoreCachesScanner(appName: { $0 == "com.foo.app" ? "Foo" : nil })
        let fs = try await scanner.scan(ctx)
        #expect(fs.count == 1)
        #expect(fs[0].id == FindingID(scannerID: "appCaches.appStore", key: "all"))
        #expect(fs[0].items.map(\.name) == ["com.bar.app – zzz", "Foo – free"])
        #expect(fs[0].needsFullDiskAccess && fs[0].risk == .safe && fs[0].method == .trash)
        #expect(scanner.phase == .collector)
    }

    @Test func appStoreCachesNoAccessWithoutFullDiskAccess() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/Containers/com.foo.app/Data/Library/Caches/free/x", bytes: 1000)
        let fs = try await AppStoreCachesScanner(appName: { _ in nil }).scan(.test(root: t.root, hasFullDiskAccess: false))
        #expect(fs.count == 1)
        #expect(fs[0].id.key == "noAccess" && fs[0].size == nil && fs[0].items.isEmpty)
        #expect(fs[0].needsFullDiskAccess)
    }
}
