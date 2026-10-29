import Foundation

/// POSIX-Single-Quote-Helfer für kopierbare Befehle und Admin-Skripte.
public enum ShellQuote {
    private static let harmless = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:@%+=,-")

    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ harmless.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct ToolCommand: Hashable, Codable, Sendable {
    public var tool: String
    public var arguments: [String]
    public var timeout: Duration

    public init(tool: String, arguments: [String], timeout: Duration) {
        self.tool = tool
        self.arguments = arguments
        self.timeout = timeout
    }

    /// Gequoteter, kopierbarer Befehl.
    public var display: String {
        ([tool] + arguments).map(ShellQuote.quote).joined(separator: " ")
    }
}

public struct AdminStep: Hashable, Codable, Sendable {
    public var executable: String
    public var arguments: [String]
    /// Optional: Item, zu dem der Schritt gehört. Tragen alle Schritte eines Funds eine ID, darf ein Item mehrere
    /// Schritte haben; ein gesperrter Schritt sperrt dann alle Schritte dieses Items.
    public var itemID: String?
    /// Läuft nur, wenn der unmittelbar vorherige Schritt (desselben Items) erfolgreich war – bei `launchctl bootout`
    /// zählen auch 3/113 („nicht geladen“). Sonst übersprungen mit `AdminScriptBuilder.skippedCode`.
    public var runsIfPreviousSucceeded: Bool

    public init(executable: String, arguments: [String], itemID: String? = nil, runsIfPreviousSucceeded: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.itemID = itemID
        self.runsIfPreviousSucceeded = runsIfPreviousSucceeded
    }

    private enum CodingKeys: String, CodingKey { case executable, arguments, itemID, runsIfPreviousSucceeded }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decode([String].self, forKey: .arguments)
        itemID = try c.decodeIfPresent(String.self, forKey: .itemID)
        runsIfPreviousSucceeded = try c.decodeIfPresent(Bool.self, forKey: .runsIfPreviousSucceeded) ?? false
    }

    /// `launchctl bootout …` – Exit 3 (No such process) / 113 (Could not find service) heißt „war nicht geladen“.
    public var isBootout: Bool { executable == "/bin/launchctl" && arguments.first == "bootout" }
    public static let bootoutNotLoadedCodes: Set<Int32> = [3, 113]

    /// Eine Ausführungseinheit: Items mit ihren Schritten, oder ein fester Fehler.
    struct Unit {
        var items: [FindingItem]
        var steps: [AdminStep]
        var failure: String?
    }

    /// Einzige Zuordnung Schritt ↔ Item (AdminRemover und Befehlsvorschau).
    /// Alle Schritte mit `itemID` → je Item seine Schritte; keiner → alte Regeln (1:1 bei gleicher Anzahl, sonst
    /// alle Schritte für die ganze Auswahl); gemischt → `nil` (nichts ausführen, nichts zeigen).
    static func units(_ steps: [AdminStep], items: [FindingItem], selected: [FindingItem]) -> [Unit]? {
        let tagged = steps.filter { $0.itemID != nil }.count
        if tagged > 0 {
            guard tagged == steps.count else { return nil }
            let known = Set(items.map(\.id))
            return selected.map { item in
                let mine = steps.filter { $0.itemID == item.id }
                if !known.contains(item.id) { return Unit(items: [item], steps: [], failure: "Unbekanntes Item") }
                if mine.isEmpty { return Unit(items: [item], steps: [], failure: "Nichts auszuführen") }
                return Unit(items: [item], steps: mine, failure: nil)
            }
        }
        if !steps.isEmpty, steps.count == items.count {
            return selected.map { item in
                guard let idx = items.firstIndex(where: { $0.id == item.id }) else {
                    return Unit(items: [item], steps: [], failure: "Unbekanntes Item")
                }
                return Unit(items: [item], steps: [steps[idx]], failure: nil)
            }
        }
        return [Unit(items: selected, steps: steps, failure: nil)]
    }

    /// Schritte, die für die Auswahl laufen würden; `nil` = ungültige Schritte (nichts läuft, nichts wird gezeigt).
    public static func selectedSteps(_ steps: [AdminStep], items: [FindingItem], selected: [FindingItem]) -> [AdminStep]? {
        units(steps, items: items, selected: selected)?.filter { $0.failure == nil }.flatMap(\.steps)
    }
}

public enum HintAction: Hashable, Codable, Sendable {
    case openURL(URL)
    case revealInFinder(URL)
}

public enum Fallback: Hashable, Codable, Sendable {
    case delete, trash
}

public enum RemovalMethod: Hashable, Codable, Sendable {
    case trash
    case delete
    case tool([ToolCommand], fallback: Fallback?)
    case admin([AdminStep])
    case hint(HintAction?)
}
