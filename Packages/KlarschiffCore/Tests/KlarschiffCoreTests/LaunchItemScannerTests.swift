import Foundation
import Testing
@testable import KlarschiffCore

@Suite struct LaunchItemScannerTests {
    let uid: uid_t = 501

    @discardableResult
    func plist(_ t: FixtureTree, _ rel: String, _ dict: [String: Any]) throws -> URL {
        let u = t.root.appending(path: rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: u)
        return u
    }

    func scan(_ t: FixtureTree, runner: FakeCommandRunner = FakeCommandRunner(),
              installed: @escaping @Sendable (String) -> URL? = { _ in nil }) async -> [LaunchItem] {
        await LaunchItemScanner(isInstalled: installed).scan(.test(root: t.root, runner: runner), uid: uid)
    }

    func item(_ label: String, _ items: [LaunchItem]) -> LaunchItem? { items.first { $0.label == label } }

    @Test func programPresentAndMissing() async throws {
        let t = try FixtureTree()
        try t.file("usr/local/bin/tool", bytes: 3)
        try plist(t, "home/Library/LaunchAgents/com.x.present.plist",
                  ["Label": "com.x.present", "ProgramArguments": ["/usr/local/bin/tool"]])
        try plist(t, "home/Library/LaunchAgents/com.x.gone.plist",
                  ["Label": "com.x.gone", "ProgramArguments": ["/opt/gone/tool"]])
        let items = await scan(t)
        #expect(item("com.x.gone", items)?.isOrphaned == true)
        #expect(item("com.x.gone", items)?.explanation == "Das Programm fehlt: /opt/gone/tool. Es wurde vermutlich deinstalliert.")
        #expect(item("com.x.present", items)?.isOrphaned == false)
    }

    @Test func programRelativeToRootExists() async throws {
        let t = try FixtureTree()
        try t.file("opt/tool/bin", bytes: 3)
        try plist(t, "home/Library/LaunchAgents/com.x.ok.plist", ["Label": "com.x.ok", "Program": "/opt/tool/bin"])
        let items = await scan(t)
        #expect(item("com.x.ok", items)?.isOrphaned == false)
    }

