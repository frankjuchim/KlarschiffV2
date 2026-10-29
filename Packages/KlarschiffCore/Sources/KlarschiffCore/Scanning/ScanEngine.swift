import Foundation
import Synchronization

public struct ScanFailure: Error, Sendable {
    public var scannerID: String
    public var message: String

    public init(scannerID: String, message: String) {
        self.scannerID = scannerID
        self.message = message
    }
}

public struct ScanReport: Sendable {
    public var findings: [Finding]
    public var failures: [ScanFailure]

    public init(findings: [Finding], failures: [ScanFailure]) {
        self.findings = findings
        self.failures = failures
    }
}

public struct ScanEngine: Sendable {
    private let scanners: [any Scanner]
    private let perScannerTimeout: Duration

    public init(scanners: [any Scanner], perScannerTimeout: Duration = .seconds(180)) {
        self.scanners = scanners
        self.perScannerTimeout = perScannerTimeout
    }

    public func run(_ ctx: ScanContext, progress: @Sendable (Int, Int) -> Void) async -> ScanReport {
        let total = scanners.count
        var completed = 0
        var findings: [Finding] = []
        var failures: [ScanFailure] = []

        for phase in [ScannerPhase.specific, .collector] {
            let batch = scanners.filter { $0.phase == phase }
            let timeout = perScannerTimeout
            var results: [(Int, Result<[Finding], ScanFailure>)] = []
            await withTaskGroup(of: (Int, Result<[Finding], ScanFailure>).self) { group in
                for (i, scanner) in batch.enumerated() {
                    group.addTask { (i, await Self.runOne(scanner, ctx, timeout)) }
                }
                for await r in group {
                    results.append(r)
                    completed += 1
                    progress(completed, total)
                }
            }
            var phaseFindings: [Finding] = []
            for (_, result) in results.sorted(by: { $0.0 < $1.0 }) {
                switch result {
                case .success(let fs):
                    phaseFindings += fs.filter { $0.size != 0 || !$0.items.isEmpty || $0.risk == .hintOnly }
                case .failure(let f):
                    failures.append(f)
                }
            }
            if phase == .specific {
                await ctx.claims.claim(phaseFindings.flatMap(\.items).compactMap(\.url))
            }
            findings += phaseFindings
        }
        return ScanReport(findings: findings, failures: failures)
    }

    /// Rennt Scanner gegen Timeout; kehrt nach Ablauf oder Abbruch auch zurück, wenn der Scanner Cancellation ignoriert.
    private static func runOne(_ scanner: any Scanner, _ ctx: ScanContext, _ timeout: Duration) async -> Result<[Finding], ScanFailure> {
        let id = scanner.id
        let gate = Gate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result<[Finding], ScanFailure>, Never>) in
                let scanTask = Task {
                    do {
                        gate.finish(.success(try await scanner.scan(ctx)))
                    } catch {
                        gate.finish(.failure(ScanFailure(scannerID: id, message: error.localizedDescription)))
                    }
                }
                let timer = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    let c = timeout.components
                    let secs = c.seconds + (c.attoseconds > 0 ? 1 : 0)
                    gate.finish(.failure(ScanFailure(scannerID: id, message: "Zeitüberschreitung nach \(max(1, secs)) s")))
                }
                gate.attach(cont: cont, scanTask: scanTask, timer: timer)
            }
        } onCancel: {
            gate.finish(.failure(ScanFailure(scannerID: id, message: "Abgebrochen")))
        }
    }
}

/// Löst die Continuation genau einmal auf; räumt die jeweils andere Task ab.
private final class Gate: Sendable {
    typealias Cont = CheckedContinuation<Result<[Finding], ScanFailure>, Never>
    private struct State {
        var cont: Cont?
        var scanTask: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var result: Result<[Finding], ScanFailure>?
        var done = false
    }
    private let state = Mutex(State())

    /// Registriert Continuation und Tasks; war das Ergebnis schon da (z. B. Abbruch vorab), wird sofort aufgelöst.
    func attach(cont: Cont, scanTask: Task<Void, Never>, timer: Task<Void, Never>) {
        let early = state.withLock { s -> Result<[Finding], ScanFailure>? in
            if s.done {
                let r = s.result
                s.result = nil
                return r
            }
            s.cont = cont
            s.scanTask = scanTask
            s.timer = timer
            return nil
        }
        if let early {
            timer.cancel()
            scanTask.cancel()
            cont.resume(returning: early)
        }
    }

    func finish(_ result: Result<[Finding], ScanFailure>) {
        let (cont, scanTask, timer) = state.withLock { s -> (Cont?, Task<Void, Never>?, Task<Void, Never>?) in
            if s.done { return (nil, nil, nil) }
            s.done = true
            let out = (s.cont, s.scanTask, s.timer)
            s.cont = nil
            s.scanTask = nil
            s.timer = nil
            if out.0 == nil { s.result = result }
            return out
        }
        timer?.cancel()
        scanTask?.cancel()
        cont?.resume(returning: result)
    }
}
