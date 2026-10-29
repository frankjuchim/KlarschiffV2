import Foundation

public enum AdminRunResult: Sendable, Equatable {
    /// Exit-Code je Schritt (-1 = nicht ausgeführt).
    case completed([Int32])
    case cancelled
    case failed(String)
}

public protocol PrivilegedExecutor: Sendable {
    func run(_ steps: [AdminStep]) async -> AdminRunResult
}
