import Foundation

public enum ScannerPhase: Int, Sendable {
    case specific = 0
    case collector = 1
    /// Sammler, die nach den übrigen Sammlern laufen (z. B. Caches nach den Resten gelöschter Apps).
    case lateCollector = 2
}

public protocol Scanner: Sendable {
    var id: String { get }
    var phase: ScannerPhase { get }
    func scan(_ ctx: ScanContext) async throws -> [Finding]
}

public extension Scanner {
    var phase: ScannerPhase { .specific }
}
