import Foundation

public struct TrashRemover: Remover {
    private let safety: SafetyGuard

    private let onTrashed: (@Sendable (URL) -> Void)?

    public init(guard safety: SafetyGuard) { self.safety = safety; onTrashed = nil }

    /// Test-Hook: meldet die Ziel-URL im Papierkorb.
    init(guard safety: SafetyGuard, onTrashed: @escaping @Sendable (URL) -> Void) {
        self.safety = safety
        self.onTrashed = onTrashed
    }

    public func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] {
        removePathItems(finding, items: items, dryRun: dryRun, guard: safety) { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let r = result as URL? { onTrashed?(r) }
        }
    }
}
