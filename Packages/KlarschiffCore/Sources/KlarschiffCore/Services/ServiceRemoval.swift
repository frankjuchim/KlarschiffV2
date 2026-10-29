import Foundation

/// Entfernt verwaiste Hintergrunddienste: Benutzer-Agents per Papierkorb, Agents/Daemons unter `/Library` per Admin.
/// Nur verwaiste, nicht-Apple, nicht-eigene LaunchAgents/-Daemons mit gültigem Label und plist am erwarteten Ort.
public enum ServiceRemoval {
    public static let scannerID = "services.orphaned"
    static let launchctl = "/bin/launchctl"
    static let trashID = FindingID(scannerID: scannerID, key: "user")
    static let adminID = FindingID(scannerID: scannerID, key: "admin")

    private static let notFoundMarkers = ["Could not find service", "No such process"]

    /// Darf dieser Dienst entfernt werden? (Fail-closed: jede Unklarheit → nein.)
    /// `home`: Home-Ordner des Scanners (`ScanContext.home`); Benutzer-plists müssen direkt in `<home>/Library/LaunchAgents` liegen.
    public static func isRemovable(_ item: LaunchItem, home: URL = URL(filePath: NSHomeDirectory())) -> Bool {
        guard item.isOrphaned, !item.isOwnAgent, item.scope != .loginItem,
              !item.label.lowercased().hasPrefix("com.apple."),
              !item.label.lowercased().hasPrefix(LaunchItemScanner.ownPrefix),
              AdminRemover.isRemovableServiceLabel(item.label),
              let plist = item.plistURL else { return false }
        let parts = plist.path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        guard plist.path.unicodeScalars.first == "/", !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              let name = parts.last, SafetyGuard.isPlistName(name.lowercased()) else { return false }
        let lower = parts.dropFirst().map { $0.lowercased() }
        switch item.scope {
        case .user:
            // Exakt <home>/Library/LaunchAgents/<name>.plist (lexikalisch, ohne Groß-/Kleinschreibung).
            let homeParts = home.path.unicodeScalars.split(separator: "/").map { String(String.UnicodeScalarView($0)).lowercased() }
            guard !homeParts.isEmpty, !homeParts.contains(where: { $0 == "." || $0 == ".." }) else { return false }
            return lower.count == homeParts.count + 3 && Array(lower.prefix(homeParts.count)) == homeParts
                && lower[homeParts.count] == "library" && lower[homeParts.count + 1] == "launchagents"
        case .allUsers:
            return lower.count == 3 && lower[0] == "library" && lower[1] == "launchagents"
        case .system:
            return lower.count == 3 && lower[0] == "library" && lower[1] == "launchdaemons"
        case .loginItem:
            return false
        }
    }

    /// Bis zu zwei Funde: Papierkorb (Benutzer-Agents) und Admin (Alle Benutzer/System).
    /// Admin-Schritte je Item: `.system` → `bootout system/<label>` + `rm -f <plist>`; `.allUsers` → nur `rm -f <plist>`
    /// (der Agent läuft im Benutzerkontext und wird per `bootout(_:)` ohne Admin gestoppt).
    public static func finding(
        _ items: [LaunchItem], home: URL = URL(filePath: NSHomeDirectory()), uid: uid_t = getuid()
    ) -> [Finding] {
        let removable = items.filter { isRemovable($0, home: home) }
        var findings: [Finding] = []

        let user = removable.filter { $0.scope == .user }
        if !user.isEmpty {
            findings.append(Finding(
                id: trashID, category: .services,
                title: "Verwaiste Hintergrunddienste",
                summary: "Die zugehörige App wurde gelöscht. Der Dienst wird gestoppt und seine Startdatei in den Papierkorb gelegt.",
                risk: .review, method: .trash, items: user.map(findingItem), size: nil, blockingApps: [],
                keepSuggested: false,
                commandPreview: user.filter(\.isRunning).map { "\(launchctl) bootout gui/\(uid)/\($0.label)" },
                needsFullDiskAccess: false))
        }

        let admin = removable.filter { $0.scope == .allUsers || $0.scope == .system }
        if !admin.isEmpty {
            var steps: [AdminStep] = []
            for item in admin {
                guard let plist = item.plistURL?.path else { continue }
                let isSystem = item.scope == .system
                if isSystem {
                    steps.append(AdminStep(executable: launchctl, arguments: ["bootout", "system/\(item.label)"], itemID: item.id))
                }
                // Schlägt der Bootout echt fehl, bleibt die plist liegen (erneuter Versuch möglich).
                steps.append(AdminStep(executable: "/bin/rm", arguments: ["-f", plist], itemID: item.id,
                                       runsIfPreviousSucceeded: isSystem))
            }
            let userBootouts = admin.filter { $0.scope == .allUsers && $0.isRunning }
                .map { "\(launchctl) bootout gui/\(uid)/\($0.label)" }
            findings.append(Finding(
                id: adminID, category: .services,
                title: "Verwaiste Hintergrunddienste (Admin)",
                summary: "Die zugehörige App wurde gelöscht. Der Dienst wird gestoppt und seine Startdatei mit deinem Admin-Passwort gelöscht – nicht über den Papierkorb.",
                risk: .review, method: .admin(steps), items: admin.map(findingItem), size: nil, blockingApps: [],
                keepSuggested: false,
                commandPreview: userBootouts + steps.map { ([$0.executable] + $0.arguments).map(ShellQuote.quote).joined(separator: " ") },
                needsFullDiskAccess: false))
        }
        return findings
    }

    private static func findingItem(_ item: LaunchItem) -> FindingItem {
        FindingItem(id: item.id, url: item.plistURL, name: item.displayName,
                    detail: "\(item.scope.title) · \(item.label) – \(item.explanation)")
    }

    /// `launchctl bootout gui/<uid>/<label>` für laufende, entfernbare Benutzer-/Alle-Benutzer-Agents.
    /// „nicht gefunden“ zählt als erledigt; Trockenlauf → keine Aufrufe.
    public static func bootout(
        _ items: [LaunchItem], runner: CommandRunner, home: URL = URL(filePath: NSHomeDirectory()),
        uid: uid_t = getuid(), dryRun: Bool
    ) async -> [ItemResult] {
        var results: [ItemResult] = []
        for item in items where isRemovable(item, home: home) && item.isRunning && (item.scope == .user || item.scope == .allUsers) {
            let fid = item.scope == .user ? trashID : adminID
            func result(_ o: ItemOutcome) -> ItemResult { ItemResult(findingID: fid, itemID: item.id, outcome: o) }
            if dryRun { results.append(result(.skipped(RemovalText.dryRun))); continue }
            do {
                let r = try await runner.run(launchctl, ["bootout", "gui/\(uid)/\(item.label)"])
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
