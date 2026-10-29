import Testing
import Foundation
@testable import KlarschiffCore

struct TeXLiveScannerTests {
    @Test func oldYearsAreAdminFindings() async throws {
        let t = try FixtureTree()
        try t.file("usr/local/texlive/2022/a", bytes: 1000)
        try t.file("usr/local/texlive/2025/a", bytes: 1000)
        try t.dir("usr/local/texlive/texmf-local")
        let fs = try await TeXLiveScanner().scan(.test(root: t.root))
        let titles = fs.map(\.title)
        #expect(titles.contains("TeX Live 2022 (veraltet)"))
        #expect(!titles.contains("TeX Live 2025 (veraltet)"))
        #expect(!titles.contains { $0.contains("texmf") })
        let old = fs.first { $0.title.contains("2022") }!
        #expect(old.method == .admin([AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive/2022"])]))
        #expect(old.risk == .review && !old.keepSuggested)
        #expect(old.size ?? 0 >= 1000)
        #expect(old.items.first?.url == t.root.appending(path: "usr/local/texlive/2022"))
    }

    @Test func completeRemovalWithOnlyTexliveExisting() async throws {
        let t = try FixtureTree()
        try t.file("usr/local/texlive/2025/a", bytes: 1000)
        let fs = try await TeXLiveScanner().scan(.test(root: t.root))
        let all = try #require(fs.first { $0.title == "TeX Live komplett entfernen" })
        #expect(all.method == .admin([AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive"])]))
        #expect(all.summary.contains("brew install --cask basictex"))
        #expect(all.risk == .review)
        #expect(fs.count == 1)
    }

    @Test func completeRemovalWithAllThreeFolders() async throws {
        let t = try FixtureTree()
        try t.file("usr/local/texlive/2024/a", bytes: 100)
        try t.file("Library/TeX/a", bytes: 100)
        try t.file("Applications/TeX/a", bytes: 100)
        let fs = try await TeXLiveScanner().scan(.test(root: t.root))
        let all = try #require(fs.first { $0.title == "TeX Live komplett entfernen" })
        #expect(all.method == .admin(["/usr/local/texlive", "/Library/TeX", "/Applications/TeX"].map {
            AdminStep(executable: "/bin/rm", arguments: ["-rf", $0])
        }))
        #expect(all.items.count == 3)
    }

    @Test func nothingWithoutTexLive() async throws {
        let t = try FixtureTree()
        #expect(try await TeXLiveScanner().scan(.test(root: t.root)).isEmpty)
    }

    @Test func registeredInCatalog() {
        #expect(Catalog.allScanners().map(\.id).contains("toolchains.texlive"))
    }
}
