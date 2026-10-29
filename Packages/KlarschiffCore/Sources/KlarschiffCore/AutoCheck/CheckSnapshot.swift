import Foundation

/// Auffälligkeit eines Checks. Der Check meldet nur – er löscht nie.
public enum CheckAlert: Codable, Sendable, Equatable {
    case growth(id: String, title: String, from: Int64, to: Int64)
    case cleanable(total: Int64)
    case lowSpace(free: Int64, total: Int64)
}

/// Ergebnis eines Check-Laufs; wird im Verlauf abgelegt.
public struct CheckSnapshot: Codable, Sendable, Equatable {
    public var date: Date
    public var cleanableTotal: Int64
    public var freeBytes: Int64
    public var totalBytes: Int64
    public var sizes: [String: Int64]
    public var titles: [String: String]
    public var alerts: [CheckAlert]
    /// IDs, deren Größe nur eine Untergrenze ist oder deren Scanner fehlschlug (unbekannt) – nie für Wachstum verglichen.
    /// Fehlt in älteren Verläufen; dann leer.
    public var lowerBoundIDs: Set<String> = []

    public init(date: Date, cleanableTotal: Int64, freeBytes: Int64, totalBytes: Int64,
                sizes: [String: Int64], titles: [String: String], alerts: [CheckAlert],
                lowerBoundIDs: Set<String> = []) {
        self.date = date
        self.cleanableTotal = cleanableTotal
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.sizes = sizes
        self.titles = titles
        self.alerts = alerts
        self.lowerBoundIDs = lowerBoundIDs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        cleanableTotal = try c.decode(Int64.self, forKey: .cleanableTotal)
        freeBytes = try c.decode(Int64.self, forKey: .freeBytes)
        totalBytes = try c.decode(Int64.self, forKey: .totalBytes)
        sizes = try c.decode([String: Int64].self, forKey: .sizes)
        titles = try c.decode([String: String].self, forKey: .titles)
        alerts = try c.decode([CheckAlert].self, forKey: .alerts)
        lowerBoundIDs = try c.decodeIfPresent(Set<String>.self, forKey: .lowerBoundIDs) ?? []
    }
}
