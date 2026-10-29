import Foundation

/// Ein Überbleibsel der alten Aufräum-Automatik (Agent, Skript, Protokoll oder leere App).
public struct LegacyItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case agent(label: String), script, log, emptyApp
    }

    public var id: String
    public var kind: Kind
    public var url: URL
    public var title: String
    public var explanation: String
    public var isLoaded: Bool

    public init(id: String, kind: Kind, url: URL, title: String, explanation: String, isLoaded: Bool) {
        self.id = id
        self.kind = kind
        self.url = url
        self.title = title
        self.explanation = explanation
        self.isLoaded = isLoaded
    }
}

/// Erkennt und entfernt die zwei alten Automatik-Agents. Nur die sechs festen Pfade, `launchctl` nur `print`/`bootout`
/// für genau die zwei festen Labels in `gui/<uid>`.
public enum LegacyAutomation {
    public static let labels = ["com.frankjuchim.cleanup", "de.bodendiek.klarschiff.check"]
    static let launchctl = "/bin/launchctl"
    static let scannerID = "legacy-automation"

    static let cleanupSentence = "Das Skript `cleanup.sh` leert jeden Monatsersten automatisch deine Caches – das macht Klarschiff 2 bewusst nie ohne dich."
    static let checkSentence = "Der alte Klarschiff-Check zeigt auf eine App, die es nicht mehr gibt."
    static let oldCheckStillRunsSentence = "Der Check von Klarschiff 1 startet weiterhin jeden Sonntag. Klarschiff 2 übernimmt diese Aufgabe – der alte Check wird nicht mehr gebraucht."

    private static let notFoundMarkers = ["Could not find service", "No such process"]

    public static func detect(_ ctx: ScanContext, uid: uid_t = getuid()) async -> [LegacyItem] {
        let fm = FileManager.default
        var items: [LegacyItem] = []

        let scriptURL = ctx.homePath("cleanup.sh")
        let scriptExists = fm.fileExists(atPath: scriptURL.path)
        let app = ctx.absolute("/Applications/Klarschiff.app")
        var isDir: ObjCBool = false
        let emptyApp = fm.fileExists(atPath: app.path, isDirectory: &isDir) && isDir.boolValue && isEmptyBundle(app)
        let oldAppRuns = fm.fileExists(atPath: app.appending(path: "Contents/MacOS/Klarschiff").path)

        // Jeder Erklärsatz erscheint nur einmal: Aufräum-Satz am Skript (sonst am Agent),
        // Check-Satz an der leeren App (sonst am Agent).
        let checkAgentSentence: String? = oldAppRuns ? oldCheckStillRunsSentence : (emptyApp ? nil : checkSentence)
        let agents: [(label: String, intro: String, sentence: String?)] = [
            (labels[0], "Startet jeden Monatsersten%@ das Skript `cleanup.sh`.", scriptExists ? nil : cleanupSentence),
            (labels[1], "Startet sonntags%@ einen Check.", checkAgentSentence),
        ]
        for agent in agents {
            let url = ctx.homePath("Library/LaunchAgents/\(agent.label).plist")
            guard fm.fileExists(atPath: url.path) else { continue }
            let timeText = scheduledTime(plist: url).map { " um \($0) Uhr" } ?? ""
            let explanation = [String(format: agent.intro, timeText), agent.sentence].compactMap { $0 }.joined(separator: " ")
            let loaded = await isLoaded(agent.label, runner: ctx.runner, uid: uid)
            items.append(LegacyItem(
                id: agent.label, kind: .agent(label: agent.label), url: url,
                title: "Hintergrund-Agent \(agent.label)", explanation: explanation, isLoaded: loaded))
        }

        let files: [(id: String, rel: String, kind: LegacyItem.Kind, title: String, explanation: String)] = [
            ("script", "cleanup.sh", .script, "Skript cleanup.sh",
             cleanupSentence),
            ("log", "cleanup.log", .log, "Protokoll cleanup.log", "Altes Protokoll des Aufräum-Skripts."),
            ("errorlog", "cleanup_error.log", .log, "Protokoll cleanup_error.log", "Altes Fehlerprotokoll des Aufräum-Skripts."),
        ]
        for f in files {
            let url = ctx.homePath(f.rel)
            guard fm.fileExists(atPath: url.path) else { continue }
            items.append(LegacyItem(id: f.id, kind: f.kind, url: url, title: f.title, explanation: f.explanation, isLoaded: false))
        }

        if emptyApp {
            items.append(LegacyItem(
                id: "app", kind: .emptyApp, url: app, title: "Leere alte App Klarschiff.app",
                explanation: "Ein leerer Ordner ohne Programm – " + checkSentence.prefix(1).lowercased() + checkSentence.dropFirst(),
                isLoaded: false))
        }
        return items
    }

