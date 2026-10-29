import Testing
import Foundation
@testable import KlarschiffCore

struct SizeMeterTests {
    @Test func sumsAllocatedSize() async throws {
        let t = try FixtureTree(); try t.file("a/x.bin", bytes: 1_000_000); try t.file("a/b/y.bin", bytes: 2_000_000)
        let s = try await SizeMeter().size(of: t.root.appending(path: "a"))
        #expect(s >= 3_000_000 && s < 3_200_000)
    }

    @Test func hardLinksCountedOnce() async throws {
        let t = try FixtureTree(); let f = try t.file("a/x.bin", bytes: 1_000_000); try t.hardlink("a/y.bin", to: f)
        #expect(try await SizeMeter().size(of: t.root.appending(path: "a")) < 1_100_000)
    }

    @Test func symlinksNotFollowed() async throws {
        let t = try FixtureTree(); let big = try t.file("outside/big.bin", bytes: 5_000_000)
        try t.dir("a"); try t.symlink("a/link", to: big.deletingLastPathComponent())
        #expect(try await SizeMeter().size(of: t.root.appending(path: "a")) < 100_000)
    }

    @Test func symlinkItselfNotFollowed() async throws {
        let t = try FixtureTree(); let big = try t.file("outside/big.bin", bytes: 5_000_000)
        try t.symlink("link", to: big)
        #expect(try await SizeMeter().size(of: t.root.appending(path: "link")) < 100_000)
    }

    @Test func regularFileReturnsAllocatedSize() async throws {
        let t = try FixtureTree(); let f = try t.file("x.bin", bytes: 1_000_000)
        let s = try await SizeMeter().size(of: f)
        #expect(s >= 1_000_000 && s < 1_100_000)
    }

    @Test func missingPathIsZero() async throws {
        #expect(try await SizeMeter().size(of: URL(filePath: "/nonexistent/klarschiff")) == 0)
    }

    @Test func sizesMeasuresEachRoot() async throws {
        let t = try FixtureTree(); try t.file("a/x.bin", bytes: 1_000_000); try t.file("b/y.bin", bytes: 2_000_000)
        let a = t.root.appending(path: "a"), b = t.root.appending(path: "b"), m = URL(filePath: "/nonexistent/k")
        let r = try await SizeMeter().sizes(of: [a, b, m])
        #expect(r.count == 3)
        #expect(r[a]! >= 1_000_000 && r[b]! >= 2_000_000 && r[m] == 0)
    }
}

@Suite struct SizeMeterMeasureTests {
    @Test func measureReportsCompleteForReadableTree() async throws {
        let tree = try FixtureTree()
        try tree.file("a/f", bytes: 5000)
        let r = try await SizeMeter().measure(tree.root.appending(path: "a"))
        #expect(r.complete)
        #expect(r.size == (try await SizeMeter().size(of: tree.root.appending(path: "a"))))
    }

    @Test func measureFlagsUnreadableSubfolder() async throws {
        let tree = try FixtureTree()
        try tree.file("a/locked/f", bytes: 5000)
        let locked = tree.root.appending(path: "a/locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let r = try await SizeMeter().measure(tree.root.appending(path: "a"))
        #expect(!r.complete)
    }
}

@Suite struct SizeMeterDeniedTests {
    @Test func unreadableParentIsIncompleteNotExactZero() async throws {
        let tree = try FixtureTree()
        try tree.file("a/b/f", bytes: 100)
        let a = tree.root.appending(path: "a")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: a.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: a.path) }
        let r = try await SizeMeter().measure(a.appending(path: "b"))
        #expect(!r.complete)
        let missing = try await SizeMeter().measure(tree.root.appending(path: "nope"))
        #expect(missing.complete && missing.size == 0)
    }
}
