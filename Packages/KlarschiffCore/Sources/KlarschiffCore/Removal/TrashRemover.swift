import Foundation

public struct TrashRemover: Remover {
    private let safety: SafetyGuard

    public init(guard safety: SafetyGuard) { self.safety = safety }

    public func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] {
        removePathItems(finding, items: items, dryRun: dryRun, guard: safety) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }
}
