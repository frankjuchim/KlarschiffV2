import Foundation

public enum ScannerPhase: Int, Sendable {
    case specific = 0
    case collector = 1
}

public protocol Scanner: Sendable {
    var id: String { get }
    var phase: ScannerPhase { get }
    func scan(_ ctx: ScanContext) async throws -> [Finding]
}

public extension Scanner {
    var phase: ScannerPhase { .specific }
}
