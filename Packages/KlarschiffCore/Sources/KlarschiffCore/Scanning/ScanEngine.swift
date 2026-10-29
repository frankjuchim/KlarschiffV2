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

    /// Rennt Scanner gegen Timeout; kehrt nach Ablauf auch zurück, wenn der Scanner Cancellation ignoriert.
    private static func runOne(_ scanner: any Scanner, _ ctx: ScanContext, _ timeout: Duration) async -> Result<[Finding], ScanFailure> {
        let id = scanner.id
        return await withCheckedContinuation { cont in
            let gate = Gate(cont)
            let scanTask = Task {
                do {
                    gate.finish(.success(try await scanner.scan(ctx)))
                } catch {
                    gate.finish(.failure(ScanFailure(scannerID: id, message: error.localizedDescription)))
                }
            }
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                let secs = timeout.components.seconds
                gate.finish(.failure(ScanFailure(scannerID: id, message: "Zeitüberschreitung nach \(secs) s")))
            }
            gate.attach(scanTask: scanTask, timer: timer)
        }
    }
}

/// Löst die Continuation genau einmal auf; räumt die jeweils andere Task ab.
private final class Gate: Sendable {
    private struct State {
        var cont: CheckedContinuation<Result<[Finding], ScanFailure>, Never>?
        var scanTask: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var done = false
    }
    private let state: Mutex<State>

    init(_ cont: CheckedContinuation<Result<[Finding], ScanFailure>, Never>) {
        state = Mutex(State(cont: cont))
    }

    func attach(scanTask: Task<Void, Never>, timer: Task<Void, Never>) {
        let alreadyDone = state.withLock { s -> Bool in
            s.scanTask = scanTask
            s.timer = timer
            return s.done
        }
        if alreadyDone { timer.cancel() }
    }

    func finish(_ result: Result<[Finding], ScanFailure>) {
        let (cont, scanTask, timer) = state.withLock { s -> (CheckedContinuation<Result<[Finding], ScanFailure>, Never>?, Task<Void, Never>?, Task<Void, Never>?) in
            if s.done { return (nil, nil, nil) }
            s.done = true
            defer { s.cont = nil }
            return (s.cont, s.scanTask, s.timer)
        }
        guard let cont else { return }
        timer?.cancel()
        scanTask?.cancel()
        cont.resume(returning: result)
    }
}
