import Foundation
import Synchronization
@testable import KlarschiffCore

/// Test-Attrappe: liefert vorab hinterlegte Ausgaben, protokolliert alle Aufrufe.
final class FakeCommandRunner: CommandRunner {
    private struct Key: Hashable { let executable: String; let arguments: [String] }
    private enum Stub { case result(CommandResult), timeout }
    private struct State {
        var stubs: [Key: Stub] = [:]
        var calls: [(String, [String])] = []
        var environments: [[String: String]] = []
    }
    private let state = Mutex(State())

    var calls: [(String, [String])] { state.withLock { $0.calls } }
    var environments: [[String: String]] { state.withLock { $0.environments } }

    func stub(_ executable: String, _ arguments: [String], result: CommandResult) {
        state.withLock { $0.stubs[Key(executable: executable, arguments: arguments)] = .result(result) }
    }

    func stubTimeout(_ executable: String, _ arguments: [String]) {
        state.withLock { $0.stubs[Key(executable: executable, arguments: arguments)] = .timeout }
    }

    func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]) async throws -> CommandResult {
        let stub = state.withLock { s -> Stub? in
            s.calls.append((executable, arguments))
            s.environments.append(environment)
            return s.stubs[Key(executable: executable, arguments: arguments)]
        }
        switch stub {
        case .result(let r): return r
        case .timeout: throw CommandError.timeout
        case nil: return CommandResult(exitCode: 127, stdout: "", stderr: "not stubbed: \(executable) \(arguments.joined(separator: " "))")
        }
    }
}
