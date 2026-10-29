import Testing
import Foundation
@testable import KlarschiffCore

@Suite struct AdminScriptBuilderTests {
    @Test func scriptQuotesHostilePaths() {
        let s = AdminScriptBuilder.script(for: [AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive/20 22'$(touch x)\""])], nonce: "N0")
        #expect(s == "/bin/rm -rf '/usr/local/texlive/20 22'\\''$(touch x)\"'; echo \"KS_STEP N0 0 $?\"")
    }

    @Test func scriptJoinsStepsWithNewline() {
        let s = AdminScriptBuilder.script(for: [
            AdminStep(executable: "/bin/rm", arguments: ["-rf", "/a"]),
            AdminStep(executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", "2026-01-01"]),
        ], nonce: "N0")
        #expect(s == "/bin/rm -rf /a; echo \"KS_STEP N0 0 $?\"\n/usr/bin/tmutil deletelocalsnapshots 2026-01-01; echo \"KS_STEP N0 1 $?\"")
    }

    @Test func parsesStepMarkers() {
        #expect(AdminScriptBuilder.parse("foo\nKS_STEP N0 0 0\nKS_STEP N0 1 1\n", stepCount: 2, nonce: "N0") == [0, 1])
        #expect(AdminScriptBuilder.parse("KS_STEP N0 0 0\n", stepCount: 2, nonce: "N0") == [0, -1])
    }

    @Test func parseRejectsWrongNonceAndJunk() {
        let out = "KS_STEP EVIL 0 0\rKS_STEP N0 1 3\rKS_STEP N0 9 0\rKS_STEP N0 x 1\rKS_STEP N0 1"
        #expect(AdminScriptBuilder.parse(out, stepCount: 2, nonce: "N0") == [-1, 3])
    }

    @Test func nonceIsRandom() {
        #expect(AdminScriptBuilder.makeNonce() != AdminScriptBuilder.makeNonce())
    }

    @Test func sourceEscapesHostilePath() {
        let script = AdminScriptBuilder.script(for: [AdminStep(executable: "/bin/rm", arguments: ["-rf", "/a'b\"c$d\\e\nf"])], nonce: "N0")
        let src = AppleScriptPrivilegedExecutor.source(for: script)
        #expect(src.hasPrefix("do shell script \"") && src.hasSuffix("\" with administrator privileges"))
        let inner = String(src.dropFirst("do shell script \"".count).dropLast("\" with administrator privileges".count))
        // Rückwärts entschärfen ergibt exakt das Skript.
        var out = ""; var it = inner.makeIterator()
        while let c = it.next() { if c == "\\" { out.append(it.next()!) } else { #expect(c != "\""); out.append(c) } }
        #expect(out == script)
    }

    private let steps = [AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive/2022"])]

    @Test func executorSuccessCancelFailure() async throws {
        // Nonce ist zufällig: stdout echot den Marker aus dem übergebenen Skript.
        let exOK = AppleScriptPrivilegedExecutor(runner: EchoOsascript())
        #expect(await exOK.run(steps) == .completed([0]))
        let c = StubOsascript(CommandResult(exitCode: 1, stdout: "", stderr: "execution error: User canceled. (-128)"))
        #expect(await AppleScriptPrivilegedExecutor(runner: c).run(steps) == .cancelled)
        let f = StubOsascript(CommandResult(exitCode: 1, stdout: "", stderr: "boom"))
        #expect(await AppleScriptPrivilegedExecutor(runner: f).run(steps) == .failed("boom"))
        #expect(c.last?.0 == "/usr/bin/osascript")
        #expect(c.last?.1.first == "-e")
    }
}

private final class StubOsascript: CommandRunner, @unchecked Sendable {
    let result: CommandResult
    nonisolated(unsafe) var last: (String, [String])?
    init(_ r: CommandResult) { result = r }
    func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]) async throws -> CommandResult {
        last = (executable, arguments); return result
    }
}

/// Liefert als stdout den Marker, den das übergebene Skript ausgeben würde (Exit 0).
private struct EchoOsascript: CommandRunner {
    func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]) async throws -> CommandResult {
        let src = arguments[1]
        let re = try NSRegularExpression(pattern: "KS_STEP ([0-9A-F]+) 0")
        let m = re.firstMatch(in: src, range: NSRange(src.startIndex..., in: src))!
        let nonce = String(src[Range(m.range(at: 1), in: src)!])
        return CommandResult(exitCode: 0, stdout: "KS_STEP \(nonce) 0 0\n", stderr: "")
    }
}

@Suite struct AppleScriptEscapeTests {
    @Test func appleScriptStringEscapes() {
        #expect(AppleScriptPrivilegedExecutor.appleScriptString("a\"b\\c") == "\"a\\\"b\\\\c\"")
    }
}
