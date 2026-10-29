import Foundation

/// Führt das Admin-Skript per `osascript` aus (Passwortdialog, kein Blockieren des Main Threads).
public struct AppleScriptPrivilegedExecutor: PrivilegedExecutor {
    private let runner: CommandRunner

    public init(runner: CommandRunner = ProcessCommandRunner()) { self.runner = runner }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func source(for script: String) -> String {
        "do shell script \(appleScriptString(script)) with administrator privileges"
    }

    public func run(_ steps: [AdminStep]) async -> AdminRunResult {
        let nonce = AdminScriptBuilder.makeNonce()
        let source = Self.source(for: AdminScriptBuilder.script(for: steps, nonce: nonce))
        do {
            let r = try await runner.run("/usr/bin/osascript", ["-e", source], timeout: .seconds(3600), environment: [:])
            if r.stderr.contains("(-128)") { return .cancelled }
            if r.exitCode != 0 {
                let msg = RemovalText.shorten(r.stderr)
                return .failed(msg.isEmpty ? "Exit \(r.exitCode)" : msg)
            }
            return .completed(AdminScriptBuilder.parse(r.stdout, stepCount: steps.count, nonce: nonce))
        } catch CommandError.timeout {
            return .failed("Zeitüberschreitung")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
