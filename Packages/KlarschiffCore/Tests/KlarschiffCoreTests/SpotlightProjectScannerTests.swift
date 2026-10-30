import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct SpotlightProjectScannerTests {
    static let big: Int64 = 150_000_000

    func ctx(_ tree: FixtureTree, fda: Bool = true) -> ScanContext {
        var c = ScanContext.test(hasFullDiskAccess: fda)
        c.home = tree.root
        return c
    }

    /// Jeder Ordner gilt als 150 MB, außer ausdrücklich anders angegeben.
    func scanner(sizes: [String: Int64] = [:]) -> SpotlightProjectScanner {
        SpotlightProjectScanner(sizeOf: { url in sizes[url.lastPathComponent] ?? Self.big })
    }

    func rel(_ cs: [SpotlightCandidate], _ tree: FixtureTree) -> [String] {
        cs.map { String($0.url.resolvingSymlinksInPath().path.dropFirst(tree.root.path.count + 1)) }.sorted()
    }

    @Test func findsPlainKinds() async throws {
        let tree = try FixtureTree()
        for k in ["node_modules", ".build", "Pods", ".venv", "venv", "__pycache__", "DerivedData", ".gradle"] {
            try tree.dir("proj/\(k)")
        }
        let r = await scanner().scan(ctx(tree))
        #expect(r.count == 8)
        #expect(Set(r.map(\.kind)) == ["node_modules", ".build", "Pods", ".venv", "venv", "__pycache__", "DerivedData", ".gradle"])
        #expect(r.allSatisfy { $0.id == $0.url.path && $0.size == Self.big })
    }

    @Test func targetNeedsCargoToml() async throws {
        let tree = try FixtureTree()
        try tree.dir("a/target")
        try tree.dir("b/target"); try tree.file("b/Cargo.toml", bytes: 1)
        let r = await scanner().scan(ctx(tree))
        #expect(rel(r, tree) == ["b/target"])
    }

    @Test func buildNeedsGradleOrCMake() async throws {
        let tree = try FixtureTree()
        try tree.dir("a/build")
        try tree.dir("b/build"); try tree.file("b/build.gradle", bytes: 1)
        try tree.dir("c/build"); try tree.file("c/CMakeLists.txt", bytes: 1)
        let r = await scanner().scan(ctx(tree))
        #expect(rel(r, tree) == ["b/build", "c/build"])
    }

    @Test func excludedFoldersAreSkipped() async throws {
        let tree = try FixtureTree()
        try tree.dir("a/node_modules"); try tree.file("a/node_modules/.metadata_never_index", bytes: 0)
        try tree.dir("b.noindex/node_modules")
        try tree.dir("c/node_modules")
        let r = await scanner().scan(ctx(tree))
        #expect(rel(r, tree) == ["c/node_modules"])
    }

    @Test func thresholdAndSorting() async throws {
        let tree = try FixtureTree()
        try tree.dir("a/node_modules"); try tree.dir("b/Pods"); try tree.dir("c/venv"); try tree.dir("d/DerivedData")
        let s = scanner(sizes: ["node_modules": 99_999_999, "Pods": 100_000_000, "venv": 900_000_000, "DerivedData": 200_000_000])
        let r = await s.scan(ctx(tree))
        #expect(r.map(\.kind) == ["venv", "DerivedData", "Pods"])
    }

    @Test func libraryAndTrashSkipped() async throws {
        let tree = try FixtureTree()
        try tree.dir("Library/x/node_modules")
        try tree.dir(".Trash/node_modules")
        try tree.dir("work/node_modules")
        let r = await scanner().scan(ctx(tree))
        #expect(rel(r, tree) == ["work/node_modules"])
    }

    @Test func nestedNodeModulesOnlyOutermost() async throws {
        let tree = try FixtureTree()
        try tree.dir("p/node_modules/dep/node_modules")
        let r = await scanner().scan(ctx(tree))
        #expect(rel(r, tree) == ["p/node_modules"])
    }

    @Test func symlinkNotFollowed() async throws {
        let tree = try FixtureTree()
        let outside = try FixtureTree()
        try outside.dir("real/node_modules")
        try tree.symlink("link", to: outside.root.appending(path: "real"))
        try tree.symlink("direct", to: outside.root.appending(path: "real/node_modules"))
        try tree.symlink("p/node_modules", to: outside.root.appending(path: "real/node_modules"))
        let r = await scanner().scan(ctx(tree))
        #expect(r.isEmpty)
    }

    @Test func hiddenDirsSkippedExceptTargets() async throws {
        let tree = try FixtureTree()
        try tree.dir(".hidden/node_modules")
        try tree.dir("p/.build")
        let r = await scanner().scan(ctx(tree))
        #expect(rel(r, tree) == ["p/.build"])
    }

    @Test func depthLimit() async throws {
        let tree = try FixtureTree()
        try tree.dir("a/b/c/d/e/node_modules")      // Tiefe 6
        try tree.dir("a/b/c/d/e/f/node_modules")    // Tiefe 7
        let r = await scanner().scan(ctx(tree))
        #expect(rel(r, tree) == ["a/b/c/d/e/node_modules"])
    }

    @Test func protectedFoldersSkippedWithoutFullDiskAccess() async throws {
        let tree = try FixtureTree()
        try tree.dir("Desktop/p/node_modules")
        try tree.dir("documents/p/node_modules")
        try tree.dir("Downloads/p/node_modules")
        try tree.dir("Code/p/node_modules")
        let without = await scanner().scan(ctx(tree, fda: false))
        #expect(rel(without, tree) == ["Code/p/node_modules"])
        let with = await scanner().scan(ctx(tree, fda: true))
        #expect(with.count == 4)
    }

    @Test func zeroTimeLimitReturnsQuickly() async throws {
        let tree = try FixtureTree()
        try tree.dir("p/node_modules")
        let r = await SpotlightProjectScanner(sizeOf: { _ in Self.big }, timeLimit: 0).scan(ctx(tree))
        #expect(r.isEmpty)
    }
}
