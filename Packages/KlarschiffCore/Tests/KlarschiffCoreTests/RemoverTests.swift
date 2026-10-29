import Testing
import Foundation
@testable import KlarschiffCore

private func makeGuard(_ tree: FixtureTree) -> (SafetyGuard, URL) {
    let home = tree.root.appending(path: "home", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let g = SafetyGuard(home: home, userCacheDir: tree.root.appending(path: "C"), allowedCacheSubdirs: [])
    return (g, home)
}

private func finding(_ method: RemovalMethod, items: [FindingItem] = []) -> Finding {
    Finding(id: FindingID(scannerID: "t", key: "k"), category: .appCaches, title: "T", summary: "S", risk: .safe,
            method: method, items: items, size: nil, blockingApps: [], keepSuggested: false,
            commandPreview: [], needsFullDiskAccess: false)
}

private func item(_ id: String, _ url: URL?, size: Int64? = 10) -> FindingItem {
    FindingItem(id: id, url: url, name: id, size: size)
}

@Suite struct RemoverTests {
    @Test func trashRemoverRefusesGuardedPath() async throws {
        let tree = try FixtureTree()
        let (g, home) = makeGuard(tree)
        let doc = try tree.file("home/Documents/x", bytes: 4)
        let r = await TrashRemover(guard: g).remove(finding(.trash), items: [item("a", doc)], dryRun: false)
        guard case .failed(let msg) = r[0].outcome else { Issue.record("expected failed"); return }
        #expect(msg.hasPrefix("Gesperrt: "))
        #expect(FileManager.default.fileExists(atPath: doc.path))
        _ = home
    }

    @Test func trashRemoverMovesFile() async throws {
        let tree = try FixtureTree()
        let (g, _) = makeGuard(tree)
        let f = try tree.file("home/Library/Caches/foo/a.bin", bytes: 4)
        let r = await TrashRemover(guard: g).remove(finding(.trash), items: [item("a", f, size: 4)], dryRun: false)
        #expect(r.count == 1 && r[0].itemID == "a")
        #expect(r[0].outcome == .removed(freed: 4))
        #expect(!FileManager.default.fileExists(atPath: f.path))
    }

    @Test func deleteRemoverDeletes() async throws {
        let tree = try FixtureTree()
        let (g, _) = makeGuard(tree)
        let d = try tree.dir("home/Library/Caches/foo")
        try tree.file("home/Library/Caches/foo/a.bin", bytes: 4)
        let r = await DeleteRemover(guard: g).remove(finding(.delete), items: [item("a", d)], dryRun: false)
        #expect(r[0].outcome == .removed(freed: 10))
        #expect(!FileManager.default.fileExists(atPath: d.path))
    }

    @Test func deleteRemoverHandlesReadOnlyTree() async throws {
        let tree = try FixtureTree()
        let (g, _) = makeGuard(tree)
        let top = try tree.dir("home/go/pkg/mod/x@v1")
        let f = try tree.file("home/go/pkg/mod/x@v1/sub/a.go", bytes: 4)
        let sub = f.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: f.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sub.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: top.path)
        defer {
            for u in [top, sub] { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path) }
        }
        let r = await DeleteRemover(guard: g).remove(finding(.delete), items: [item("a", top)], dryRun: false)
        #expect(r[0].outcome == .removed(freed: 10))
        #expect(!FileManager.default.fileExists(atPath: top.path))
    }

    @Test func deleteDoesNotFollowSymlinkWhenFixingPermissions() async throws {
        let tree = try FixtureTree()
        let (g, _) = makeGuard(tree)
        let outside = try tree.dir("outside")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: outside.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path) }
        let top = try tree.dir("home/go/pkg/mod/y")
        try tree.symlink("home/go/pkg/mod/y/link", to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: top.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: top.path) }
        _ = await DeleteRemover(guard: g).remove(finding(.delete), items: [item("a", top)], dryRun: false)
        let perms = try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int
        #expect(perms == 0o555)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func dryRunTouchesNothing() async throws {
        let tree = try FixtureTree()
        let (g, _) = makeGuard(tree)
        let f = try tree.file("home/Library/Caches/foo/a.bin", bytes: 4)
        let doc = try tree.file("home/Documents/x", bytes: 4)
        for remover in [TrashRemover(guard: g) as Remover, DeleteRemover(guard: g)] {
            let r = await remover.remove(finding(.delete), items: [item("a", f), item("b", doc), item("c", nil)], dryRun: true)
            #expect(r[0].outcome == .skipped("Trockenlauf"))
            guard case .failed(let m) = r[1].outcome else { Issue.record("expected failed"); return }
            #expect(m.hasPrefix("Gesperrt: "))
            #expect(r[2].outcome == .skipped("Kein Pfad"))
            #expect(FileManager.default.fileExists(atPath: f.path))
            #expect(FileManager.default.fileExists(atPath: doc.path))
        }
        let runner = FakeCommandRunner()
        let tool = finding(.tool([ToolCommand(tool: "brew", arguments: ["cleanup"], timeout: .seconds(5))], fallback: nil))
        let t = await ToolRemover(runner: runner, tools: ToolLocator(searchPaths: ["/x"], fileExists: { _ in true }))
            .remove(tool, items: [item("a", nil)], dryRun: true)
        #expect(t[0].outcome == .skipped("Trockenlauf"))
        #expect(runner.calls.isEmpty)
    }

    // MARK: Admin

    private func rm(_ args: String...) -> AdminStep { AdminStep(executable: "/bin/rm", arguments: args) }

    @Test func cancelledAdminMarksAllCancelled() async throws {
        let tree = try FixtureTree()
        let (g, _) = makeGuard(tree)
        let ex = FakeExecutor(fixed: .cancelled)
        let fnd = finding(.admin([rm("-rf", "/usr/local/texlive/2022")]), items: [item("a", nil)])
        let r = await AdminRemover(executor: ex, guard: g).remove([(fnd, fnd.items)], dryRun: false)
        #expect(r.map(\.outcome) == [.cancelled])
    }

    @Test func adminSkipsGuardedRmTarget() async throws {
        let tree = try FixtureTree()
        let (g, _) = makeGuard(tree)
        let ex = FakeExecutor(fixed: .completed([0]))
        let fnd = finding(.admin([rm("-rf", "/System"), rm("-rf", "/usr/local/texlive/2022")]),
                          items: [item("sys", nil), item("tex", nil, size: 7)])
        let r = await AdminRemover(executor: ex, guard: g).remove([(fnd, fnd.items)], dryRun: false)
        #expect(ex.runs == [[rm("-rf", "/usr/local/texlive/2022")]])
        guard case .failed(let m) = r[0].outcome else { Issue.record("expected failed"); return }
        #expect(m.hasPrefix("Gesperrt: "))
        #expect(r[1].outcome == .removed(freed: 7))
    }

    @Test func adminChecksEveryRmArgument() async throws {
        let tree = try FixtureTree()
        let (g, _) = makeGuard(tree)
        let ex = FakeExecutor(fixed: .completed([]))
        let fnd = finding(.admin([rm("-rf", "/usr/local/texlive/2022", "/System")]), items: [item("a", nil)])
        let r = await AdminRemover(executor: ex, guard: g).remove([(fnd, fnd.items)], dryRun: false)
        #expect(ex.runs.isEmpty)
        guard case .failed(let m) = r[0].outcome else { Issue.record("expected failed"); return }
        #expect(m.hasPrefix("Gesperrt: "))
    }

    @Test func adminRejectsRelativeAndDashPaths() async throws {
        let tree = try FixtureTree()
        let (g, _) = makeGuard(tree)
        let ex = FakeExecutor(fixed: .completed([]))
        let a = finding(.admin([rm("-rf", "texlive")]), items: [item("a", nil)])
        let b = finding(.admin([rm("-rf", "--", "-System")]), items: [item("b", nil)])
        let r = await AdminRemover(executor: ex, guard: g).remove([(a, a.items), (b, b.items)], dryRun: false)
        #expect(ex.runs.isEmpty)
        #expect(r.allSatisfy { if case .failed = $0.outcome { true } else { false } })
    }

    @Test func adminOneToOneMappingUsesOnlySelectedStep() async throws {
        let tree = try FixtureTree()
        let (g, _) = makeGuard(tree)
        let ex = FakeExecutor(fixed: .completed([3]))
        let s0 = AdminStep(executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", "A"])
        let s1 = AdminStep(executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", "B"])
        let fnd = finding(.admin([s0, s1]), items: [item("A", nil), item("B", nil)])
        let r = await AdminRemover(executor: ex, guard: g).remove([(fnd, [fnd.items[1]])], dryRun: false)
        #expect(ex.runs == [[s1]])
        #expect(r.count == 1 && r[0].itemID == "B" && r[0].outcome == .failed("Exit 3"))
    }

    @Test func adminDryRunAndMissingMarker() async throws {
        let tree = try FixtureTree()
        let (g, _) = makeGuard(tree)
        let fnd = finding(.admin([rm("-rf", "/usr/local/texlive/2022")]), items: [item("a", nil)])
        let ex = FakeExecutor(fixed: .completed([]))
        let dry = await AdminRemover(executor: ex, guard: g).remove([(fnd, fnd.items)], dryRun: true)
        #expect(dry.map(\.outcome) == [.skipped("Trockenlauf")])
        #expect(ex.runs.isEmpty)
        let r = await AdminRemover(executor: ex, guard: g).remove([(fnd, fnd.items)], dryRun: false)
        #expect(r.map(\.outcome) == [.failed("Nicht ausgeführt")])
    }

    // MARK: Tool

    private let tools = ToolLocator(searchPaths: ["/opt/homebrew/bin"], fileExists: { $0 == "/opt/homebrew/bin/brew" })

    @Test func toolRemoverReportsUntrustedTap() async throws {
        let runner = FakeCommandRunner()
        runner.stub("/opt/homebrew/bin/brew", ["uninstall", "--cask", "foo"],
                    result: CommandResult(exitCode: 1, stdout: "", stderr: "Error: Refusing to load cask from untrusted tap acme/tools."))
        let cmd = ToolCommand(tool: "brew", arguments: ["uninstall", "--cask", "foo"], timeout: .seconds(5))
        let fnd = finding(.tool([cmd], fallback: nil), items: [item("foo", nil)])
        let r = await ToolRemover(runner: runner, tools: tools).remove(fnd, items: fnd.items, dryRun: false)
        #expect(r[0].outcome == .failed("Homebrew vertraut diesem Tap nicht. Führe nacheinander aus: brew trust acme/tools · brew uninstall --cask foo · brew untap acme/tools"))
        #expect(runner.environments.first == ToolLocator.brewEnvironment)
    }

    @Test func toolRemoverRunsSequentiallyAndStopsAtFailure() async throws {
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/xcrun", ["simctl", "a"], result: CommandResult(exitCode: 2, stdout: "", stderr: "boom"))
        let cmds = [ToolCommand(tool: "xcrun", arguments: ["simctl", "a"], timeout: .seconds(5)),
                    ToolCommand(tool: "xcrun", arguments: ["simctl", "b"], timeout: .seconds(5))]
        let fnd = finding(.tool(cmds, fallback: nil), items: [item("x", nil), item("y", nil)])
        let r = await ToolRemover(runner: runner, tools: tools).remove(fnd, items: fnd.items, dryRun: false)
        #expect(r.map(\.outcome) == [.failed("boom"), .failed("boom")])
        #expect(runner.calls.count == 1)
    }

    @Test func toolRemoverSuccessTimeoutAndWrongMethod() async throws {
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/xcrun", ["ok"], result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        runner.stubTimeout("/usr/bin/xcrun", ["slow"])
        let ok = finding(.tool([ToolCommand(tool: "xcrun", arguments: ["ok"], timeout: .seconds(5))], fallback: nil), items: [item("x", nil, size: 5)])
        let slow = finding(.tool([ToolCommand(tool: "xcrun", arguments: ["slow"], timeout: .seconds(5))], fallback: nil), items: [item("x", nil)])
        let remover = ToolRemover(runner: runner, tools: tools)
        #expect(await remover.remove(ok, items: ok.items, dryRun: false).map(\.outcome) == [.removed(freed: 5)])
        #expect(await remover.remove(slow, items: slow.items, dryRun: false).map(\.outcome) == [.failed("Zeitüberschreitung")])
        let wrong = finding(.trash, items: [item("x", nil)])
        #expect(await remover.remove(wrong, items: wrong.items, dryRun: false).map(\.outcome) == [.failed("Falsche Methode")])
    }

    @Test func toolRemoverMissingExecutable() async throws {
        let runner = FakeCommandRunner()
        let fnd = finding(.tool([ToolCommand(tool: "rustup", arguments: ["x"], timeout: .seconds(5))], fallback: nil), items: [item("x", nil)])
        let r = await ToolRemover(runner: runner, tools: tools).remove(fnd, items: fnd.items, dryRun: false)
        #expect(r[0].outcome == .failed("Werkzeug nicht gefunden: rustup"))
        #expect(runner.calls.isEmpty)
    }
}
