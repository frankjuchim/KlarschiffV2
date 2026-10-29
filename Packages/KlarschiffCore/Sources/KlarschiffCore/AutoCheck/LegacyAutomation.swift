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

    private static let notFoundMarkers = ["Could not find service", "No such process"]

    public static func detect(_ ctx: ScanContext, uid: uid_t = getuid()) async -> [LegacyItem] {
        let fm = FileManager.default
        var items: [LegacyItem] = []

        let agents: [(label: String, explanation: String)] = [
            (labels[0], "Startet jeden Monatsersten um 9:00 Uhr das Skript `cleanup.sh`. Das Skript `cleanup.sh` leert jeden Monatsersten automatisch deine Caches – das macht Klarschiff 2 bewusst nie ohne dich."),
            (labels[1], "Startet sonntags um 10:00 Uhr einen Check. Der alte Klarschiff-Check zeigt auf eine App, die es nicht mehr gibt."),
        ]
        for agent in agents {
            let url = ctx.homePath("Library/LaunchAgents/\(agent.label).plist")
            guard fm.fileExists(atPath: url.path) else { continue }
            let loaded = await isLoaded(agent.label, runner: ctx.runner, uid: uid)
            items.append(LegacyItem(
                id: agent.label, kind: .agent(label: agent.label), url: url,
                title: "Hintergrund-Agent \(agent.label)", explanation: agent.explanation, isLoaded: loaded))
        }

        let files: [(id: String, rel: String, kind: LegacyItem.Kind, title: String, explanation: String)] = [
            ("script", "cleanup.sh", .script, "Skript cleanup.sh",
             "Das Skript `cleanup.sh` leert jeden Monatsersten automatisch deine Caches – das macht Klarschiff 2 bewusst nie ohne dich."),
            ("log", "cleanup.log", .log, "Protokoll cleanup.log", "Altes Protokoll des Aufräum-Skripts."),
            ("errorlog", "cleanup_error.log", .log, "Protokoll cleanup_error.log", "Altes Fehlerprotokoll des Aufräum-Skripts."),
        ]
        for f in files {
            let url = ctx.homePath(f.rel)
            guard fm.fileExists(atPath: url.path) else { continue }
            items.append(LegacyItem(id: f.id, kind: f.kind, url: url, title: f.title, explanation: f.explanation, isLoaded: false))
        }

        let app = ctx.absolute("/Applications/Klarschiff.app")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: app.path, isDirectory: &isDir), isDir.boolValue,
           !fm.fileExists(atPath: app.appending(path: "Contents/MacOS/Klarschiff").path) {
            items.append(LegacyItem(
                id: "app", kind: .emptyApp, url: app, title: "Leere alte App Klarschiff.app",
                explanation: "Ein leerer Ordner ohne Programm – der alte Klarschiff-Check zeigt auf eine App, die es nicht mehr gibt.",
                isLoaded: false))
        }
        return items
    }

    static func isLoaded(_ label: String, runner: CommandRunner, uid: uid_t) async -> Bool {
        guard labels.contains(label) else { return false }
        let result = try? await runner.run(launchctl, ["print", "gui/\(uid)/\(label)"])
        return result?.succeeded == true
    }

    public static func removalFinding(_ items: [LegacyItem], includeExtras: Bool) -> Finding {
        let chosen = items.filter { item in
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
