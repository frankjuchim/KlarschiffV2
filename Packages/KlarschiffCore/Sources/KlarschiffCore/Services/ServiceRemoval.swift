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
    public static func isRemovable(_ item: LaunchItem) -> Bool {
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
            // …/Library/LaunchAgents/<name>.plist unterhalb eines Home-Ordners (nicht /Library selbst).
            return lower.count > 3 && Array(lower.suffix(3).prefix(2)) == ["library", "launchagents"]
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
    public static func finding(_ items: [LaunchItem], uid: uid_t = getuid()) -> [Finding] {
        let removable = items.filter(isRemovable)
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
                if item.scope == .system {
                    steps.append(AdminStep(executable: launchctl, arguments: ["bootout", "system/\(item.label)"], itemID: item.id))
                }
                steps.append(AdminStep(executable: "/bin/rm", arguments: ["-f", plist], itemID: item.id))
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
        _ items: [LaunchItem], runner: CommandRunner, uid: uid_t = getuid(), dryRun: Bool
    ) async -> [ItemResult] {
        var results: [ItemResult] = []
        for item in items where isRemovable(item) && item.isRunning && (item.scope == .user || item.scope == .allUsers) {
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
