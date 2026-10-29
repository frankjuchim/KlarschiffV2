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
        let script = items.first { if case .agent(let l) = $0.kind { l == cleanupLabel } else { false } }!
        #expect(script.explanation.contains("leert jeden Monatsersten automatisch deine Caches"))
        let check = items.first { if case .agent(let l) = $0.kind { l == checkLabel } else { false } }!
        #expect(check.explanation.contains("zeigt auf eine App, die es nicht mehr gibt"))
        #expect(items.allSatisfy { !$0.isLoaded })
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
        let lean = LegacyAutomation.removalFinding(items, includeExtras: false)
        #expect(lean.category == KlarschiffCore.Category.system)
        #expect(lean.method == .trash)
        #expect(lean.items.count == 2)
        #expect(lean.items.allSatisfy { $0.url?.pathExtension == "plist" })
        let full = LegacyAutomation.removalFinding(items, includeExtras: true)
        #expect(full.items.count == 6)
        #expect(Set(full.items.map(\.id)).count == 6)
    }
}
