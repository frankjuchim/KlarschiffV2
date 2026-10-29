import Foundation

let softwareUpdateURL = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!

private func adminPreview(_ step: AdminStep) -> String {
    (["sudo", step.executable] + step.arguments).map(ShellQuote.quote).joined(separator: " ")
}

/// Lokale APFS-Schnappschüsse: Update-Snapshots (nur Hinweis) und Time-Machine-Snapshots (Admin-Löschung).
public struct SnapshotScanner: Scanner {
    public let id = "system.snapshots"
    public init() {}

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let result = try await ctx.runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: .seconds(120))
        guard result.succeeded else { throw CommandError.launchFailed("tmutil: Exit \(result.exitCode)") }

        let names = result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") }
        var findings: [Finding] = []

        let updates = names.filter { $0.contains("com.apple.os.update") || $0.contains("MSUPrepareUpdate") }
        if !updates.isEmpty {
            findings.append(Finding(
                id: FindingID(scannerID: id, key: "update"), category: .system,
                title: "Schnappschüsse von macOS-Updates",
                summary: "Diese Schnappschüsse hält macOS für ein ausstehendes Update fest. Sie verschwinden, sobald du das Update installierst und neu startest.",
                risk: .hintOnly, method: .hint(.openURL(softwareUpdateURL)),
                items: updates.map { FindingItem(id: $0, name: $0) },
                size: nil, blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false))
        }

        let prefix = "com.apple.TimeMachine."
        let suffix = ".local"
        var items: [FindingItem] = []
        var steps: [AdminStep] = []
        for n in names where n.hasPrefix(prefix) && n.hasSuffix(suffix) && n.count > prefix.count + suffix.count {
            let stamp = String(n.dropFirst(prefix.count).dropLast(suffix.count))
            items.append(FindingItem(id: n, name: Self.readable(stamp), detail: n))
            steps.append(AdminStep(executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", stamp]))
        }
        if !steps.isEmpty {
            findings.append(Finding(
                id: FindingID(scannerID: id, key: "timeMachine"), category: .system,
                title: "Time-Machine-Schnappschüsse",
                summary: "Lokale Kopien deiner Time-Machine-Sicherung. macOS löscht sie selbst bei Platzmangel. Das Entfernen braucht dein Admin-Passwort.",
                risk: .review, method: .admin(steps), items: items,
                size: nil, blockingApps: [], keepSuggested: false,
                commandPreview: steps.map(adminPreview), needsFullDiskAccess: false))
        }
        return findings
    }

    /// „2026-10-27-101500“ → „27.10.2026, 10:15:00“; unbekanntes Format bleibt unverändert.
    static func readable(_ stamp: String) -> String {
        let p = DateFormatter()
        p.locale = Locale(identifier: "en_US_POSIX")
        p.dateFormat = "yyyy-MM-dd-HHmmss"
        guard let date = p.date(from: stamp) else { return stamp }
        let o = DateFormatter()
        o.locale = Locale(identifier: "de_DE")
        o.dateFormat = "dd.MM.yyyy, HH:mm:ss"
        return o.string(from: date)
    }
}

/// Ausstehende Softwareupdates (`softwareupdate -l`) – nur bei manuellem Scan.
public struct SoftwareUpdateScanner: Scanner {
    public let id = "system.softwareupdate"
    public init() {}

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        guard ctx.includeSlowChecks else { return [] }
        let result = try await ctx.runner.run("/usr/sbin/softwareupdate", ["-l"], timeout: .seconds(60))
        guard result.succeeded else { throw CommandError.launchFailed("softwareupdate: Exit \(result.exitCode)") }

        var labels: [String] = []
        var titles: [String: String] = [:]   // Label → Titel
        var current: String?
        for raw in result.stdout.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label:") {
                let label = line.dropFirst("* Label:".count).trimmingCharacters(in: .whitespaces)
                labels.append(label); current = label
            } else if line.hasPrefix("Title:"), let c = current {
                let rest = line.dropFirst("Title:".count)
                let title = rest.split(separator: ",", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !title.isEmpty { titles[c] = title }
            }
        }
        guard !labels.isEmpty else { return [] }
        return [Finding(
            id: FindingID(scannerID: id, key: "pending"), category: .system,
            title: "Ausstehende Updates",
            summary: "Für deinen Mac stehen Updates bereit. Alte Update-Reste verschwinden meist, sobald du sie installierst und neu startest.",
            risk: .hintOnly, method: .hint(.openURL(softwareUpdateURL)),
            items: labels.map { FindingItem(id: $0, name: titles[$0] ?? $0) },
            size: nil, blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)]
    }
}