    /// Leer = rekursiv keine Dateien außer `.DS_Store`; Symlinks (auch die App selbst) und Lesefehler zählen als „nicht leer“.
    static func isEmptyBundle(_ url: URL) -> Bool {
        let fm = FileManager.default
        func type(_ u: URL) -> FileAttributeType? { (try? fm.attributesOfItem(atPath: u.path))?[.type] as? FileAttributeType }
        guard type(url) == .typeDirectory else { return false }
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
        for name in names {
            let child = url.appending(path: name)
            switch type(child) {
            case .typeDirectory: if !isEmptyBundle(child) { return false }
            case .typeRegular where name == ".DS_Store": continue
            default: return false
            }
        }
        return true
    }

    /// Liest Stunde/Minute aus `StartCalendarInterval` (Dictionary oder erstes Array-Element); sonst nil.
    static func scheduledTime(plist url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        var interval = obj["StartCalendarInterval"]
        if let arr = interval as? [[String: Any]] { interval = arr.first }
        guard let dict = interval as? [String: Any], let hour = dict["Hour"] as? Int else { return nil }
        let minute = dict["Minute"] as? Int ?? 0
        return String(format: "%d:%02d", hour, minute)
    }

    static func isLoaded(_ label: String, runner: CommandRunner, uid: uid_t) async -> Bool {
        guard labels.contains(label) else { return false }
        let result = try? await runner.run(launchctl, ["print", "gui/\(uid)/\(label)"])
        return result?.succeeded == true
    }

    /// Nur Items, deren URL einer der sechs festen Pfade ist, werden aufgenommen.
    public static func removalFinding(_ items: [LegacyItem], ctx: ScanContext, includeExtras: Bool) -> Finding {
        let allowed = Set(
            labels.map { ctx.homePath("Library/LaunchAgents/\($0).plist").path }
                + [ctx.homePath("cleanup.sh").path, ctx.homePath("cleanup.log").path,
                   ctx.homePath("cleanup_error.log").path, ctx.absolute("/Applications/Klarschiff.app").path])
        let chosen = items.filter { item in
            guard allowed.contains(item.url.path) else { return false }
            if case .agent = item.kind { return true }
            return includeExtras
        }
        let findingItems = chosen.map {
            FindingItem(id: $0.id, url: $0.url, name: $0.title, detail: $0.explanation)
        }
        return Finding(
            id: FindingID(scannerID: scannerID, key: "legacy"),
            category: .system,
            title: "Alte Aufräum-Automatik",
            summary: "Alte Hintergrund-Agents und Überbleibsel, die in den Papierkorb gelegt werden.",
            risk: .review, method: .trash, items: findingItems, size: nil, blockingApps: [],
            keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)
    }

    public static func bootout(
        _ items: [LegacyItem], runner: CommandRunner, uid: uid_t = getuid(), dryRun: Bool
    ) async -> [ItemResult] {
        var results: [ItemResult] = []
        for item in items {
            guard case .agent(let label) = item.kind, labels.contains(label), item.isLoaded else { continue }
            let fid = FindingID(scannerID: scannerID, key: "legacy")
            func result(_ o: ItemOutcome) -> ItemResult { ItemResult(findingID: fid, itemID: item.id, outcome: o) }
            if dryRun { results.append(result(.skipped(RemovalText.dryRun))); continue }
            do {
                let r = try await runner.run(launchctl, ["bootout", "gui/\(uid)/\(label)"])
                if r.succeeded || notFoundMarkers.contains(where: { r.stderr.contains($0) }) {
                    results.append(result(.removed(freed: nil)))
                } else {
                    results.append(result(.failed(RemovalText.shorten(r.stderr))))
                }
            } catch {
                results.append(result(.failed("launchctl konnte nicht ausgeführt werden")))
            }
        }
        return results
    }
}
