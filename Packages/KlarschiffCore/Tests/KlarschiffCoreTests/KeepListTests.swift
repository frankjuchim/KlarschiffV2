import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct KeepListTests {
    @Test func keepListPersists() async throws {
        let t = try FixtureTree()
        let file = t.root.appending(path: "keep.json")
        let id = FindingID(scannerID: "brew.cask", key: "mitmproxy")
        try await KeepList(fileURL: file).add(id)
        #expect(await KeepList(fileURL: file).contains(id))
    }

    @Test func removeAndAll() async throws {
        let t = try FixtureTree()
        let file = t.root.appending(path: "sub/dir/keep.json")
        let a = FindingID(scannerID: "a", key: "1"), b = FindingID(scannerID: "b", key: "2")
        let list = KeepList(fileURL: file)
        try await list.add(a); try await list.add(b); try await list.add(a)
        #expect(await list.all == [a, b])
        try await list.remove(a)
        #expect(await KeepList(fileURL: file).all == [b])
    }

    @Test func missingOrCorruptFileIsEmpty() async throws {
        let t = try FixtureTree()
        #expect(await KeepList(fileURL: t.root.appending(path: "none.json")).all.isEmpty)
        let bad = t.root.appending(path: "bad.json")
        try Data("{not json".utf8).write(to: bad)
        let list = KeepList(fileURL: bad)
        #expect(await list.all.isEmpty)
        let id = FindingID(scannerID: "x", key: "y")
        try await list.add(id)
        #expect(await KeepList(fileURL: bad).contains(id))
    }

    @Test func defaultFileURL() {
        let u = KeepList.defaultFileURL(home: URL(filePath: "/Users/test"))
        #expect(u.path == "/Users/test/Library/Application Support/Klarschiff2/keep.json")
    }
}
