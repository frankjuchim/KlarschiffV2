import Foundation

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Equatable, Sendable {
    case timeout
    case launchFailed(String)
}

public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]) async throws -> CommandResult
}

public extension CommandRunner {
    func run(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(30)) async throws -> CommandResult {
        try await run(executable, arguments, timeout: timeout, environment: [:])
    }
}
