import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct AdminScriptBuilderTests {
    @Test func scriptQuotesHostilePaths() {
        let s = AdminScriptBuilder.script(for: [AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive/20 22'$(touch x)\""])])
        #expect(s == "/bin/rm -rf '/usr/local/texlive/20 22'\\''$(touch x)\"'; echo \"KS_STEP 0 $?\"")
    }

    @Test func scriptJoinsStepsWithNewline() {
        let s = AdminScriptBuilder.script(for: [
            AdminStep(executable: "/bin/rm", arguments: ["-rf", "/a"]),
            AdminStep(executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", "2026-01-01"]),
        ])
        #expect(s == "/bin/rm -rf /a; echo \"KS_STEP 0 $?\"\n/usr/bin/tmutil deletelocalsnapshots 2026-01-01; echo \"KS_STEP 1 $?\"")
    }

    @Test func parsesStepMarkers() {
        #expect(AdminScriptBuilder.parse("foo\nKS_STEP 0 0\nKS_STEP 1 1\n", stepCount: 2) == [0, 1])
        #expect(AdminScriptBuilder.parse("KS_STEP 0 0\n", stepCount: 2) == [0, -1])
    }

    @Test func parseHandlesCarriageReturnsAndIgnoresJunk() {
        #expect(AdminScriptBuilder.parse("KS_STEP 0 0\rKS_STEP 1 3\rKS_STEP 9 0\rKS_STEP x 1\rKS_STEP 1", stepCount: 2) == [0, 3])
    }

    @Test func appleScriptStringEscapes() {
        #expect(AppleScriptPrivilegedExecutor.appleScriptString("a\"b\\c") == "\"a\\\"b\\\\c\"")
    }
}
