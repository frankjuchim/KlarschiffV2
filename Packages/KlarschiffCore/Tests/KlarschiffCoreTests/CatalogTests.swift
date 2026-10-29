import Testing
import Foundation
@testable import KlarschiffCore

/// Konkreter Pfad zu einem Muster: jedes `*` wird durch „x“ ersetzt.
private func instantiate(_ pattern: String) -> String {
    pattern.replacingOccurrences(of: "*", with: "x")
}

private func relBase(_ base: PathBase) -> String {
    switch base {
    case .home: "home"
    case .userCache: "C"
    case .absolute: ""
    }
}

struct CatalogTests {
    @Test func everyCatalogRuleHasGermanTextAndNoHashInPreviews() {
        for r in Catalog.pathRules() {
            #expect(!r.title.isEmpty && !r.summary.isEmpty, "\(r.id)")
            #expect(!r.patterns.isEmpty, "\(r.id)")
            if case .tool(let cmds, _) = r.method {
                #expect(cmds.allSatisfy { !$0.display.contains("#") && $0.timeout == .seconds(120) }, "\(r.id)")
            }
        }
    }

    @Test func ruleIDsAreUniqueAndDotted() {
        let ids = Catalog.pathRules().map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            let parts = id.split(separator: ".")
            #expect(parts.count == 2, "\(id)")
            #expect(KlarschiffCore.Category.allCases.contains { id.hasPrefix(prefix(for: $0) + ".") }, "\(id)")
        }
    }

    private func prefix(for c: KlarschiffCore.Category) -> String {
        switch c {
        case .system: "system"
        case .aiLeftovers: "ai"
        case .appCaches: "appCaches"
        case .personalData: "personal"
        case .apps: "apps"
        case .xcode: "xcode"
        case .simulators: "simulators"
        case .homebrew: "homebrew"
        case .languages: "languages"
        case .toolchains: "toolchains"
        }
    }

    @Test func hintRulesAreHintOnlyAndHintMethodsMatch() {
        for r in Catalog.pathRules() {
            if r.risk == .hintOnly { #expect(r.method == .hint(nil), "\(r.id)") }
            if case .hint = r.method { #expect(r.risk == .hintOnly, "\(r.id)") }
        }
    }

    @Test func allScannersCoverEveryRule() {
        let ids = Catalog.allScanners().map(\.id)
        #expect(Catalog.pathRules().allSatisfy { ids.contains($0.id) })
        #expect(Set(ids).count == ids.count)
    }

    /// Legt für jedes Muster jeder Regel einen Treffer an und prüft, dass er gefunden wird
    /// und kein kopierbarer Befehl ein „#“ enthält.
    @Test(arguments: [false, true])
    func everyPatternMatchesAndPreviewsHaveNoHash(toolsAvailable: Bool) async throws {
        let tools = ToolLocator(searchPaths: ["/bin"], fileExists: { _ in toolsAvailable })
        for rule in Catalog.pathRules() {
            let t = try FixtureTree()
            for p in rule.patterns {
                let rel = [relBase(rule.base), instantiate(p)].filter { !$0.isEmpty }.joined(separator: "/")
                try t.file(rel + "/inhalt.bin", bytes: 4096)
                if rule.minAgeDays != nil { try t.setModified(rel + "/inhalt.bin", daysAgo: 400) }
            }
            let fs = try await PathScanner(rule: rule).scan(.test(root: t.root, tools: tools))
            #expect(!fs.isEmpty, "\(rule.id)")
            let itemCount = fs.reduce(0) { $0 + $1.items.count }
            #expect(itemCount == rule.patterns.count, "\(rule.id)")
            if rule.grouping == .perMatch { #expect(fs.count == rule.patterns.count, "\(rule.id)") }
            for f in fs {
                #expect(f.id.scannerID == rule.id)
                #expect(f.category == rule.category)
                #expect(f.size ?? 0 >= 4096, "\(rule.id)")
                #expect(f.commandPreview.allSatisfy { !$0.contains("#") }, "\(rule.id): \(f.commandPreview)")
            }
        }
    }

    @Test func coworkVMRuleFindsVMBundleFolder() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img", bytes: 8192)
        let rule = Catalog.rule("ai.coworkVM")
        #expect(rule.risk == .review && rule.method == .delete)
        #expect(rule.blockingApps.map(\.bundleID) == ["com.anthropic.claudefordesktop"])
        let fs = try await PathScanner(rule: rule).scan(.test(root: t.root))
        let f = try #require(fs.first)
        #expect(fs.count == 1 && f.id.scannerID == "ai.coworkVM" && f.category == .aiLeftovers)
        #expect(f.risk == .review && f.method == .delete && f.size ?? 0 >= 8192)
        #expect(f.items.first?.url?.lastPathComponent == "vm_bundles")
        #expect(f.commandPreview.count == 1 && f.commandPreview[0].hasPrefix("rm -rf "))
        #expect(f.commandPreview[0].contains("vm_bundles") && !f.commandPreview[0].contains("#"))
        #expect(f.summary.contains("~12 GB"))
    }

    /// Versionsordner gehören allein dem VersionedDirScanner – keine PathRule darf sie doppelt melden.
    @Test func noPathRuleCoversVersionedDirectories() {
        let versioned = Catalog.allScanners().compactMap { $0 as? VersionedDirScanner }
        #expect(versioned.count == 4)
        for v in versioned {
            for r in Catalog.pathRules() where r.base == v.base {
                #expect(!r.patterns.contains { $0.hasPrefix(v.parent) }, "\(r.id) überschneidet \(v.id)")
            }
        }
        #expect(Catalog.rule("languages.ruby").patterns == [".gem/*"])
    }

    @Test func specValuesForSelectedRules() {
        let xcodeApps = Catalog.rule("xcode.derivedData").blockingApps
        #expect(xcodeApps.map(\.displayName) == ["Xcode", "Instruments", "xctrace", "instruments"])
        #expect(xcodeApps.compactMap(\.bundleID) == ["com.apple.dt.Xcode", "com.apple.dt.Instruments"])
        #expect(xcodeApps.compactMap(\.processName) == ["xctrace", "instruments"])
        let claude = Catalog.rule("ai.claudeCache")
        #expect(claude.patterns.count == 6 && claude.risk == .safe && claude.method == .trash)
        #expect(claude.blockingApps.map(\.bundleID) == ["com.anthropic.claudefordesktop"])
        #expect(Catalog.rule("ai.cliCaches").patterns.count == 15)
        #expect(Catalog.rule("languages.pnpm").method
                == .tool([ToolCommand(tool: "pnpm", arguments: ["store", "prune"], timeout: .seconds(120))], fallback: nil))
        let logs = Catalog.rule("system.oldLogs")
        #expect(logs.minAgeDays == 30 && logs.excludeNames == ["CoreSimulator"] && logs.patterns == ["Library/Logs"])
        let archives = Catalog.rule("xcode.archives")
        #expect(archives.risk == .review && archives.method == .trash && archives.grouping == .single)
        #expect(Catalog.rule("personal.mailDownloads").needsFullDiskAccess)
        #expect(Catalog.rule("xcode.libraryDeveloper").base == .absolute)
    }
}
