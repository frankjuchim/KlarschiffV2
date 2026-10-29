import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct CheckHistoryTests {
    func snap(_ i: Int) -> CheckSnapshot {
        CheckSnapshot(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60),
                      cleanableTotal: Int64(i), freeBytes: 1, totalBytes: 2,
                      sizes: ["a": Int64(i)], titles: ["a": "A"],
                      alerts: [.cleanable(total: Int64(i))])
    }

    @Test func historyPersistsAndCaps52() async throws {
        let t = try FixtureTree()
        let file = t.root.appending(path: "sub/history.json")
        let h = CheckHistory(fileURL: file)
        for i in 0..<60 { try await h.append(snap(i)) }
        let all = await CheckHistory(fileURL: file).all()
        #expect(all.count == 52)
        #expect(all.first == snap(59))
        #expect(all.last == snap(8))
        #expect(await h.latest() == snap(59))
    }

    @Test func corruptHistoryStartsEmpty() async throws {
        let t = try FixtureTree()
        let bad = t.root.appending(path: "bad.json")
        try Data("{not json".utf8).write(to: bad)
        let h = CheckHistory(fileURL: bad)
        #expect(await h.all().isEmpty)
        #expect(await h.latest() == nil)
        try await h.append(snap(1))
        #expect(await CheckHistory(fileURL: bad).all() == [snap(1)])
        #expect(await CheckHistory(fileURL: t.root.appending(path: "none.json")).all().isEmpty)
    }

    @Test func concurrentAppendsKeepValidFile() async throws {
        let t = try FixtureTree()
        let file = t.root.appending(path: "history.json")
        let a = CheckHistory(fileURL: file), b = CheckHistory(fileURL: file)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { try? await a.append(self.snap(i)) }
                group.addTask { try? await b.append(self.snap(100 + i)) }
            }
        }
        let data = try Data(contentsOf: file)
        let decoded = try JSONDecoder().decode([CheckSnapshot].self, from: data)
        #expect(decoded.count <= 52)
        #expect(!decoded.isEmpty)
    }
}
