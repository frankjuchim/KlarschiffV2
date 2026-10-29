import Foundation

/// Reine Schwellenlogik: Wachstum je ID, Aufräumbares, knapper Speicher.
public enum GrowthWatcher {
    static let growthAbsolute: Int64 = 5_000_000_000
    static let growthDoubledMin: Int64 = 2_000_000_000
    static let cleanableMin: Int64 = 1_000_000_000
    static let lowSpaceAbsolute: Int64 = 20_000_000_000

    /// Unbekannt: ID selbst oder ihr Scanner (Teil vor `/`) steht in `lowerBoundIDs`.
    static func isUnknown(_ id: String, in s: CheckSnapshot) -> Bool {
        if s.lowerBoundIDs.contains(id) { return true }
        guard let scanner = id.split(separator: "/", maxSplits: 1).first, scanner.count < id.count else { return false }
        return s.lowerBoundIDs.contains(String(scanner))
    }

    /// Verglichen werden nur IDs, die in beiden Snapshots eine Größe haben und in keinem als Untergrenze/unbekannt gelten.
    /// Verwaiste Hintergrunddienste: nur Labels, die im vorigen Snapshot fehlten (ohne vorigen Snapshot kein Alarm).
    /// Reihenfolge: growth (absteigend nach Zuwachs), orphanedServices, lowSpace, cleanable.
    public static func alerts(previous: CheckSnapshot?, current: CheckSnapshot) -> [CheckAlert] {
        var result: [CheckAlert] = []

        if let previous {
            let grown: [(id: String, from: Int64, to: Int64)] = current.sizes.compactMap { id, to in
                guard let from = previous.sizes[id],
                      !isUnknown(id, in: previous), !isUnknown(id, in: current) else { return nil }
                let delta = to - from
                guard delta >= growthAbsolute || (delta >= growthDoubledMin && to > 2 * from) else { return nil }
                return (id, from, to)
            }
            let sorted = grown.sorted {
                let d0 = $0.to - $0.from, d1 = $1.to - $1.from
                return d0 != d1 ? d0 > d1 : $0.id < $1.id
            }
            for g in sorted {
                result.append(.growth(id: g.id, title: current.titles[g.id] ?? g.id, from: g.from, to: g.to))
            }
            let known = Set(previous.orphanedServiceLabels)
            let new = Set(current.orphanedServiceLabels).subtracting(known).sorted()
            if !new.isEmpty { result.append(.orphanedServices(labels: new)) }
        }

        if current.totalBytes > 0,
           current.freeBytes * 10 < current.totalBytes || current.freeBytes < lowSpaceAbsolute {
            result.append(.lowSpace(free: current.freeBytes, total: current.totalBytes))
        }
        if current.cleanableTotal >= cleanableMin {
            result.append(.cleanable(total: current.cleanableTotal))
        }
        return result
    }
}
