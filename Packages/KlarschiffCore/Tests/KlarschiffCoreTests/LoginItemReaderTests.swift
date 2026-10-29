import Testing
import Foundation
@testable import KlarschiffCore

struct LoginItemReaderTests {
    private func fixtureText() throws -> String {
        try String(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/sfltool-dumpbtm.txt"), encoding: .utf8)
    }

    @Test func parsesOnlyLoginItemsOfUID() throws {
        let items = LoginItemReader.parse(try fixtureText(), uid: 501)
        #expect(items.map(\.displayName) == ["Fensterdock", "StartHelfer", "TunnelHelfer", "Namenlos"])
        #expect(items.allSatisfy { $0.scope == .loginItem && !$0.isOrphaned && !$0.isOwnAgent && !$0.isRunning })
    }

    @Test func otherUIDsAreSeparate() throws {
        let text = try fixtureText()
        #expect(LoginItemReader.parse(text, uid: 502).map(\.displayName) == ["FremderHelfer"])
        #expect(LoginItemReader.parse(text, uid: 0).map(\.displayName) == ["RootHelfer"])
        #expect(LoginItemReader.parse(text, uid: 999).isEmpty)
    }

    @Test func dispositionDecidesStartKindAndNote() throws {
        let items = LoginItemReader.parse(try fixtureText(), uid: 501)
        let enabled = try #require(items.first { $0.displayName == "StartHelfer" })
        #expect(enabled.startKind == .atLogin)
        #expect(!enabled.explanation.contains("ausgeschaltet"))
        let off = try #require(items.first { $0.displayName == "TunnelHelfer" })
        #expect(off.startKind != .atLogin)
        #expect(off.explanation.contains("ausgeschaltet"))
    }

    @Test func nameFallbackViaParentThenURL() throws {
        let items = LoginItemReader.parse(try fixtureText(), uid: 501)
        #expect(items.first { $0.label == "4.com.beispiel.fensterdockLauncher" }?.displayName == "Fensterdock")
        #expect(items.first { $0.label == "4.com.beispiel.namenlos" }?.displayName == "Namenlos")
    }

    @Test func deduplicatesByIdentifier() throws {
        let items = LoginItemReader.parse(try fixtureText(), uid: 501)
        #expect(items.filter { $0.label == "4.com.beispiel.fensterdockLauncher" }.count == 1)
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func brokenFormatYieldsEmpty() {
        #expect(LoginItemReader.parse("", uid: 501).isEmpty)
        #expect(LoginItemReader.parse("kein sfltool\nRecords for UID\n Type: login item (0x4)\n", uid: 501).isEmpty)
    }

    @Test func readUsesSfltool() async throws {
        let fake = FakeCommandRunner()
        fake.stub("/usr/bin/sfltool", ["dumpbtm"], result: .fixture("sfltool-dumpbtm.txt"))
        let r = await LoginItemReader.read(runner: fake, uid: 501)
        #expect(!r.failed)
        #expect(r.items.count == 4)
    }

    @Test func timeoutOrErrorMeansFailed() async {
        let t = FakeCommandRunner()
        t.stubTimeout("/usr/bin/sfltool", ["dumpbtm"])
        let r1 = await LoginItemReader.read(runner: t, uid: 501)
        #expect(r1.failed && r1.items.isEmpty)
        let e = FakeCommandRunner()
        e.stub("/usr/bin/sfltool", ["dumpbtm"], result: CommandResult(exitCode: 1, stdout: "", stderr: "x"))
        let r2 = await LoginItemReader.read(runner: e, uid: 501)
        #expect(r2.failed && r2.items.isEmpty)
    }
}
