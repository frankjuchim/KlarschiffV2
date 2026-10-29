import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct SnapshotScannerTests {
    @Test func parsesUpdateAndTimeMachineSnapshots() async throws {
        let fake = FakeCommandRunner()
        fake.stub("/usr/bin/tmutil", ["listlocalsnapshots", "/"], result: .fixture("tmutil-listlocalsnapshots.txt"))
        let fs = try await SnapshotScanner().scan(.test(runner: fake))
        let upd = try #require(fs.first { $0.id.key == "update" })
        #expect(upd.risk == .hintOnly && upd.size == nil && upd.items.count == 2)
        #expect(upd.id.scannerID == "system.snapshots")
        #expect(upd.commandPreview.isEmpty)
        let tm = try #require(fs.first { $0.id.key == "timeMachine" })
        #expect(tm.method == .admin([AdminStep(executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", "2026-10-27-101500"])]))
        #expect(tm.risk == .review && tm.size == nil && tm.items.count == 1)
        #expect(tm.items[0].id == "com.apple.TimeMachine.2026-10-27-101500.local")
        #expect(tm.commandPreview == ["sudo /usr/bin/tmutil deletelocalsnapshots 2026-10-27-101500"])
    }

    @Test func noSnapshotsNoFinding() async throws {
        let fake = FakeCommandRunner()
        fake.stub("/usr/bin/tmutil", ["listlocalsnapshots", "/"], result: .fixture("tmutil-listlocalsnapshots-empty.txt"))
        let fs = try await SnapshotScanner().scan(.test(runner: fake))
        #expect(fs.isEmpty)
    }

    @Test func tmutilFailureThrows() async throws {
        let fake = FakeCommandRunner()
        fake.stub("/usr/bin/tmutil", ["listlocalsnapshots", "/"], result: CommandResult(exitCode: 1, stdout: "", stderr: "boom"))
        await #expect(throws: (any Error).self) { try await SnapshotScanner().scan(.test(runner: fake)) }
    }

    @Test func softwareUpdateParsedOnlyWithSlowChecks() async throws {
        let fake = FakeCommandRunner()
        fake.stub("/usr/sbin/softwareupdate", ["-l"], result: .fixture("softwareupdate-l.txt"))
        let skipped = try await SoftwareUpdateScanner().scan(.test(runner: fake))
        #expect(skipped.isEmpty)
        #expect(fake.calls.isEmpty)
        let fs = try await SoftwareUpdateScanner().scan(.test(runner: fake, includeSlowChecks: true))
        let f = try #require(fs.first)
        #expect(f.id == FindingID(scannerID: "system.softwareupdate", key: "pending"))
        #expect(f.risk == .hintOnly && f.size == nil && f.commandPreview.isEmpty)
        #expect(f.items.map(\.name) == ["macOS Tahoe 26.1", "Safari"])
        #expect(f.method == .hint(.openURL(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)))
    }

    @Test func softwareUpdateNoneNoFinding() async throws {
        let fake = FakeCommandRunner()
        fake.stub("/usr/sbin/softwareupdate", ["-l"], result: .fixture("softwareupdate-l-none.txt"))
        #expect(try await SoftwareUpdateScanner().scan(.test(runner: fake, includeSlowChecks: true)).isEmpty)
    }

    @Test func softwareUpdateFailureThrows() async throws {
        let fake = FakeCommandRunner()
        await #expect(throws: (any Error).self) { try await SoftwareUpdateScanner().scan(.test(runner: fake, includeSlowChecks: true)) }
    }
}