    @Test func appInstalledViaPath() async throws {
        let t = try FixtureTree()
        try t.file("Applications/Elgato Stream Deck.app/Contents/MacOS/Stream Deck", bytes: 3)
        try plist(t, "home/Library/LaunchAgents/com.elgato.StreamDeck.plist", [
            "Label": "com.elgato.StreamDeck",
            "ProgramArguments": ["/Applications/Elgato Stream Deck.app/Contents/MacOS/Stream Deck", "--runinbk"],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false]])
        try plist(t, "home/Library/LaunchAgents/com.y.deleted.plist", [
            "Label": "com.y.deleted", "ProgramArguments": ["/Applications/Deleted.app/Contents/MacOS/Deleted"]])
        let items = await scan(t)
        let sd = try #require(item("com.elgato.StreamDeck", items))
        #expect(!sd.isOrphaned)
        #expect(sd.appURL?.lastPathComponent == "Elgato Stream Deck.app")
        #expect(sd.displayName == "Elgato Stream Deck")
        #expect(sd.explanation == "Gehört zu Elgato Stream Deck.")
        #expect(sd.startKind == .atLogin)
        #expect(item("com.y.deleted", items)?.isOrphaned == true)
    }

    @Test func bundleProgramWithAssociatedBundleIDs() async throws {
        let t = try FixtureTree()
        let app = t.root.appending(path: "Applications/Helper.app")
        try plist(t, "Library/LaunchAgents/com.h.inst.plist", [
            "Label": "com.h.inst", "BundleProgram": "Contents/MacOS/helper",
            "AssociatedBundleIdentifiers": ["com.h.app"]])
        try plist(t, "Library/LaunchAgents/com.h.gone.plist", [
            "Label": "com.h.gone", "BundleProgram": "Contents/MacOS/helper",
            "AssociatedBundleIdentifiers": ["com.h.nope"]])
        let items = await scan(t, installed: { $0 == "com.h.app" ? app : nil })
        let inst = try #require(item("com.h.inst", items))
        #expect(!inst.isOrphaned)
        #expect(inst.appURL == app)
        #expect(inst.scope == .allUsers)
        let gone = try #require(item("com.h.gone", items))
        #expect(gone.isOrphaned)
        #expect(gone.associatedBundleIDs == ["com.h.nope"])
    }

    @Test func brokenPlistIsNotOrphaned() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/LaunchAgents/com.broken.thing.plist", bytes: 10)
        let items = await scan(t)
        let b = try #require(item("com.broken.thing", items))
        #expect(!b.isOrphaned)
        #expect(b.explanation.contains("konnte nicht gelesen werden"))
    }

    @Test func appleSkippedCaseInsensitive() async throws {
        let t = try FixtureTree()
        try plist(t, "Library/LaunchDaemons/com.apple.foo.plist", ["Label": "com.apple.foo", "Program": "/nope"])
        try plist(t, "Library/LaunchDaemons/COM.Apple.Bar.plist", ["Label": "COM.Apple.Bar", "Program": "/nope"])
        try plist(t, "Library/LaunchDaemons/other.plist", ["Label": "Com.Apple.Baz", "Program": "/nope"])
        let items = await scan(t)
        #expect(items.isEmpty)
    }

    @Test func symlinkPlistSkipped() async throws {
        let t = try FixtureTree()
        let real = try plist(t, "elsewhere/com.s.link.plist", ["Label": "com.s.link", "Program": "/nope"])
        try t.symlink("home/Library/LaunchAgents/com.s.link.plist", to: real)
        let items = await scan(t)
        #expect(items.isEmpty)
    }

    @Test func ownAgentNeverOrphaned() async throws {
        let t = try FixtureTree()
        try plist(t, "home/Library/LaunchAgents/de.frankjuchim.klarschiff2.check.weekly.plist", [
            "Label": "de.frankjuchim.klarschiff2.check.weekly", "ProgramArguments": ["/Applications/Klarschiff 2.app/Contents/MacOS/x"],
            "StartCalendarInterval": ["Weekday": 0, "Hour": 10]])
        let items = await scan(t)
        let own = try #require(items.first)
        #expect(own.isOwnAgent)
        #expect(!own.isOrphaned)
        #expect(own.startKind == .scheduled)
        #expect(own.displayName == "Klarschiff 2 – automatischer Check")
    }

    @Test func permissionErrorIsNotOrphaned() async throws {
        let t = try FixtureTree()
        let locked = try t.dir("opt/locked")
        try t.file("opt/locked/tool", bytes: 3)
        try plist(t, "home/Library/LaunchAgents/com.p.locked.plist", ["Label": "com.p.locked", "Program": "/opt/locked/tool"])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let items = await scan(t)
        #expect(item("com.p.locked", items)?.isOrphaned == false)
    }

    @Test func unmountedVolumeIsNotOrphaned() async throws {
        let t = try FixtureTree()
        try plist(t, "home/Library/LaunchAgents/com.v.off.plist", ["Label": "com.v.off", "Program": "/Volumes/Ext/tool"])
        try plist(t, "home/Library/LaunchAgents/com.v.on.plist", ["Label": "com.v.on", "Program": "/Volumes/Mounted/tool"])
        try t.dir("Volumes/Mounted")
        let items = await scan(t)
        let off = try #require(item("com.v.off", items))
        #expect(!off.isOrphaned)
        #expect(off.explanation.contains("nicht verbundenen Laufwerk"))
        #expect(item("com.v.on", items)?.isOrphaned == true)
    }

    @Test func renamedAppWithInstalledBundleIDIsNotOrphaned() async throws {
        let t = try FixtureTree()
        let app = t.root.appending(path: "Applications/New Name.app")
        try plist(t, "home/Library/LaunchAgents/com.n.helper.plist", [
            "Label": "com.n.helper", "ProgramArguments": ["/Applications/Old Name.app/Contents/MacOS/h"],
            "AssociatedBundleIdentifiers": ["com.n.app"]])
        let items = await scan(t, installed: { $0 == "com.n.app" ? app : nil })
        let i = try #require(item("com.n.helper", items))
        #expect(!i.isOrphaned)
        #expect(i.explanation == "Das Programm liegt nicht mehr am erwarteten Ort, die App ist aber installiert.")
    }

    @Test func systemShellAndRelativePathsNotOrphaned() async throws {
        let t = try FixtureTree()
        try plist(t, "home/Library/LaunchAgents/com.s.sh.plist", [
            "Label": "com.s.sh", "ProgramArguments": ["/bin/sh", "-c", "echo /nonexistent"]])
        try plist(t, "home/Library/LaunchAgents/com.s.rel.plist", ["Label": "com.s.rel", "ProgramArguments": ["python3"]])
        try plist(t, "home/Library/LaunchAgents/com.s.tilde.plist", ["Label": "com.s.tilde", "Program": "~/bin/tool"])
        let items = await scan(t)
        #expect(items.count == 3)
        #expect(items.allSatisfy { !$0.isOrphaned })
    }

    @Test func duplicateLabelsGetUniqueIDs() async throws {
        let t = try FixtureTree()
        try plist(t, "home/Library/LaunchAgents/a.plist", ["Label": "com.d.same", "Program": "/nope"])
        try plist(t, "home/Library/LaunchAgents/b.plist", ["Label": "com.d.same", "Program": "/nope"])
        let items = await scan(t)
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
    }

    @Test func bundleProgramWithoutIDsIsNotOrphaned() async throws {
        let t = try FixtureTree()
        try plist(t, "home/Library/LaunchAgents/com.b.none.plist", ["Label": "com.b.none", "BundleProgram": "Contents/x"])
        let items = await scan(t)
        #expect(item("com.b.none", items)?.isOrphaned == false)
    }

    @Test func startKinds() {
        #expect(LaunchItemScanner.startKind(["RunAtLoad": true]) == .atLogin)
        #expect(LaunchItemScanner.startKind(["KeepAlive": true]) == .atLogin)
        #expect(LaunchItemScanner.startKind(["KeepAlive": ["SuccessfulExit": false]]) == .atLogin)
        #expect(LaunchItemScanner.startKind(["KeepAlive": false]) == .onDemand)
        #expect(LaunchItemScanner.startKind(["StartInterval": 60]) == .scheduled)
        #expect(LaunchItemScanner.startKind(["StartCalendarInterval": ["Hour": 1]]) == .scheduled)
        #expect(LaunchItemScanner.startKind([:]) == .onDemand)
        #expect(StartKind.atLogin.title == "startet bei der Anmeldung")
        #expect(LaunchScope.allUsers.title == "Alle Benutzer")
    }

    @Test func displayNameFromLabel() {
        #expect(LaunchItemScanner.prettyName(fromLabel: "com.elgato.StreamDeck") == "Stream Deck")
        #expect(LaunchItemScanner.prettyName(fromLabel: "single") == "Single")
    }

    @Test func runningStateViaLaunchctl() async throws {
        let t = try FixtureTree()
        try plist(t, "home/Library/LaunchAgents/com.r.running.plist", ["Label": "com.r.running", "Program": "/x"])
        try plist(t, "home/Library/LaunchAgents/com.r.idle.plist", ["Label": "com.r.idle", "Program": "/x"])
        try plist(t, "Library/LaunchDaemons/com.d.daemon.plist", ["Label": "com.d.daemon", "Program": "/x"])
        let runner = FakeCommandRunner()
        runner.stub("/bin/launchctl", ["print", "gui/501/com.r.running"],
                    result: CommandResult(exitCode: 0, stdout: "com.r.running = {\n\tstate = running\n}", stderr: ""))
        runner.stub("/bin/launchctl", ["print", "gui/501/com.r.idle"],
                    result: CommandResult(exitCode: 113, stdout: "",
                                          stderr: "Could not find service \"com.r.idle\" in domain for user gui: 501"))
        runner.stub("/bin/launchctl", ["print", "system/com.d.daemon"],
                    result: CommandResult(exitCode: 0, stdout: "state = running", stderr: ""))
        let items = await scan(t, runner: runner)
        #expect(item("com.r.running", items)?.isRunning == true)
        #expect(item("com.r.idle", items)?.isRunning == false)
        #expect(item("com.d.daemon", items)?.isRunning == true)
        #expect(runner.calls.contains { $0.1 == ["print", "system/com.d.daemon"] })
        #expect(!runner.calls.contains { $0.1 == ["print", "gui/501/com.d.daemon"] })
    }

    @Test func loadedButWaitingIsNotRunning() async throws {
        let t = try FixtureTree()
        try plist(t, "home/Library/LaunchAgents/com.w.wait.plist", ["Label": "com.w.wait", "Program": "/x"])
        let runner = FakeCommandRunner()
        runner.stub("/bin/launchctl", ["print", "gui/501/com.w.wait"],
                    result: CommandResult(exitCode: 0, stdout: "state = not running", stderr: ""))
        let items = await scan(t, runner: runner)
        #expect(item("com.w.wait", items)?.isRunning == false)
    }

    @Test func manyItemsAllScanned() async throws {
        let t = try FixtureTree()
        for i in 0..<30 { try plist(t, "home/Library/LaunchAgents/com.m.n\(i).plist", ["Label": "com.m.n\(i)", "Program": "/x"]) }
        let runner = FakeCommandRunner()
        let items = await scan(t, runner: runner)
        #expect(items.count == 30)
        #expect(runner.calls.count == 30)
    }
}
