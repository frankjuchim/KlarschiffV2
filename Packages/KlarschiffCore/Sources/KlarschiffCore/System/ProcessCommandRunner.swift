import Foundation
import Synchronization
import os

/// Führt Programme über `Process` aus. Stdout/Stderr werden nebenläufig gelesen,
/// damit große Ausgaben nicht blockieren.
public struct ProcessCommandRunner: CommandRunner {
    private static let logger = Logger(subsystem: "de.frankjuchim.klarschiff2", category: "command")

    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let timedOut = Atomic<Bool>(false)
        Self.logger.debug("run \(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)")

        // Exit-Beobachtung: Continuation wird genau einmal von terminationHandler fortgesetzt.
        let exitStream = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { p in
            exitStream.continuation.yield(p.terminationStatus)
            exitStream.continuation.finish()
        }
        do {
            try process.run()
        } catch {
            Self.logger.error("launch failed: \(error.localizedDescription, privacy: .public)")
            throw CommandError.launchFailed(error.localizedDescription)
        }
        let pid = process.processIdentifier

        async let outData = Self.readAll(outPipe.fileHandleForReading)
        async let errData = Self.readAll(errPipe.fileHandleForReading)

        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            timedOut.store(true, ordering: .sequentiallyConsistent)
            Self.logger.error("timeout, terminating pid \(pid)")
            process.terminate()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if process.isRunning { kill(pid, SIGKILL) }
        }

        let status: Int32 = await withTaskCancellationHandler {
            var s: Int32 = -1
            for await v in exitStream.stream { s = v }
            return s
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        watchdog.cancel()
        let out = await outData
        let err = await errData

        if timedOut.load(ordering: .sequentiallyConsistent) { throw CommandError.timeout }
        if Task.isCancelled { throw CancellationError() }
        return CommandResult(exitCode: status, stdout: out, stderr: err)
    }

    private static func readAll(_ handle: FileHandle) async -> String {
        await Task.detached {
            let data = (try? handle.readToEnd()) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
