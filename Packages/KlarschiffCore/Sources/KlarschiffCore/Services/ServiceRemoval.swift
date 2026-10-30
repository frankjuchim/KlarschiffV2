import Foundation

/// Entfernt verwaiste Hintergrunddienste: Benutzer-Agents per Papierkorb, Agents/Daemons unter `/Library` per Admin.
/// Nur verwaiste, nicht-Apple, nicht-eigene LaunchAgents/-Daemons mit gültigem Label und plist am erwarteten Ort.
public enum ServiceRemoval {
    public static let scannerID = "services.orphaned"
    static let launchctl = "/bin/launchctl"
    static let trashID = FindingID(scannerID: scannerID, key: "user")
    static let adminID = FindingID(scannerID: scannerID, key: "admin")

    private static let notFoundMarkers = ["Could not find service", "No such process"]

    public static let sharedLabelReason = "Ein gleichnamiger, intakter Dienst läuft – bitte über die zugehörige App entfernen."
    /// Markierung bedingter Admin-Schritte in der Befehlsvorschau (als Shell-Kommentar, damit die Zeile kopierbar bleibt).
    public static let conditionalNote = "  # nur wenn der Dienst gestoppt wurde"

    /// Darf dieser Dienst entfernt werden? (Fail-closed: jede Unklarheit → nein.)
    /// `home`: Home-Ordner des Scanners (`ScanContext.home`); Benutzer-plists müssen direkt in `<home>/Library/LaunchAgents` liegen.
    public static func isRemovable(_ item: LaunchItem, home: URL = URL(filePath: NSHomeDirectory())) -> Bool {
        !item.sharesLabelWithKeptService && isRemovableIgnoringSharedLabels(item, home: home)
    }

    /// launchd-Domäne, in der `launchctl` den Dienst anspricht: Benutzer und Alle Benutzer teilen `gui/<uid>`.
    private static func domain(_ scope: LaunchScope) -> String? {
        switch scope {
        case .user, .allUsers: "gui"
        case .system: "system"
        case .loginItem: nil
        }
    }

    /// Setzt `sharesLabelWithKeptService` für entfernbare Einträge, deren Label (ohne Groß-/Kleinschreibung) ein nicht
    /// entfernbarer Eintrag derselben Domäne trägt. Setzt nur, hebt nie auf.
    public static func markSharedLabels(_ items: [LaunchItem], home: URL) -> [LaunchItem] {
        let kept = Set(items.compactMap { item -> String? in
            guard !isRemovableIgnoringSharedLabels(item, home: home), let d = domain(item.scope) else { return nil }
            return d + "/" + item.label.lowercased()
        })
        return items.map { item in
            var copy = item
            if let d = domain(item.scope), kept.contains(d + "/" + item.label.lowercased()),
               isRemovableIgnoringSharedLabels(item, home: home) {
                copy.sharesLabelWithKeptService = true
            }
            return copy
        }
    }

    /// Grund, warum ein (verwaister) Dienst nicht entfernbar ist; `nil` = entfernbar.
    public static func notRemovableReason(_ item: LaunchItem, home: URL) -> String? {
        if isRemovable(item, home: home) { return nil }
        if item.sharesLabelWithKeptService, isRemovableIgnoringSharedLabels(item, home: home) { return sharedLabelReason }
        if item.isOwnAgent || item.label.lowercased().hasPrefix(LaunchItemScanner.ownPrefix) {
            return "Gehört zu Klarschiff 2 und bleibt erhalten."
        }
        if item.scope == .loginItem { return "Anmeldeobjekte schaltest du in den Systemeinstellungen aus." }
        if !item.isOrphaned { return "Der Dienst ist nicht verwaist." }
        let lower = item.label.lowercased()
        if lower.hasPrefix("com.apple.") || AdminRemover.appleServicePrefixes.contains(where: { lower.hasPrefix($0) }) {
            return "Gehört zu macOS."
        }
        if !AdminRemover.isRemovableServiceLabel(item.label) {
            return "Ungewöhnlicher Name – Klarschiff 2 fasst diesen Dienst nicht an."
        }
        return "Die Startdatei liegt nicht am erwarteten Ort."
    }

