import Foundation
import Synchronization
@testable import KlarschiffCore

/// Test-Attrappe: protokolliert die erhaltenen Schritte und liefert ein festes Ergebnis.
final class FakeExecutor: PrivilegedExecutor {
    private let state = Mutex<[[AdminStep]]>([])
    private let result: @Sendable (Int) -> AdminRunResult

    init(_ result: @escaping @Sendable (Int) -> AdminRunResult) { self.result = result }
    convenience init(fixed: AdminRunResult) { self.init { _ in fixed } }

    var runs: [[AdminStep]] { state.withLock { $0 } }

    func run(_ steps: [AdminStep]) async -> AdminRunResult {
        state.withLock { $0.append(steps) }
        return result(steps.count)
    }
}
