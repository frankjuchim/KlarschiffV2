import Foundation
import Testing
@testable import KlarschiffCore

private func fixtureData(_ name: String) -> Data {
    let url = Bundle.module.resourceURL!.appending(path: "Fixtures").appending(path: name)
    return try! Data(contentsOf: url)
}

@Suite struct VolumeInventoryTests {
    @Test func parsesRecordedMac() throws {
        let r = try VolumeInventory.parse(fixtureData("diskutil-apfs-list.plist"))
        let roles = Set(r.volumes.map(\.role))
        #expect(roles.isSuperset(of: [.system, .preboot, .recovery, .vm, .data]))
        let data = try #require(r.volumes.first { $0.role == .data })
        #expect(data.consumed > 0)
        #expect(r.containerSize > r.containerFree)
        #expect(r.containerSize == 494384795648)
        #expect(r.containerFree == 218001747968)
        #expect(r.volumes.count == 6)
        let sim = try #require(r.simulatorVolumes.first)
        #expect(sim.name.hasSuffix("Simulator") && sim.role == .simulator)
        #expect(r.simulatorVolumes.count == 1)
    }

    @Test func failsOnGarbage() {
        #expect(throws: (any Error).self) { try VolumeInventory.parse(Data("x".utf8)) }
    }

    @Test func failsWithoutDataVolume() {
        let plist = #"<?xml version="1.0"?><plist version="1.0"><dict><key>Containers</key><array/></dict></plist>"#
        #expect(throws: (any Error).self) { try VolumeInventory.parse(Data(plist.utf8)) }
    }

    @Test func readUsesDiskutilAndParses() async throws {
        let fake = FakeCommandRunner()
        let text = try String(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/diskutil-apfs-list.plist"), encoding: .utf8)
        fake.stub("/usr/sbin/diskutil", ["apfs", "list", "-plist"], result: CommandResult(exitCode: 0, stdout: text, stderr: ""))
        let r = try await VolumeInventory.read(runner: fake)
        #expect(r.volumes.contains { $0.role == .data })
    }

    @Test func readThrowsOnNonZeroExit() async {
        let fake = FakeCommandRunner()
        fake.stub("/usr/sbin/diskutil", ["apfs", "list", "-plist"], result: CommandResult(exitCode: 1, stdout: "", stderr: "boom"))
        await #expect(throws: (any Error).self) { try await VolumeInventory.read(runner: fake) }
    }
}
