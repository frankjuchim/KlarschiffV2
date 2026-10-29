import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct VersionedDirScannerTests {
    @Test func versionCompare() {
        #expect(VersionCompare.isNewer("18.2 (22C150)", than: "17.5 (21F79)"))
        #expect(VersionCompare.isNewer("v22.11.0", than: "v20.18.0"))
        #expect(!VersionCompare.isNewer("3.9.1", than: "3.12.0"))
    }

    @Test func deviceSupportKeepsNewestPerPlatform() async throws {
        let tree = try FixtureTree()
        let base = "home/Library/Developer/Xcode"
        try tree.file("\(base)/iOS DeviceSupport/17.5 (21F79)/a", bytes: 1000)
        try tree.file("\(base)/iOS DeviceSupport/18.2 (22C150)/a", bytes: 2000)
        try tree.file("\(base)/watchOS DeviceSupport/11.0 (22R349)/a", bytes: 500)
        let scanner = Catalog.allScanners().first { $0.id == "xcode.deviceSupport" }!
        let fs = try await scanner.scan(.test(root: tree.root, running: ["com.apple.dt.Xcode"]))
        #expect(fs.count == 3)
        let keep = Set(fs.filter(\.keepSuggested).map { $0.items[0].name })
        #expect(keep == ["18.2 (22C150)", "11.0 (22R349)"])
        let f = try #require(fs.first { $0.items[0].name == "18.2 (22C150)" })
        #expect(f.title == "iOS-Gerätesupport 18.2 (22C150)")
        #expect(f.category == .xcode && f.risk == .safe && f.method == .trash)
        #expect(f.id.key == f.items[0].url?.path)
        #expect(f.commandPreview == ["In den Papierkorb: \(f.items[0].url!.path)"])
        #expect((f.size ?? 0) >= 2000)
        #expect(f.blockingApps.map(\.displayName).contains("Xcode"))
        #expect(f.watchedApps.map(\.displayName).contains("Xcode"))
        #expect(fs.first { $0.title.hasPrefix("watchOS-Gerätesupport") } != nil)
    }

    @Test func nvmKeepsNewest() async throws {
        let tree = try FixtureTree()
        for v in ["v18.20.4", "v22.11.0", "v20.18.0"] { try tree.file("home/.nvm/versions/node/\(v)/bin/node", bytes: 100) }
        let scanner = Catalog.allScanners().first { $0.id == "languages.nvm" }!
        let fs = try await scanner.scan(.test(root: tree.root))
        #expect(fs.count == 3)
        #expect(fs.filter(\.keepSuggested).map { $0.items[0].name } == ["v22.11.0"])
        #expect(fs.allSatisfy { $0.category == .languages && $0.risk == .review && $0.method == .trash })
        #expect(fs.first?.title.hasSuffix(fs.first!.items[0].name) == true)
    }

    @Test func catalogRegistersAll() {
        let ids = Set(Catalog.allScanners().map(\.id))
        for id in ["toolchains.conda", "ai.ollama", "languages.rustup", "xcode.deviceSupport",
                   "languages.nvm", "languages.pyenv", "languages.rbenv"] { #expect(ids.contains(id)) }
    }

    @Test func missingParentYieldsNothing() async throws {
        let scanner = Catalog.allScanners().first { $0.id == "languages.pyenv" }!
        #expect(try await scanner.scan(.test()).isEmpty)
    }

    @Test func deviceSupportIgnoresModelNumber() async throws {
        let tree = try FixtureTree()
        let base = "home/Library/Developer/Xcode/iOS DeviceSupport"
        try tree.file("\(base)/iPhone15,2 18.2 (22C150)/a", bytes: 100)
        try tree.file("\(base)/iPhone16,1 17.5 (21F79)/a", bytes: 100)
        try tree.file("\(base)/17.0 (21A329)/a", bytes: 100)
        let scanner = Catalog.allScanners().first { $0.id == "xcode.deviceSupport" }!
        let fs = try await scanner.scan(.test(root: tree.root))
        #expect(fs.filter(\.keepSuggested).map { $0.items[0].name } == ["iPhone15,2 18.2 (22C150)"])
        #expect(fs.contains { $0.title == "iOS-Gerätesupport 18.2 (22C150) · iPhone15,2" })
        #expect(fs.contains { $0.title == "iOS-Gerätesupport 17.0 (21A329)" })
    }
}
