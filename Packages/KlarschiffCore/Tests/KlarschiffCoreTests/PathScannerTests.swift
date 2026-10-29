import Testing
import Foundation
@testable import KlarschiffCore

struct PathScannerTests {
    @Test func derivedDataFoundWithSizeAndDeleteCommand() async throws {
        let t = try FixtureTree(); try t.file("home/Library/Developer/Xcode/DerivedData/App-abc/x.o", bytes: 2_000_000)
        let f = try await PathScanner(rule: Catalog.rule("xcode.derivedData")).scan(.test(root: t.root)).first!
        #expect(f.category == .xcode && f.risk == .safe && f.method == .delete)
        #expect(f.size! >= 2_000_000)
        #expect(f.commandPreview.allSatisfy { !$0.contains("#") })
        let path = t.root.appending(path: "home/Library/Developer/Xcode/DerivedData/App-abc").path
        #expect(f.commandPreview == ["rm -rf " + ShellQuote.quote(path)])
        #expect(f.id == FindingID(scannerID: "xcode.derivedData", key: "all"))
        #expect(f.items.map(\.name) == ["App-abc"])
    }

    @Test func instrumentsCacheUsesUserCacheDirAndBlocksWhenXcodeRuns() async throws {
        let t = try FixtureTree(); try t.file("C/com.apple.dt.Instruments/a", bytes: 1000); try t.file("C/com.apple.dt.InstrumentsCLI/b", bytes: 1000)
        let f = try await PathScanner(rule: Catalog.rule("xcode.instruments")).scan(.test(root: t.root, running: ["com.apple.dt.Xcode"])).first!
        #expect(f.items.count == 2); #expect(f.blockingApps.map(\.displayName) == ["Xcode"])
    }

    @Test func missingPathsYieldNothing() async throws {
        #expect(try await PathScanner(rule: Catalog.rule("languages.gradle")).scan(.test(root: FixtureTree().root)).isEmpty)
    }

