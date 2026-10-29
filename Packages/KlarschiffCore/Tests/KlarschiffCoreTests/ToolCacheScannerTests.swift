import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct ToolCacheScannerTests {
    private func ok(_ out: String) -> CommandResult { CommandResult(exitCode: 0, stdout: out, stderr: "") }
    private func tools(_ names: String...) -> ToolLocator {
        let set = Set(names.map { "/fake/bin/\($0)" })
        return ToolLocator(searchPaths: ["/fake/bin"], fileExists: { set.contains($0) })
    }

    // MARK: Ollama

    @Test func ollamaUsesRmWhenInstalled() async throws {
        let fake = FakeCommandRunner()
        fake.stub("/fake/bin/ollama", ["list"], result: .fixture("ollama-list.txt"))
        let fs = try await OllamaScanner().scan(.test(runner: fake, tools: tools("ollama")))
        #expect(fs.count == 3)
        let f = try #require(fs.first { $0.id.key == "qwen2.5-coder:7b" })
        #expect(f.category == .aiLeftovers && f.risk == .review)
        #expect(f.size == 4_700_000_000)
        #expect(f.items.first?.url == nil)
        let cmd = ToolCommand(tool: "ollama", arguments: ["rm", "qwen2.5-coder:7b"], timeout: .seconds(300))
        #expect(f.method == .tool([cmd], fallback: nil))
        #expect(f.commandPreview == ["ollama rm qwen2.5-coder:7b"])
        #expect(f.blockingApps.isEmpty)
        #expect(fs.first { $0.id.key == "nomic-embed-text:latest" }?.size == 274_000_000)
        #expect(fs.allSatisfy { !$0.commandPreview.joined().contains("#") })
    }

    @Test func ollamaFallsBackToDeleteWithoutCli() async throws {
        let tree = try FixtureTree()
        try tree.file("home/.ollama/models/blobs/sha256-a", bytes: 4000)
        let ctx = ScanContext.test(root: tree.root, running: ["ollama"])
        let fs = try await OllamaScanner().scan(ctx)
        let f = try #require(fs.first)
        #expect(fs.count == 1 && f.id.key == "models")
        #expect(f.risk == .review && f.method == .delete)
        #expect(f.size ?? 0 >= 4000)
        let path = tree.root.appending(path: "home/.ollama/models").path
        #expect(f.commandPreview == ["rm -rf " + ShellQuote.quote(path)])
        #expect(f.blockingApps.map(\.displayName) == ["ollama"])
    }

    @Test func ollamaServerDownFallsBackToFolder() async throws {
        let tree = try FixtureTree()
        try tree.file("home/.ollama/models/blobs/sha256-a", bytes: 4000)
        let fake = FakeCommandRunner()
        fake.stub("/fake/bin/ollama", ["list"], result: CommandResult(exitCode: 1, stdout: "", stderr: "could not connect"))
        let fs = try await OllamaScanner().scan(.test(root: tree.root, runner: fake, running: ["com.electron.ollama"], tools: tools("ollama")))
        let f = try #require(fs.first)
        #expect(f.id.key == "models" && f.method == .delete)
        #expect(f.blockingApps.map(\.displayName) == ["Ollama"])
        #expect(f.watchedApps.map(\.displayName) == ["Ollama", "ollama"])
    }

    @Test func ollamaServerDownWithoutFolderThrows() async throws {
        let fake = FakeCommandRunner()
        fake.stub("/fake/bin/ollama", ["list"], result: CommandResult(exitCode: 1, stdout: "", stderr: "x"))
        await #expect(throws: CommandError.self) {
            _ = try await OllamaScanner().scan(.test(runner: fake, tools: tools("ollama")))
        }
    }

    @Test func rustupRejectsUnsafeNamesAndSymlinks() async throws {
        let tree = try FixtureTree()
        let outside = try tree.dir("outside")
        try tree.dir("home/.rustup/toolchains/good")
        try tree.symlink("home/.rustup/toolchains/linked", to: outside)
        let fake = FakeCommandRunner()
        fake.stub("/fake/bin/rustup", ["toolchain", "list"],
                  result: CommandResult(exitCode: 0, stdout: "good\n..\n.\n../x\na/b\nlinked\n", stderr: ""))
        let fs = try await RustupScanner().scan(.test(root: tree.root, runner: fake, tools: tools("rustup")))
        #expect(fs.map(\.id.key) == ["good"])
    }

    @Test func ollamaNothingWithoutCliAndModels() async throws {
        #expect(try await OllamaScanner().scan(.test()).isEmpty)
    }

    // MARK: Rustup

    @Test func rustupDefaultIsKeepSuggested() async throws {
        let tree = try FixtureTree()
        for n in ["stable-aarch64-apple-darwin", "nightly-aarch64-apple-darwin"] {
            try tree.file("home/.rustup/toolchains/\(n)/bin/rustc", bytes: 1000)
        }
        let fake = FakeCommandRunner()
        fake.stub("/fake/bin/rustup", ["toolchain", "list"], result: .fixture("rustup-toolchain-list.txt"))
        let fs = try await RustupScanner().scan(.test(root: tree.root, runner: fake, tools: tools("rustup")))
        #expect(fs.count == 2)  // 1.70.0 hat keinen Ordner
        let stable = try #require(fs.first { $0.id.key == "stable-aarch64-apple-darwin" })
        let nightly = try #require(fs.first { $0.id.key == "nightly-aarch64-apple-darwin" })
        #expect(stable.keepSuggested && !nightly.keepSuggested)
        #expect(stable.category == .languages && stable.risk == .review)
        let cmd = ToolCommand(tool: "rustup", arguments: ["toolchain", "uninstall", "nightly-aarch64-apple-darwin"], timeout: .seconds(300))
        #expect(nightly.method == .tool([cmd], fallback: nil))
        #expect(nightly.items.first?.url == tree.root.appending(path: "home/.rustup/toolchains/nightly-aarch64-apple-darwin"))
        #expect((nightly.size ?? 0) >= 1000)
    }

    @Test func rustupParsesActiveMarkers() {
        let out = "a (active, default)\nb (active)\nc\n"
        let p = RustupScanner.parse(out)
        #expect(p.map(\.name) == ["a", "b", "c"])
        #expect(p.map(\.isDefault) == [true, false, false])
    }

    // MARK: Conda

    private func condaTree() throws -> FixtureTree {
        let tree = try FixtureTree()
        try tree.file("home/miniconda3/pkgs/numpy/lib", bytes: 3000)
        try tree.file("home/miniconda3/bin/python", bytes: 1000)
        try tree.file("home/.conda/pkgs/x/y", bytes: 500)
        return tree
    }

    @Test func condaCacheUsesCondaClean() async throws {
        let tree = try condaTree()
        let ctx = ScanContext.test(root: tree.root, tools: tools("conda"))
        let fs = try await CondaScanner().scan(ctx)
        let pkgs = try #require(fs.first { $0.id.key == "pkgs" })
        #expect(pkgs.category == .toolchains && pkgs.risk == .review)
        let cmd = ToolCommand(tool: "conda", arguments: ["clean", "--all", "-y"], timeout: .seconds(300))
        #expect(pkgs.method == .tool([cmd], fallback: nil))
        #expect(pkgs.items.count == 2 && (pkgs.size ?? 0) >= 3500)
        #expect(pkgs.commandPreview == ["conda clean --all -y"])

        let instPath = tree.root.appending(path: "home/miniconda3").path
        let inst = try #require(fs.first { $0.id.key == instPath })
        #expect(inst.risk == .hintOnly)
        #expect(inst.title == "Miniconda – ganze Installation")
        guard case .hint(.revealInFinder(let revealed)) = inst.method else { Issue.record("kein Hinweis"); return }
        #expect(revealed.path == instPath)
        #expect((inst.size ?? 0) >= 4000)
        #expect(inst.commandPreview.isEmpty)
        #expect(inst.summary.contains("anaconda-clean"))
    }

    @Test func condaWithoutCondaDegradesToHint() async throws {
        let tree = try condaTree()
        let fs = try await CondaScanner().scan(.test(root: tree.root))
        let pkgs = try #require(fs.first { $0.id.key == "pkgs" })
        #expect(pkgs.risk == .hintOnly)
        guard case .hint(.revealInFinder) = pkgs.method else { Issue.record("kein Hinweis"); return }
        #expect(pkgs.commandPreview.isEmpty)
    }

    @Test func condaNothingInstalled() async throws {
        #expect(try await CondaScanner().scan(.test()).isEmpty)
    }
}
