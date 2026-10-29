import Testing
import Foundation
@testable import KlarschiffCore

struct ToolLocatorTests {
    @Test func locatorPrefersFirstSearchPath() {
        let l = ToolLocator(searchPaths: ["/a", "/b"], fileExists: { $0 == "/b/brew" || $0 == "/a/brew" })
        #expect(l.path(for: "brew") == "/a/brew"); #expect(l.path(for: "conda") == nil)
    }

    @Test func defaultSearchPathsExpandTilde() {
        #expect(!ToolLocator.defaultSearchPaths.contains { $0.hasPrefix("~") })
        #expect(ToolLocator.defaultSearchPaths.first == "/opt/homebrew/bin")
    }

    @Test func brewEnvironmentValues() {
        #expect(ToolLocator.brewEnvironment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(ToolLocator.brewEnvironment.count == 3)
    }

    @Test func xcrunUnavailableWithOnlyCommandLineTools() async {
        let fake = FakeCommandRunner()
        fake.stub("/usr/bin/xcode-select", ["-p"], result: .init(exitCode: 0, stdout: "/Library/Developer/CommandLineTools\n", stderr: ""))
        #expect(await ToolLocator.xcrunAvailable(runner: fake) == false)
    }

    @Test func xcrunAvailableWithXcode() async {
        let fake = FakeCommandRunner()
        fake.stub("/usr/bin/xcode-select", ["-p"], result: .init(exitCode: 0, stdout: "/Applications/Xcode.app/Contents/Developer\n", stderr: ""))
        #expect(await ToolLocator.xcrunAvailable(runner: fake) == true)
    }

    @Test func xcrunUnavailableOnFailureOrTimeout() async {
        let fake = FakeCommandRunner()
        #expect(await ToolLocator.xcrunAvailable(runner: fake) == false)
        fake.stubTimeout("/usr/bin/xcode-select", ["-p"])
        #expect(await ToolLocator.xcrunAvailable(runner: fake) == false)
    }
}