    @Test func minAgeFiltersYoungFiles() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/Logs/App/old.log", bytes: 5000); try t.setModified("home/Library/Logs/App/old.log", daysAgo: 40)
        try t.file("home/Library/Logs/App/new.log", bytes: 5000); try t.setModified("home/Library/Logs/App/new.log", daysAgo: 1)
        try t.file("home/Library/Logs/CoreSimulator/sim.log", bytes: 5000); try t.setModified("home/Library/Logs/CoreSimulator/sim.log", daysAgo: 40)
        let fs = try await PathScanner(rule: Catalog.rule("system.oldLogs")).scan(.test(root: t.root))
        #expect(fs.count == 1)
        let f = try #require(fs.first)
        #expect(f.items.map(\.name) == ["old.log"])
        #expect(f.size == f.items.compactMap(\.size).reduce(0, +))
        #expect(f.size! >= 5000)
        #expect(f.commandPreview == ["In den Papierkorb: " + t.root.appending(path: "home/Library/Logs/App/old.log").path])
    }

    @Test func minAgeWithOnlyYoungFilesYieldsNothing() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/Logs/App/new.log", bytes: 5000); try t.setModified("home/Library/Logs/App/new.log", daysAgo: 2)
        #expect(try await PathScanner(rule: Catalog.rule("system.oldLogs")).scan(.test(root: t.root)).isEmpty)
    }

    @Test func toolFallsBackWhenToolMissing() async throws {
        let t = try FixtureTree(); try t.file("home/.npm/_cacache/index/x", bytes: 1000)
        let f = try #require(try await PathScanner(rule: Catalog.rule("languages.npm")).scan(.test(root: t.root)).first)
        #expect(f.method == .delete)
        #expect(f.commandPreview == ["rm -rf " + ShellQuote.quote(t.root.appending(path: "home/.npm/_cacache").path)])
    }

    @Test func toolUsedWhenToolAvailable() async throws {
        let t = try FixtureTree(); try t.file("home/.npm/_cacache/index/x", bytes: 1000)
        let tools = ToolLocator(searchPaths: ["/opt/homebrew/bin"], fileExists: { $0 == "/opt/homebrew/bin/npm" })
        let f = try #require(try await PathScanner(rule: Catalog.rule("languages.npm")).scan(.test(root: t.root, tools: tools)).first)
        let cmd = ToolCommand(tool: "npm", arguments: ["cache", "clean", "--force"], timeout: .seconds(120))
        #expect(f.method == .tool([cmd], fallback: .delete))
        #expect(f.commandPreview == ["npm cache clean --force"])
    }

    @Test func toolWithoutFallbackBecomesHint() async throws {
        let t = try FixtureTree(); try t.file("home/Library/pnpm/store/v3/x", bytes: 1000)
        let f = try #require(try await PathScanner(rule: Catalog.rule("languages.pnpm")).scan(.test(root: t.root)).first)
        #expect(f.method == .hint(nil))
        #expect(f.risk == Catalog.rule("languages.pnpm").risk)
        #expect(f.commandPreview.isEmpty)
    }

    @Test func codexOnlyWhitelistedSubfolders() async throws {
        let t = try FixtureTree(); try t.file("home/.codex/log/a.log", bytes: 10); try t.file("home/.codex/auth.json", bytes: 10); try t.file("home/.codex/sessions/s.jsonl", bytes: 10)
        let urls = try await PathScanner(rule: Catalog.rule("ai.cliCaches")).scan(.test(root: t.root)).flatMap(\.items).compactMap(\.url?.lastPathComponent)
        #expect(urls == ["log"])
    }

    @Test func huggingFacePerMatchYieldsOneFindingPerModel() async throws {
        let t = try FixtureTree()
        try t.file("home/.cache/huggingface/hub/models--meta-llama--Llama-3/blob", bytes: 3000)
        try t.file("home/.cache/huggingface/hub/models--openai--whisper/blob", bytes: 3000)
        try t.file("home/.cache/huggingface/hub/version.txt", bytes: 10)
        let fs = try await PathScanner(rule: Catalog.rule("ai.huggingFace")).scan(.test(root: t.root))
        #expect(fs.count == 2)
        #expect(Set(fs.map(\.id.key)).count == 2)
        #expect(fs.allSatisfy { $0.id.key.hasSuffix($0.items.first!.name) && $0.items.count == 1 })
        #expect(fs.allSatisfy { $0.risk == .review && $0.method == .delete })
        #expect(Set(fs.map(\.title)) == ["Hugging Face: meta-llama/Llama-3", "Hugging Face: openai/whisper"])
    }

    @Test func hintRuleRevealsFirstItemInFinder() async throws {
        let t = try FixtureTree(); try t.file("home/Library/Arduino15/packages/esp32/tools/x", bytes: 4000)
        let fs = try await PathScanner(rule: Catalog.rule("toolchains.arduinoPackages")).scan(.test(root: t.root))
        let f = try #require(fs.first)
        #expect(fs.count == 1)
        #expect(f.risk == .hintOnly)
        #expect(f.method == .hint(.revealInFinder(t.root.appending(path: "home/Library/Arduino15/packages/esp32"))))
        #expect(f.size! >= 4000)
        #expect(f.commandPreview.isEmpty)
    }

    @Test func fullDiskAccessMissingYieldsUnmeasuredFinding() async throws {
        let t = try FixtureTree(); try t.file("home/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/a.pdf", bytes: 4000)
        let rule = Catalog.rule("personal.mailDownloads")
        let fs = try await PathScanner(rule: rule).scan(.test(root: t.root, hasFullDiskAccess: false))
        let f = try #require(fs.first)
        #expect(fs.count == 1)
        #expect(f.size == nil && f.items.isEmpty && f.needsFullDiskAccess)
        #expect(f.summary == rule.summary)
        let withAccess = try await PathScanner(rule: rule).scan(.test(root: t.root, hasFullDiskAccess: true))
        #expect(withAccess.first?.size ?? 0 >= 4000)
        #expect(withAccess.first?.needsFullDiskAccess == false)
    }

    @Test func globMatchesWithinOneComponentAndSkipsHiddenAndSymlinks() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/Developer/Xcode/DerivedData/A/x", bytes: 100)
        try t.file("home/Library/Developer/Xcode/DerivedData/.hidden/x", bytes: 100)
        let outside = try t.file("elsewhere/big", bytes: 100)
        try t.symlink("home/Library/Developer/Xcode/DerivedData/link", to: outside)
        let f = try #require(try await PathScanner(rule: Catalog.rule("xcode.derivedData")).scan(.test(root: t.root)).first)
        #expect(f.items.map(\.name) == ["A"])
    }

    @Test func minSizeDropsSmallItems() async throws {
        let t = try FixtureTree(); try t.file("home/a/big/x", bytes: 50_000); try t.file("home/a/small/x", bytes: 1)
        let rule = PathRule(id: "test.min", category: .system, title: "T", summary: "S", base: .home,
                            patterns: ["a/*"], risk: .safe, method: .trash, minSize: 20_000)
        let f = try #require(try await PathScanner(rule: rule).scan(.test(root: t.root)).first)
        #expect(f.items.map(\.name) == ["big"])
    }

    @Test func absoluteBaseUsesRootPrefix() async throws {
        let t = try FixtureTree(); try t.file("Library/Developer/CommandLineTools/usr/x", bytes: 1000)
        let fs = try await PathScanner(rule: Catalog.rule("xcode.libraryDeveloper")).scan(.test(root: t.root))
        #expect(fs.count == 1)
        #expect(fs.first?.items.first?.url == t.root.appending(path: "Library/Developer/CommandLineTools"))
        #expect(fs.first?.risk == .hintOnly)
    }
}
