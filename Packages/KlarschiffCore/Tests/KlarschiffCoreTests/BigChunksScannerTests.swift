import Testing
import Foundation
@testable import KlarschiffCore

struct BigChunksScannerTests {
    private func stub(_ sizes: [String: Int64]) -> @Sendable (URL) async throws -> Int64 {
        { sizes[$0.lastPathComponent] ?? 0 }
    }

    private func finding(risk: Risk, url: URL, size: Int64) -> Finding {
        let items = [FindingItem(id: url.path, url: url, name: url.lastPathComponent, size: size)]
        return Finding(
            id: FindingID(scannerID: "t", key: url.lastPathComponent), category: .apps, title: "t", summary: "s",
            risk: risk, method: .trash, items: items, size: size, blockingApps: [], keepSuggested: false,
            commandPreview: [], needsFullDiskAccess: false)
    }

    @Test func bigChunksAboveOneGBWithCleanablePart() async throws {
        let t = try FixtureTree()
        try t.dir("home/Library/Application Support/Claude")
        try t.dir("home/Library/Application Support/Autodesk")
        try t.dir("home/Library/Application Support/Small")
        let ctx = ScanContext.test(root: t.root)
        let claudeFinding = finding(
            risk: .safe, url: ctx.homePath("Library/Application Support/Claude/vm_bundles"), size: 12_040_000_000)
        let scanner = BigChunksScanner(sizeOf: stub([
            "Claude": 13_060_000_000, "Autodesk": 11_110_000_000, "Small": 500_000_000]))
        let chunks = await scanner.scan(ctx, findings: [claudeFinding])
        #expect(chunks.map(\.displayName) == ["Claude", "Autodesk"])
        #expect(chunks[0].cleanableSize == 12_040_000_000)
        #expect(chunks[1].cleanableSize == 0)
    }

    @Test func cleanableSizeNeverExceedsChunkSize() async throws {
        let t = try FixtureTree()
        try t.dir("opt/texlive")
        let ctx = ScanContext.test(root: t.root)
        // Überlappende Funde (TeX komplett + einzelne Jahrgänge) zählen dieselben Bytes doppelt.
        let whole = finding(risk: .review, url: ctx.absolute("/opt/texlive"), size: 6_000_000_000)
        let year = finding(risk: .review, url: ctx.absolute("/opt/texlive/2023"), size: 4_000_000_000)
        let chunks = await BigChunksScanner(sizeOf: stub(["texlive": 6_000_000_000])).scan(ctx, findings: [whole, year])
        #expect(chunks.map(\.size) == [6_000_000_000])
        #expect(chunks[0].cleanableSize == 6_000_000_000)
    }

    @Test func hintOnlyFindingsAreNotCleanableAndLibraryIsSkipped() async throws {
        let t = try FixtureTree()
        try t.dir("home/Library/Application Support/Claude")
        try t.dir("home/Library/Foo")
        try t.dir("home/Movies")
        try t.symlink("home/Linked", to: try t.dir("elsewhere"))
        try t.dir("Applications/Big.app")
        let ctx = ScanContext.test(root: t.root)
        let hint = finding(risk: .hintOnly, url: ctx.homePath("Library/Application Support/Claude/h"), size: 5_000_000_000)
        let safe = finding(risk: .safe, url: ctx.homePath("Library/Application Support/Claude/s"), size: 2_000_000_000)
        let big: Int64 = 3_000_000_000
        let chunks = await BigChunksScanner(sizeOf: stub([
            "Claude": 9_000_000_000, "Foo": big, "Movies": big - 1, "Linked": big, "Big.app": big, "Library": big]))
            .scan(ctx, findings: [hint, safe])
        #expect(chunks.map(\.displayName).count == 3)
        #expect(chunks.map(\.url.lastPathComponent) == ["Claude", "Big.app", "Movies"])
        #expect(chunks[0].cleanableSize == 2_000_000_000)
    }

    @Test func trashSizeNilWithoutFullDiskAccess() async throws {
        let t = try FixtureTree()
        try t.file("home/.Trash/x", bytes: 100_000)
        #expect(await trashSize(.test(root: t.root, hasFullDiskAccess: false)) == nil)
        let size = try #require(await trashSize(.test(root: t.root)))
        #expect(size >= 100_000)
    }

    @Test func trashSizeZeroWhenMissing() async throws {
        let t = try FixtureTree()
        #expect(await trashSize(.test(root: t.root)) == 0)
    }

    @Test func photosInfoPicksLargestLibrary() async throws {
        let t = try FixtureTree()
        try t.file("home/Pictures/Small.photoslibrary/x", bytes: 100)
        try t.file("home/Pictures/Big.photoslibrary/x", bytes: 500_000)
        try t.file("home/Pictures/Other/x", bytes: 900_000)
        let info = await photosInfo(.test(root: t.root))
        #expect(info?.libraryURL.lastPathComponent == "Big.photoslibrary")
        #expect((info?.librarySize ?? 0) >= 500_000)
        #expect(await photosInfo(.test(root: try FixtureTree().root)) == nil)
    }
}
