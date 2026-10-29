import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct SimulatorScannerTests {
    private static let xcode = ("/usr/bin/xcode-select", ["-p"])
    private static let runtimeList = ("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])
    private static let unavailable = ("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"])

    private func fakeWithXcode() -> FakeCommandRunner {
        let fake = FakeCommandRunner()
        fake.stub(Self.xcode.0, Self.xcode.1, result: CommandResult(exitCode: 0, stdout: "/Applications/Xcode.app/Contents/Developer\n", stderr: ""))
        return fake
    }

    private func fakeWithRuntimes(_ json: String? = nil) -> FakeCommandRunner {
        let fake = fakeWithXcode()
        let result = json.map { CommandResult(exitCode: 0, stdout: $0, stderr: "") } ?? .fixture("simctl-runtime-list.json")
        fake.stub(Self.runtimeList.0, Self.runtimeList.1, result: result)
        return fake
    }

    @Test func runtimesWithNewestPerPlatformKept() async throws {
        let fs = try await SimulatorRuntimeScanner().scan(.test(runner: fakeWithRuntimes()))
        #expect(fs.count == 7)
        #expect(fs.filter(\.keepSuggested).map(\.title).sorted() == ["iOS 26.0 Simulator", "tvOS 18.0 Simulator", "visionOS 2.0 Simulator", "watchOS 11.0 Simulator"])
        #expect(fs.allSatisfy { $0.risk == .review && !$0.isPreselected(isKept: false) })
        #expect(fs.allSatisfy { $0.id.scannerID == "sim.runtimes" && $0.category == .simulators })
        let ios = fs.filter { $0.title.hasPrefix("iOS") }.compactMap(\.size).reduce(0, +)
        #expect(ios == 32_000_000_000)
    }

    @Test func runtimeFindingShape() async throws {
        let fs = try await SimulatorRuntimeScanner().scan(.test(runner: fakeWithRuntimes(), running: ["com.apple.iphonesimulator"]))
        let f = try #require(fs.first { $0.title == "iOS 18.2 Simulator" })
        let id = "AAAAAAAA-0000-0000-0000-000000000003"
        #expect(f.id.key == id)
        #expect(f.size == 8_000_000_000)
        #expect(f.items.count == 1 && f.items[0].id == id && f.items[0].detail == "Build 22C150" && f.items[0].size == 8_000_000_000)
        let cmd = ToolCommand(tool: "xcrun", arguments: ["simctl", "runtime", "delete", id], timeout: .seconds(600))
        #expect(f.method == .tool([cmd], fallback: nil))
        #expect(f.commandPreview == [cmd.display])
        #expect(!f.commandPreview.contains { $0.contains("#") })
        #expect(f.blockingApps == [AppRef(bundleID: "com.apple.iphonesimulator", processName: nil, displayName: "Simulator")])
        #expect(!f.keepSuggested)
        let idle = try await SimulatorRuntimeScanner().scan(.test(runner: fakeWithRuntimes()))
        #expect(idle.allSatisfy { $0.blockingApps.isEmpty })
    }

    @Test func noXcodeNoRuntimes() async throws {
        let fake = FakeCommandRunner()
        fake.stub(Self.xcode.0, Self.xcode.1, result: CommandResult(exitCode: 0, stdout: "/Library/Developer/CommandLineTools\n", stderr: ""))
        #expect(try await SimulatorRuntimeScanner().scan(.test(runner: fake)).isEmpty)
        #expect(try await UnavailableSimulatorsScanner().scan(.test(runner: fake)).isEmpty)
        #expect(!fake.calls.contains { $0.1.contains("simctl") })
    }

    @Test func deletingAndNonDeletableSkipped() async throws {
        let json = """
        {"A":{"identifier":"A","version":"18.0","build":"1","platformIdentifier":"com.apple.platform.iphonesimulator","sizeBytes":100,"state":"Ready","deletable":true},
         "B":{"identifier":"B","version":"19.0","build":"2","platformIdentifier":"com.apple.platform.iphonesimulator","sizeBytes":100,"state":"Ready","deletable":false},
         "C":{"identifier":"C","version":"20.0","build":"3","platformIdentifier":"com.apple.platform.iphonesimulator","sizeBytes":100,"state":"Deleting"},
         "D":{"identifier":"D","version":"1.0","build":"4","platformIdentifier":"com.apple.platform.realityossimulator","sizeBytes":100,"state":"Ready"}}
        """
        let fs = try await SimulatorRuntimeScanner().scan(.test(runner: fakeWithRuntimes(json)))
        #expect(fs.map(\.id.key).sorted() == ["A", "D"])
        #expect(fs.first { $0.id.key == "A" }?.keepSuggested == true)
        #expect(fs.first { $0.id.key == "D" }?.title == "realityossimulator 1.0 Simulator")
    }

    @Test func runtimeFailuresThrow() async throws {
        let fail = fakeWithXcode()
        fail.stub(Self.runtimeList.0, Self.runtimeList.1, result: CommandResult(exitCode: 1, stdout: "", stderr: "boom"))
        await #expect(throws: (any Error).self) { try await SimulatorRuntimeScanner().scan(.test(runner: fail)) }
        await #expect(throws: (any Error).self) { try await SimulatorRuntimeScanner().scan(.test(runner: fakeWithRuntimes("not json"))) }
    }

    @Test func unavailableDevicesSized() async throws {
        let tree = try FixtureTree()
        try tree.file("Devices/DEV-1/data/a.bin", bytes: 4096)
        try tree.file("Devices/DEV-2/data/b.bin", bytes: 8192)
        let template = try String(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/simctl-devices-unavailable.json"), encoding: .utf8)
        let json = template.replacingOccurrences(of: "@@ROOT@@", with: tree.root.path)
        let fake = fakeWithXcode()
        fake.stub(Self.unavailable.0, Self.unavailable.1, result: CommandResult(exitCode: 0, stdout: json, stderr: ""))
        let fs = try await UnavailableSimulatorsScanner().scan(.test(runner: fake))
        let f = try #require(fs.first)
        #expect(fs.count == 1 && f.id == FindingID(scannerID: "sim.unavailable", key: "all"))
        #expect(f.risk == .safe && f.category == .simulators)
        #expect(f.items.map(\.id).sorted() == ["DEV-1", "DEV-2"])
        #expect(f.items.map(\.name).sorted() == ["iPhone 15", "iPhone 15 Pro"])
        #expect(f.items.allSatisfy { ($0.size ?? 0) >= 4096 })
        #expect(f.size == f.items.compactMap(\.size).reduce(0, +))
        let cmd = ToolCommand(tool: "xcrun", arguments: ["simctl", "delete", "unavailable"], timeout: .seconds(120))
        #expect(f.method == .tool([cmd], fallback: nil))
        #expect(f.commandPreview == ["xcrun simctl delete unavailable"])
    }

    @Test func noUnavailableDevicesNoFinding() async throws {
        let fake = fakeWithXcode()
        fake.stub(Self.unavailable.0, Self.unavailable.1, result: CommandResult(exitCode: 0, stdout: "{\"devices\":{\"x\":[]}}", stderr: ""))
        #expect(try await UnavailableSimulatorsScanner().scan(.test(runner: fake)).isEmpty)
    }

    @Test func versionCompare() {
        #expect(VersionCompare.isNewer("18.2", than: "17.5"))
        #expect(VersionCompare.isNewer("26.0", than: "18.2"))
        #expect(VersionCompare.isNewer("3.12.0", than: "3.9.1"))
        #expect(!VersionCompare.isNewer("18.0", than: "18.0.0"))
        #expect(VersionCompare.isNewer("18.0.1", than: "18.0"))
        #expect(!VersionCompare.isNewer("v1.0", than: "v1.0"))
        #expect(!VersionCompare.isNewer("abc", than: "1.0"))
    }
}
