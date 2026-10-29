import Foundation

public struct CheckNotification: Sendable, Equatable {
    public var title: String
    public var body: String
    public var tab: AppTab

    public init(title: String, body: String, tab: AppTab) {
        self.title = title
        self.body = body
        self.tab = tab
    }
}

/// Text der einen Mitteilung pro Check. Priorität: Wachstum > knapper Speicher > Aufräumbares.
public enum CheckNotificationText {
    public static let title = "Klarschiff 2"

    public static func make(_ s: CheckSnapshot) -> CheckNotification? {
        var growth: (id: String, title: String, from: Int64, to: Int64)?
        var low: Int64?
        var cleanable: Int64?
        for a in s.alerts {
            switch a {
            case .growth(let id, let t, let from, let to): if growth == nil { growth = (id, t, from, to) }
            case .lowSpace(let free, _): if low == nil { low = free }
            case .cleanable(let total): if cleanable == nil { cleanable = total }
            }
        }
        if let g = growth {
            var body = "\(g.title) +\(ByteFormat.string(g.to - g.from)) seit dem letzten Check"
            if let c = cleanable { body += " · \(ByteFormat.string(c)) aufräumbar" }
            return CheckNotification(title: title, body: body, tab: tab(forGrowthID: g.id))
        }
        if let free = low {
            return CheckNotification(title: title, body: "Nur noch \(ByteFormat.string(free)) frei", tab: .storage)
        }
        if let c = cleanable {
            return CheckNotification(title: title, body: "\(ByteFormat.string(c)) aufräumbar", tab: .storage)
        }
        return nil
    }

    /// `systemdata.*` → Systemdaten; sonst Tab der Kategorie des Scanners (ID = `scannerID/key`); unbekannt → Speicher.
    static func tab(forGrowthID id: String) -> AppTab {
        if id.hasPrefix("systemdata.") { return .systemData }
        let scannerID = id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id
        return Category.forScannerID(scannerID)?.tab ?? .storage
    }
}
