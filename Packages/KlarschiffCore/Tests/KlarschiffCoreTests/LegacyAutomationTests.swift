import Foundation
import Testing
@testable import KlarschiffCore

@Suite struct LegacyAutomationTests {
    let cleanupLabel = "com.frankjuchim.cleanup"
    let checkLabel = "de.bodendiek.klarschiff.check"
    let launchctl = "/bin/launchctl"

    func fullFixture() throws -> FixtureTree {
        let t = try FixtureTree()
        try t.file("home/Library/LaunchAgents/com.frankjuchim.cleanup.plist", bytes: 10)
        try t.file("home/Library/LaunchAgents/de.bodendiek.klarschiff.check.plist", bytes: 10)
        try t.file("home/cleanup.sh", bytes: 10)
        try t.file("home/cleanup.log", bytes: 10)
        try t.file("home/cleanup_error.log", bytes: 10)
        try t.dir("Applications/Klarschiff.app")
        return t
    }

    @Test func detectsAllSixInFixture() async throws {
        let t = try fullFixture()
        let ctx = ScanContext.test(root: t.root)
        let items = await LegacyAutomation.detect(ctx, uid: 501)
        #expect(items.count == 6)
        #expect(items.filter { if case .agent = $0.kind { true } else { false } }.count == 2)
        #expect(items.contains { if case .script = $0.kind { true } else { false } })
        #expect(items.contains { if case .emptyApp = $0.kind { true } else { false } })
        #expect(items.filter { if case .log = $0.kind { true } else { false } }.count == 2)
        let script = items.first { if case .script = $0.kind { true } else { false } }!
        #expect(script.explanation.contains("leert jeden Monatsersten automatisch deine Caches"))
        let app = items.first { if case .emptyApp = $0.kind { true } else { false } }!
        #expect(app.explanation.contains("zeigt auf eine App, die es nicht mehr gibt"))
        #expect(items.allSatisfy { !$0.isLoaded })
        #expect(occurrences("leert jeden Monatsersten", in: items) == 1)
        #expect(occurrences("zeigt auf eine App, die es nicht mehr gibt", in: items) == 1)
    }

    func occurrences(_ needle: String, in items: [LegacyItem]) -> Int {
        items.reduce(0) { $0 + $1.explanation.components(separatedBy: needle).count - 1 }
    }

    func agent(_ label: String, _ items: [LegacyItem]) -> LegacyItem? {
        items.first { if case .agent(let l) = $0.kind { l == label } else { false } }
    }