    private static func isRemovableIgnoringSharedLabels(_ item: LaunchItem, home: URL) -> Bool {
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
        let removable = markSharedLabels(items, home: home).filter { isRemovable($0, home: home) }
        var findings: [Finding] = []

        let user = removable.filter { $0.scope == .user }
        if !user.isEmpty {
            findings.append(Finding(
                id: trashID, category: .services,
                title: "Verwaiste Hintergrunddienste",
                summary: "Die zugehörige App wurde gelöscht. Der Dienst wird gestoppt und seine Startdatei in den Papierkorb gelegt.",
                risk: .review, method: .trash, items: user.map(findingItem), size: nil, blockingApps: [],
                keepSuggested: false,
                commandPreview: guiBootoutLines(user, uid: uid),
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
            // Alle-Benutzer-Agents werden erst nach erfolgreichem Admin-Schritt gestoppt (Abbruch → bleiben geladen).
            let lateBootouts = guiBootoutLines(admin.filter { $0.scope == .allUsers }, uid: uid)
            findings.append(Finding(
                id: adminID, category: .services,
                title: "Verwaiste Hintergrunddienste (Admin)",
                summary: "Die zugehörige App wurde gelöscht. Der Dienst wird gestoppt und seine Startdatei mit deinem Admin-Passwort gelöscht – nicht über den Papierkorb.",
                risk: .review, method: .admin(steps), items: admin.map(findingItem), size: nil, blockingApps: [],
                keepSuggested: false,
                commandPreview: steps.map { previewLine($0) } + lateBootouts,
                needsFullDiskAccess: false))
        }
        return findings
    }

    /// Gequoteter Admin-Schritt; bedingte Schritte tragen `conditionalNote`.
    static func previewLine(_ step: AdminStep) -> String {
        ([step.executable] + step.arguments).map(ShellQuote.quote).joined(separator: " ")
            + (step.runsIfPreviousSucceeded ? conditionalNote : "")
    }

    private static func guiBootoutLines(_ items: [LaunchItem], uid: uid_t) -> [String] {
        items.map { "\(launchctl) bootout gui/\(uid)/\($0.label)" }
    }

    /// Kopierbare Befehle in Ausführungsreihenfolge: `bootout gui/…` der Benutzer-Agents, Papierkorb, Admin-Schritte
    /// (mit `sudo`), danach `bootout gui/…` der Alle-Benutzer-Agents.
    public static func commandPreview(
        _ items: [LaunchItem], home: URL = URL(filePath: NSHomeDirectory()), uid: uid_t = getuid()
    ) -> [String] {
        let removable = markSharedLabels(items, home: home).filter { isRemovable($0, home: home) }
        let findings = finding(removable, home: home, uid: uid)
        let selection = Dictionary(findings.map { ($0.id, Set($0.items.map(\.id))) }, uniquingKeysWith: { a, b in a.union(b) })
        let plan = RemovalPlan(findings: findings, selection: selection, options: RemovalOptions())
        return guiBootoutLines(removable.filter { $0.scope == .user }, uid: uid) + plan.commandPreview
            + guiBootoutLines(removable.filter { $0.scope == .allUsers }, uid: uid)
    }

    private static func findingItem(_ item: LaunchItem) -> FindingItem {
        FindingItem(id: item.id, url: item.plistURL, name: item.displayName,
                    detail: "\(item.scope.title) · \(item.label) – \(item.explanation)")
    }

    /// `launchctl bootout gui/<uid>/<label>` für jeden entfernbaren Benutzer-/Alle-Benutzer-Agent – auch wenn er gerade
    /// nicht läuft (er kann trotzdem geladen sein). „nicht gefunden“ zählt als erledigt; Trockenlauf → keine Aufrufe.
    /// Gleichnamige intakte Dienste derselben Domäne sperren den bootout (`markSharedLabels`).
    public static func bootout(
        _ items: [LaunchItem], runner: CommandRunner, home: URL = URL(filePath: NSHomeDirectory()),
        uid: uid_t = getuid(), dryRun: Bool
    ) async -> [ItemResult] {
        var results: [ItemResult] = []
        for item in markSharedLabels(items, home: home)
        where isRemovable(item, home: home) && (item.scope == .user || item.scope == .allUsers) {
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
