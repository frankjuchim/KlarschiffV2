import Foundation

/// Beanspruchte Pfade: Spezifische Scanner claimen, Sammel-Scanner überspringen Beanspruchtes.
public actor PathClaims {
    private var claimed: [[String]] = []

    public init() {}

    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents
    }

    private static func isEqualOrBelow(_ child: [String], _ parent: [String]) -> Bool {
        child.count >= parent.count && Array(child.prefix(parent.count)) == parent
    }

    public func claim(_ urls: [URL]) {
        claimed.append(contentsOf: urls.map(Self.components))
    }

    /// `true`, wenn `url` gleich einem beanspruchten Pfad ist oder darunter liegt (Vergleich nach Pfadkomponenten).
    public func isClaimed(_ url: URL) -> Bool {
        let c = Self.components(url)
        return claimed.contains { Self.isEqualOrBelow(c, $0) }
    }

    /// Summe der Item-Größen der übergebenen Funde, deren URL gleich `url` ist oder darunter liegt.
    public func claimedSize(under url: URL, findings: [Finding]) -> Int64 {
        let base = Self.components(url)
        var total: Int64 = 0
        for item in findings.flatMap(\.items) {
            guard let u = item.url, Self.isEqualOrBelow(Self.components(u), base) else { continue }
            total += item.size ?? 0
        }
        return total
    }
}
