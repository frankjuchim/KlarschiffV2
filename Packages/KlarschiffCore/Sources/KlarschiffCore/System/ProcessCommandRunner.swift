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

        let outDrain = Drain(outPipe.fileHandleForReading)
        let errDrain = Drain(errPipe.fileHandleForReading)

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
        // Nachkommen können die Pipe-Enden offen halten: nur kurz auf EOF warten, dann abbrechen.
        await Self.waitForDrains([outDrain, errDrain], grace: .seconds(1))
        let out = outDrain.finish()
        let err = errDrain.finish()

        if timedOut.load(ordering: .sequentiallyConsistent) { throw CommandError.timeout }
        if Task.isCancelled { throw CancellationError() }
        return CommandResult(exitCode: status, stdout: out, stderr: err)
    }

    private static func waitForDrains(_ drains: [Drain], grace: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for d in drains { await d.waitForEOF() }
            }
            group.addTask { try? await Task.sleep(for: grace) }
            await group.next()
            group.cancelAll()
        }
    }
}

/// Liest eine Pipe über `readabilityHandler` (hält keinen Thread des Cooperative Pools).
private final class Drain: Sendable {
    private struct State { var data = Data(); var eof = false }
    private let handle: FileHandle
    private let state = Mutex(State())
    private let eofStream = AsyncStream<Void>.makeStream()

    init(_ handle: FileHandle) {
        self.handle = handle
        let continuation = eofStream.continuation
        handle.readabilityHandler = { [self] h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                state.withLock { $0.eof = true }
                continuation.yield()
                continuation.finish()
            } else {
                state.withLock { $0.data.append(chunk) }
            }
        }
    }

    func waitForEOF() async {
        for await _ in eofStream.stream { return }
    }

    /// Beendet das Lesen (falls noch offen), schließt das Handle und liefert den Text.
    func finish() -> String {
        handle.readabilityHandler = nil
        try? handle.close()
        eofStream.continuation.finish()
        return String(decoding: state.withLock { $0.data }, as: UTF8.self)
    }
}