    @Test func sentencesOnAgentsWhenNoScriptAndNoApp() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/LaunchAgents/com.frankjuchim.cleanup.plist", bytes: 10)
        try t.file("home/Library/LaunchAgents/de.bodendiek.klarschiff.check.plist", bytes: 10)
        let items = await LegacyAutomation.detect(ScanContext.test(root: t.root), uid: 501)
        #expect(agent(cleanupLabel, items)?.explanation.contains("leert jeden Monatsersten automatisch deine Caches") == true)
        #expect(agent(checkLabel, items)?.explanation.hasSuffix("Der alte Klarschiff-Check zeigt auf eine App, die es nicht mehr gibt.") == true)
        #expect(occurrences("leert jeden Monatsersten", in: items) == 1)
        #expect(occurrences("zeigt auf eine App", in: items) == 1)
    }

    @Test func oldAppStillInstalledChangesCheckSentence() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/LaunchAgents/de.bodendiek.klarschiff.check.plist", bytes: 10)
        try t.file("Applications/Klarschiff.app/Contents/MacOS/Klarschiff", bytes: 10)
        let items = await LegacyAutomation.detect(ScanContext.test(root: t.root), uid: 501)
        #expect(items.count == 1)
        let check = try #require(agent(checkLabel, items))
        #expect(check.explanation == "Startet sonntags einen Check. Der Check von Klarschiff 1 startet weiterhin jeden Sonntag. Klarschiff 2 übernimmt diese Aufgabe – der alte Check wird nicht mehr gebraucht.")
        #expect(!check.explanation.contains("nicht mehr gibt"))
    }

    @Test func detectsPartial() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/LaunchAgents/com.frankjuchim.cleanup.plist", bytes: 10)
        try t.file("home/cleanup.sh", bytes: 10)
        let items = await LegacyAutomation.detect(ScanContext.test(root: t.root), uid: 501)
        #expect(items.count == 2)
    }

    @Test func appWithExecutableIsNotLegacy() async throws {
        let t = try FixtureTree()
        try t.file("Applications/Klarschiff.app/Contents/MacOS/Klarschiff", bytes: 10)
        let items = await LegacyAutomation.detect(ScanContext.test(root: t.root), uid: 501)
        #expect(items.isEmpty)
    }

    func legacyApp(_ build: (FixtureTree) throws -> Void) async throws -> Int {
        let t = try FixtureTree()
        try build(t)
        let items = await LegacyAutomation.detect(ScanContext.test(root: t.root), uid: 501)
        return items.filter { if case .emptyApp = $0.kind { true } else { false } }.count
    }

    @Test func appEmptinessRuling() async throws {
        #expect(try await legacyApp { try $0.dir("Applications/Klarschiff.app") } == 1)
        #expect(try await legacyApp { try $0.dir("Applications/Klarschiff.app/Contents/MacOS") } == 1)
        #expect(try await legacyApp { try $0.file("Applications/Klarschiff.app/.DS_Store", bytes: 3) } == 1)
        #expect(try await legacyApp { try $0.file("Applications/Klarschiff.app/Contents/MacOS/OtherName", bytes: 3) } == 0)
        #expect(try await legacyApp { try $0.file("Applications/Klarschiff.app/Contents/Info.plist", bytes: 3) } == 0)
        #expect(try await legacyApp {
            let target = try $0.file("elsewhere", bytes: 1)
            try $0.dir("Applications/Klarschiff.app")
            try $0.symlink("Applications/Klarschiff.app/link", to: target)
        } == 0)
    }

    @Test func foreignURLDroppedFromFinding() async throws {
        let t = try fullFixture()
        let ctx = ScanContext.test(root: t.root)
        var items = await LegacyAutomation.detect(ctx, uid: 501)
        items.append(LegacyItem(id: "x", kind: .log, url: ctx.homePath("Documents/wichtig.txt"), title: "x", explanation: "", isLoaded: false))
        let f = LegacyAutomation.removalFinding(items, ctx: ctx, includeExtras: true)
        #expect(f.items.count == 6)
        #expect(!f.items.contains { $0.url?.lastPathComponent == "wichtig.txt" })
    }

    @Test func scheduleTimeReadFromPlist() async throws {
        let t = try FixtureTree()
        let url = try t.file("home/Library/LaunchAgents/com.frankjuchim.cleanup.plist", bytes: 0)
        let plist: [String: Any] = ["StartCalendarInterval": ["Day": 1, "Hour": 9, "Minute": 0]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        try t.file("home/Library/LaunchAgents/de.bodendiek.klarschiff.check.plist", bytes: 5)
        let items = await LegacyAutomation.detect(ScanContext.test(root: t.root), uid: 501)
        #expect(items[0].explanation.contains("um 9:00 Uhr"))
        #expect(!items[1].explanation.contains(" Uhr"))
    }

    @Test func loadedStateFromLaunchctlPrint() async throws {
        let t = try fullFixture()
        let runner = FakeCommandRunner()
        runner.stub(launchctl, ["print", "gui/501/\(cleanupLabel)"], result: CommandResult(exitCode: 0, stdout: "x", stderr: ""))
        runner.stub(launchctl, ["print", "gui/501/\(checkLabel)"], result: CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service"))
        let items = await LegacyAutomation.detect(ScanContext.test(root: t.root, runner: runner), uid: 501)
        let loaded = items.filter(\.isLoaded)
        #expect(loaded.count == 1)
        if case .agent(let l) = loaded[0].kind { #expect(l == cleanupLabel) } else { Issue.record("kein Agent") }
        #expect(runner.calls.allSatisfy { $0.0 == launchctl && $0.1.first == "print" })
    }

    func loadedItems(_ t: FixtureTree, _ runner: FakeCommandRunner, both: Bool = true) async -> [LegacyItem] {
        runner.stub(launchctl, ["print", "gui/501/\(cleanupLabel)"], result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        if both {
            runner.stub(launchctl, ["print", "gui/501/\(checkLabel)"], result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        }
        return await LegacyAutomation.detect(ScanContext.test(root: t.root, runner: runner), uid: 501)
    }

    @Test func bootoutOnlyLoadedLabelsExactArgs() async throws {
        let t = try fullFixture()
        let runner = FakeCommandRunner()
        let items = await loadedItems(t, runner, both: false)
        let before = runner.calls.count
        runner.stub(launchctl, ["bootout", "gui/501/\(cleanupLabel)"], result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        let results = await LegacyAutomation.bootout(items, runner: runner, uid: 501, dryRun: false)
        let calls = runner.calls.dropFirst(before)
        #expect(calls.count == 1)
        #expect(calls.first?.0 == launchctl)
        #expect(calls.first?.1 == ["bootout", "gui/501/\(cleanupLabel)"])
        #expect(results.count == 1)
        #expect(results[0].outcome == .removed(freed: nil))
    }

    @Test func bootoutNotLoadedCountsAsDone() async throws {
        let t = try fullFixture()
        let runner = FakeCommandRunner()
        let items = await loadedItems(t, runner)
        runner.stub(launchctl, ["bootout", "gui/501/\(cleanupLabel)"], result: CommandResult(exitCode: 3, stdout: "", stderr: "No such process"))
        runner.stub(launchctl, ["bootout", "gui/501/\(checkLabel)"], result: CommandResult(exitCode: 113, stdout: "", stderr: "Boot-out failed: Could not find service"))
        let results = await LegacyAutomation.bootout(items, runner: runner, uid: 501, dryRun: false)
        #expect(results.map(\.outcome) == [.removed(freed: nil), .removed(freed: nil)])

        runner.stub(launchctl, ["bootout", "gui/501/\(cleanupLabel)"], result: CommandResult(exitCode: 5, stdout: "", stderr: "Input/output error"))
        let r2 = await LegacyAutomation.bootout(items, runner: runner, uid: 501, dryRun: false)
        if case .failed(let m) = r2[0].outcome { #expect(m.contains("Input/output error")) } else { Issue.record("erwartet failed") }
        #expect(r2[1].outcome == .removed(freed: nil))
    }

    @Test func bootoutDryRunNoCalls() async throws {
        let t = try fullFixture()
        let runner = FakeCommandRunner()
        let items = await loadedItems(t, runner)
        let before = runner.calls.count
        let results = await LegacyAutomation.bootout(items, runner: runner, uid: 501, dryRun: true)
        #expect(runner.calls.count == before)
        #expect(results.map(\.outcome) == [.skipped("Trockenlauf"), .skipped("Trockenlauf")])
    }

    @Test func removalFindingExtrasToggle() async throws {
        let t = try fullFixture()
        let items = await LegacyAutomation.detect(ScanContext.test(root: t.root), uid: 501)
        let lean = LegacyAutomation.removalFinding(items, ctx: ScanContext.test(root: t.root), includeExtras: false)
        #expect(lean.category == KlarschiffCore.Category.system)
        #expect(lean.method == .trash)
        #expect(lean.items.count == 2)
        #expect(lean.items.allSatisfy { $0.url?.pathExtension == "plist" })
        let full = LegacyAutomation.removalFinding(items, ctx: ScanContext.test(root: t.root), includeExtras: true)
        #expect(full.items.count == 6)
        #expect(Set(full.items.map(\.id)).count == 6)
    }
}
