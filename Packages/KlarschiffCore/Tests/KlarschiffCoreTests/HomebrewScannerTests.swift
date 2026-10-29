import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct HomebrewScannerTests {
    private static let brew = "/fake/bin/brew"
    private static let tools = ToolLocator(searchPaths: ["/fake/bin"], fileExists: { $0 == "/fake/bin/brew" })

    private func template(_ name: String, root: URL) throws -> String {
        try String(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/\(name)"), encoding: .utf8)
            .replacingOccurrences(of: "@@ROOT@@", with: root.path)
    }

    private func ok(_ out: String) -> CommandResult { CommandResult(exitCode: 0, stdout: out, stderr: "") }

    private func cleanupFake(_ tree: FixtureTree, autoremove: String? = nil) throws -> FakeCommandRunner {
        let fake = FakeCommandRunner()
        fake.stub(Self.brew, ["--prefix"], result: ok("\(tree.root.path)/opt/homebrew\n"))
        fake.stub(Self.brew, ["--cache"], result: ok("\(tree.root.path)/Library/Caches/Homebrew\n"))
        fake.stub(Self.brew, ["cleanup", "--prune=all", "-n"], result: ok(try template("brew-cleanup-n.txt", root: tree.root)))
        fake.stub(Self.brew, ["autoremove", "-n"], result: ok(try autoremove ?? template("brew-autoremove-n.txt", root: tree.root)))
        return fake
    }

    private func cleanupTree() throws -> FixtureTree {
        let tree = try FixtureTree()
        try tree.file("Library/Caches/Homebrew/xcodegen--2.46.0", bytes: 2000)
        try tree.file("opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.7/bin/ruby", bytes: 5000)
        try tree.file("opt/homebrew/Cellar/mitmproxy/1.0/bin/x", bytes: 3000)
        return tree
    }

    @Test func parsesCleanupDryRun() async throws {
        let tree = try cleanupTree()
        let fake = try cleanupFake(tree)
        let fs = try await HomebrewCleanupScanner().scan(.test(runner: fake, tools: Self.tools))
        let f = try #require(fs.first)
        #expect(fs.count == 1 && f.id == FindingID(scannerID: "brew.cleanup", key: "all"))
        #expect(f.category == .homebrew && f.risk == .safe)
        #expect(f.title == "Homebrew aufräumen")
        let ids = f.items.map(\.id)
        #expect(ids.contains("\(tree.root.path)/opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.7"))
        #expect(ids.contains("\(tree.root.path)/Library/Caches/Homebrew/portable-ruby-4.0.9.arm64_big_sur.bottle.tar.gz"))
        #expect(ids.contains("\(tree.root.path)/Library/Caches/Homebrew/bootsnap/1648b9c0eb5134fdce8dfbcecb391fcc931156d9b42dd086d11aea90ad04efe9"))
        #expect(ids.contains("formula:mitmproxy") && ids.contains("formula:libyaml"))
        #expect(f.items.count == 8)
        let ruby = try #require(f.items.first { $0.name == "4.0.7" })
        #expect(try #require(ruby.size) >= 5000)
        let formula = try #require(f.items.first { $0.id == "formula:mitmproxy" })
        #expect(formula.name == "mitmproxy" && formula.detail == "nicht mehr benötigt")
        #expect(formula.url == URL(fileURLWithPath: "\(tree.root.path)/opt/homebrew/Cellar/mitmproxy"))
        #expect((formula.size ?? 0) >= 3000)
        let cmds = [ToolCommand(tool: "brew", arguments: ["cleanup", "--prune=all"], timeout: .seconds(300)),
                    ToolCommand(tool: "brew", arguments: ["autoremove"], timeout: .seconds(300))]
        #expect(f.method == .tool(cmds, fallback: nil))
        #expect(f.commandPreview == ["brew cleanup --prune=all", "brew autoremove"])
        #expect(f.blockingApps.isEmpty)
    }

    @Test func cacheClaimedAndBrewEnvPassed() async throws {
        let tree = try cleanupTree()
        let fake = try cleanupFake(tree)
        let ctx = ScanContext.test(runner: fake, tools: Self.tools)
        _ = try await HomebrewCleanupScanner().scan(ctx)
        let cache = URL(fileURLWithPath: "\(tree.root.path)/Library/Caches/Homebrew")
        #expect(await ctx.claims.isClaimed(cache))
        #expect(await ctx.claims.isClaimed(cache.appending(path: "bootsnap")))
        #expect(!fake.environments.isEmpty)
        #expect(fake.environments.allSatisfy { $0 == ToolLocator.brewEnvironment })
    }

    @Test func nothingToCleanNoFinding() async throws {
        let tree = try cleanupTree()
        let fake = try cleanupFake(tree, autoremove: "")
        fake.stub(Self.brew, ["cleanup", "--prune=all", "-n"], result: ok(""))
        #expect(try await HomebrewCleanupScanner().scan(.test(runner: fake, tools: Self.tools)).isEmpty)
    }

    @Test func cacheClaimedEvenWhenNothingToClean() async throws {
        let tree = try cleanupTree()
        let fake = try cleanupFake(tree, autoremove: "")
        fake.stub(Self.brew, ["cleanup", "--prune=all", "-n"], result: ok(""))
        let ctx = ScanContext.test(runner: fake, tools: Self.tools)
        #expect(try await HomebrewCleanupScanner().scan(ctx).isEmpty)
        #expect(await ctx.claims.isClaimed(URL(fileURLWithPath: "\(tree.root.path)/Library/Caches/Homebrew")))
    }

    @Test func nonZeroExitThrows() async throws {
        let tree = try cleanupTree()
        let fake = try cleanupFake(tree)
        fake.stub(Self.brew, ["cleanup", "--prune=all", "-n"], result: CommandResult(exitCode: 1, stdout: "", stderr: "Error: boom"))
        await #expect(throws: (any Error).self) { try await HomebrewCleanupScanner().scan(.test(runner: fake, tools: Self.tools)) }
    }

    @Test func casksAbove200MBOnly() async throws {
        let fake = FakeCommandRunner()
        fake.stub(Self.brew, ["--prefix"], result: ok("/opt/homebrew\n"))
        fake.stub(Self.brew, ["list", "--cask"], result: ok("flutter\ntiny\n"))
        let scanner = HomebrewCaskScanner(sizeOf: { $0.lastPathComponent == "flutter" ? 3_700_000_000 : 1_000_000 })
        let fs = try await scanner.scan(.test(runner: fake, tools: Self.tools))
        let f = try #require(fs.first)
        #expect(fs.count == 1 && f.id == FindingID(scannerID: "brew.cask", key: "flutter"))
        #expect(f.category == .homebrew && f.risk == .review && !f.isPreselected(isKept: false))
        #expect(f.title == "flutter (Homebrew-Cask)")
        #expect(f.size == 3_700_000_000)
        #expect(f.items.count == 1 && f.items[0].id == "flutter" && f.items[0].url == URL(fileURLWithPath: "/opt/homebrew/Caskroom/flutter"))
        let cmd = ToolCommand(tool: "brew", arguments: ["uninstall", "--cask", "flutter"], timeout: .seconds(300))
        #expect(f.method == .tool([cmd], fallback: nil))
        #expect(f.commandPreview == [cmd.display])
        #expect(f.blockingApps.isEmpty)
        #expect(fake.environments.allSatisfy { $0 == ToolLocator.brewEnvironment })
    }

    @Test func caskFixtureParsedAndDefaultSizer() async throws {
        let fake = FakeCommandRunner()
        fake.stub(Self.brew, ["--prefix"], result: ok("/nonexistent-prefix\n"))
        fake.stub(Self.brew, ["list", "--cask"], result: .fixture("brew-list-cask.txt"))
        // Default-Sizer auf nicht vorhandenen Pfaden: nichts ≥ 200 MB, kein Absturz
        let fs = try await HomebrewCaskScanner().scan(.test(runner: fake, tools: Self.tools))
        #expect(fs.isEmpty)
    }

    @Test func noBrewNoFindings() async throws {
        let fake = FakeCommandRunner()
        #expect(try await HomebrewCleanupScanner().scan(.test(runner: fake)).isEmpty)
        #expect(try await HomebrewCaskScanner().scan(.test(runner: fake)).isEmpty)
        #expect(fake.calls.isEmpty)
    }

    @Test func detectsUntrustedTap() {
        #expect(HomebrewErrors.untrustedTap(in: "Error: Refusing to load cask from untrusted tap homebrew/cask-versions") == "homebrew/cask-versions")
        #expect(HomebrewErrors.untrustedTap(in: "Error: Tap foo/bar is not trusted.") == "foo/bar")
        #expect(HomebrewErrors.untrustedTap(in: "Error: Refusing to load from untrusted tap foo/bar.") == "foo/bar")
        #expect(HomebrewErrors.untrustedTap(in: "Error: No such file") == nil)
    }

    @Test func registeredInCatalog() {
        let ids = Catalog.allScanners().map(\.id)
        #expect(ids.contains("brew.cleanup") && ids.contains("brew.cask"))
    }
}
