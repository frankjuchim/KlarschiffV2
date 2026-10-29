import Testing
import Foundation
@testable import KlarschiffCore

private func makeApp(_ t: FixtureTree, _ path: String, bundleID: String, modifiedDaysAgo: Int = 0) throws {
    try t.file("\(path)/Contents/MacOS/bin", bytes: 500)
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
    try data.write(to: t.root.appending(path: "\(path)/Contents/Info.plist"))
    try t.setModified(path, daysAgo: modifiedDaysAgo)
}

struct AppScannerTests {
    @Test func unusedAppsSkipApple() async throws {
        let t = try FixtureTree()
        try makeApp(t, "Applications/Old.app", bundleID: "com.foo.old")
        try makeApp(t, "Applications/Fresh.app", bundleID: "com.foo.fresh")
        try makeApp(t, "Applications/Safari.app", bundleID: "com.apple.Safari")
        try makeApp(t, "Applications/Klarschiff.app", bundleID: "de.frankjuchim.klarschiff2")
        let now = Date()
        let scanner = UnusedAppsScanner(lastUsed: { url in
            switch url.lastPathComponent {
            case "Old.app", "Safari.app", "Klarschiff.app": now.addingTimeInterval(-400 * 86_400)
            default: now.addingTimeInterval(-10 * 86_400)
            }
        })
        let fs = try await scanner.scan(.test(root: t.root, now: now))
        #expect(fs.count == 1)
        #expect(fs[0].items.map(\.name) == ["Old.app"])
        #expect(fs[0].items[0].detail?.hasPrefix("zuletzt geöffnet am ") == true)
        #expect(fs[0].method == .trash && fs[0].risk == .review)
        #expect(fs[0].summary.contains("Entwickler"))
    }

    @Test func neverOpenedUsesModificationDate() async throws {
        let t = try FixtureTree()
        try makeApp(t, "Applications/Stale.app", bundleID: "com.foo.stale", modifiedDaysAgo: 300)
        try makeApp(t, "Applications/New.app", bundleID: "com.foo.new", modifiedDaysAgo: 3)
        let fs = try await UnusedAppsScanner(lastUsed: { _ in nil }).scan(.test(root: t.root))
        #expect(fs.count == 1)
        #expect(fs[0].items.map(\.name) == ["Stale.app"])
        #expect(fs[0].items[0].detail == "nie geöffnet")
    }

    @Test func leftoversOnlyUninstalledReverseDNS() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/Containers/com.foo.bar/Data/x", bytes: 20_000_000)
        try t.file("home/Library/Caches/com.apple.x/x", bytes: 20_000_000)
        try t.file("home/Library/Application Support/Google/x", bytes: 20_000_000)
        try t.file("home/Library/Caches/com.installed.app/x", bytes: 20_000_000)
        try t.file("home/Library/Caches/com.tiny.thing/x", bytes: 1000)
        try t.file("home/Library/Application Support/com.claimed.app/x", bytes: 20_000_000)
        let ctx = ScanContext.test(root: t.root)
        await ctx.claims.claim([ctx.homePath("Library/Application Support/com.claimed.app")])
        let scanner = LeftoverAppDataScanner(isInstalled: { $0 == "com.installed.app" })
        let fs = try await scanner.scan(ctx)
        #expect(fs.count == 1)
        #expect(fs[0].items.count == 1)
        #expect(fs[0].items[0].name == "com.foo.bar (Containers)")
        #expect(fs[0].method == .trash && fs[0].risk == .review)
        #expect(scanner.phase == .collector)
    }

    @Test func leftoversSumAcrossLocations() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/Containers/com.foo.bar/x", bytes: 6_000_000)
        try t.file("home/Library/Caches/com.foo.bar/x", bytes: 6_000_000)
        let fs = try await LeftoverAppDataScanner(isInstalled: { _ in false }).scan(.test(root: t.root))
        #expect(fs.count == 1 && fs[0].items.count == 2)
        #expect(fs[0].items.map(\.name) == ["com.foo.bar (Caches)", "com.foo.bar (Containers)"])
    }

    @Test func extraXcodeExcludesActive() async throws {
        let t = try FixtureTree()
        try t.file("Applications/Xcode.app/Contents/a", bytes: 1000)
        try t.file("Applications/Xcode-beta.app/Contents/a", bytes: 1000)
        try t.file("Applications/Other.app/Contents/a", bytes: 1000)
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/xcode-select", ["-p"], result: CommandResult(exitCode: 0, stdout: "/Applications/Xcode.app/Contents/Developer\n", stderr: ""))
        let fs = try await ExtraXcodeScanner().scan(.test(root: t.root, runner: runner))
        #expect(fs.count == 1)
        #expect(fs[0].title == "Xcode-beta (zusätzliche Version)")
        #expect(fs[0].method == .trash && fs[0].risk == .review)
        #expect(fs[0].items[0].url == t.root.appending(path: "Applications/Xcode-beta.app"))
    }

    @Test func extraXcodeWithoutSelectListsAll() async throws {
        let t = try FixtureTree()
        try t.file("Applications/Xcode.app/Contents/a", bytes: 1000)
        let fs = try await ExtraXcodeScanner().scan(.test(root: t.root))
        #expect(fs.count == 1)
    }

    @Test func registeredInCatalog() {
        let ids = Catalog.allScanners().map(\.id)
        #expect(["apps.unused", "apps.leftovers", "xcode.extraVersions"].allSatisfy(ids.contains))
    }
}
