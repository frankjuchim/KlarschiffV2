import Foundation

public enum ItemOutcome: Sendable, Equatable {
    case removed(freed: Int64?)
    case skipped(String)
    case failed(String)
    case cancelled
}

public struct ItemResult: Sendable {
    public var findingID: FindingID
    public var itemID: String?
    public var outcome: ItemOutcome

    public init(findingID: FindingID, itemID: String?, outcome: ItemOutcome) {
        self.findingID = findingID
        self.itemID = itemID
        self.outcome = outcome
    }
}

public protocol Remover: Sendable {
    func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult]
}

enum RemovalText {
    static let dryRun = "Trockenlauf"
    static func denied(_ reason: String) -> String { "Gesperrt: \(reason)" }

    /// Kürzt Werkzeug-Fehlertext auf ca. 300 Zeichen.
    static func shorten(_ text: String, limit: Int = 300) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }
}

/// Gemeinsamer Ablauf für Papierkorb und Löschen: Guard zuerst, dann Trockenlauf, dann die Aktion.
func removePathItems(
    _ finding: Finding, items: [FindingItem], dryRun: Bool, guard safety: SafetyGuard,
    action: (URL) throws -> Void
) -> [ItemResult] {
    items.map { item in
        func result(_ o: ItemOutcome) -> ItemResult { ItemResult(findingID: finding.id, itemID: item.id, outcome: o) }
        guard let url = item.url else { return result(.skipped("Kein Pfad")) }
        if case .denied(let reason) = safety.check(url) { return result(.failed(RemovalText.denied(reason))) }
        if dryRun { return result(.skipped(RemovalText.dryRun)) }
        do {
            try action(url)
            return result(.removed(freed: item.size))
        } catch {
            return result(.failed(error.localizedDescription))
        }
    }
}
