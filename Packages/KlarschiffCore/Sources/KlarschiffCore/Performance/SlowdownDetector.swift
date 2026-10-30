import Foundation

/// Ein ruhiger Hinweis, was den Mac gerade bremst.
public struct SlowdownHint: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let text: String

    public init(id: String, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

/// Meldet erst, wenn eine Bedingung mindestens 3 Minuten ununterbrochen gilt.
public struct SlowdownDetector: Sendable {
    public static let requiredDuration: TimeInterval = 180
    public static let cpuThreshold: Double = 80
    public static let swapGrowthThreshold: UInt64 = 1_000_000_000

    private var cpuSince: [String: Date] = [:]
    private var pressureSince: Date?
    private var swapSamples: [(date: Date, used: UInt64)] = []
    private var lastUpdate: Date?
    /// Größere Lücken zwischen zwei Messungen (Tab war zu, Mac schlief) unterbrechen die Beobachtung.
    public static let maxGap: TimeInterval = 30

    public init() {}

    public mutating func update(sample: SystemSample, top: [ActivityEntry], now: Date) -> [SlowdownHint] {
        if let last = lastUpdate, now.timeIntervalSince(last) > Self.maxGap {
            cpuSince = [:]; pressureSince = nil; swapSamples = []
        }
        lastUpdate = now
        var hints: [SlowdownHint] = []
        let needed = Self.requiredDuration

        // Apps mit hoher Last: je Eintrag eigener Startzeitpunkt, Unterbrechung setzt zurück.
        var stillBusy: [String: Date] = [:]
        for entry in top where entry.cpuPercent > Self.cpuThreshold {
            let start = cpuSince[entry.id] ?? now
            stillBusy[entry.id] = start
            if now.timeIntervalSince(start) >= needed {
                hints.append(Self.cpuHint(for: entry))
            }
        }
        cpuSince = stillBusy

        // Speicherdruck.
        if sample.pressureLevel >= 2 {
            let start = pressureSince ?? now
            pressureSince = start
            if now.timeIntervalSince(start) >= needed {
                hints.append(SlowdownHint(
                    id: "pressure",
                    title: "Der Arbeitsspeicher ist seit Minuten \(PerformanceWords.memory(pressure: sample.pressureLevel))",
                    text: "Dein Mac hat seit einigen Minuten wenig freien Arbeitsspeicher. "
                        + "Das Beenden großer Programme, die du gerade nicht brauchst, schafft wieder Luft."))
            }
        } else {
            pressureSince = nil
        }

        // Auslagerung wächst: aktuellen Wert mit dem ältesten Wert im 3-Minuten-Fenster vergleichen.
        swapSamples.append((sample.date, sample.swapUsed))
        let cutoff = now.addingTimeInterval(-needed)
        // Eine Probe am oder vor der Grenze bleibt als Vergleichswert erhalten.
        while swapSamples.count > 1, swapSamples[1].date <= cutoff { swapSamples.removeFirst() }
        if let base = swapSamples.first, now.timeIntervalSince(base.date) >= needed,
           sample.swapUsed > base.used, sample.swapUsed - base.used > Self.swapGrowthThreshold {
            hints.append(SlowdownHint(
                id: "swap",
                title: "Dein Mac lagert gerade viel Speicher aus",
                text: "In den letzten Minuten ist die Auslagerung auf die Festplatte deutlich gewachsen. "
                    + "Das macht den Mac träge – weniger offene Programme helfen."))
        }
        return hints
    }

    /// Beenden wird nur vorgeschlagen, wenn Klarschiff 2 das Programm auch beenden darf.
    static func cpuHint(for entry: ActivityEntry) -> SlowdownHint {
        let id = "cpu.\(entry.id)"
        if entry.isSystem {
            return SlowdownHint(
                id: id, title: "\(entry.name) arbeitet seit Minuten viel",
                text: "Ein Systemdienst ist gerade sehr beschäftigt – das ist meist vorübergehend "
                    + "(zum Beispiel Fotos-Analyse oder Spotlight). Am besten abwarten.")
        }
        if !entry.canQuit {
            return SlowdownHint(
                id: id, title: "\(entry.name) arbeitet seit Minuten viel",
                text: "\(entry.name) beansprucht den Prozessor seit einigen Minuten stark. "
                    + "Oft ist das nach einer Weile vorbei – falls nicht, lohnt ein Blick, was das Programm gerade tut.")
        }
        return SlowdownHint(
            id: id, title: "\(entry.name) rechnet seit Minuten stark",
            text: "\(entry.name) beansprucht den Prozessor seit einigen Minuten stark. "
                + "Wenn du das Programm gerade nicht brauchst, kannst du es in Ruhe beenden.")
    }
}
