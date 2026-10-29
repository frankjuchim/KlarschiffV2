import Testing
import Foundation
@testable import KlarschiffCore

struct CommandRunnerTests {
    @Test func runsProcessAndCapturesOutput() async throws {
        let r = try await ProcessCommandRunner().run("/bin/echo", ["hallo welt"], timeout: .seconds(5), environment: [:])
        #expect(r.succeeded); #expect(r.stdout == "hallo welt\n")
    }

    @Test func timesOut() async {
        await #expect(throws: CommandError.timeout) {
            try await ProcessCommandRunner().run("/bin/sleep", ["5"], timeout: .milliseconds(200), environment: [:])
        }
    }

    @Test func launchFailure() async {
        await #expect(throws: CommandError.self) {
            try await ProcessCommandRunner().run("/nonexistent/tool", [], timeout: .seconds(2), environment: [:])
        }
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let r = try await ProcessCommandRunner().run("/usr/bin/head", ["-c", "3000000", "/dev/zero"], timeout: .seconds(10), environment: [:])
        #expect(r.succeeded); #expect(r.stdout.utf8.count == 3_000_000)
    }

    @Test func environmentIsMerged() async throws {
        let r = try await ProcessCommandRunner().run("/usr/bin/env", [], timeout: .seconds(5), environment: ["KS_TEST": "1"])
        #expect(r.stdout.contains("KS_TEST=1")); #expect(r.stdout.contains("PATH="))
    }

    @Test func nonZeroExit() async throws {
        let r = try await ProcessCommandRunner().run("/usr/bin/false", [], timeout: .seconds(5), environment: [:])
        #expect(!r.succeeded)
    }
}
