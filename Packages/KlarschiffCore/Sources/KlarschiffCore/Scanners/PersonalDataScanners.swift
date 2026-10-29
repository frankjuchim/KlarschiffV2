import Foundation

enum GermanDate {
    static func string(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "de_DE")))
    }
}

// MARK: - iPhone-/iPad-Backups

public struct MobileBackupScanner: Scanner {
    public let id = "personal.backups"
    public init() {}

    private func noAccess() -> Finding {
        Finding(
            id: FindingID(scannerID: id, key: "noAccess"), category: .personalData,
            title: "iPhone-/iPad-Backups",
            summary: "Braucht Vollzugriff auf die Festplatte. Erlaube Klarschiff 2 den Zugriff in den Systemeinstellungen unter Datenschutz & Sicherheit, dann kann ich die Backups auflisten.",
            risk: .review, method: .trash, items: [], size: nil, blockingApps: [],
            keepSuggested: false, commandPreview: [], needsFullDiskAccess: true)
    }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let dir = ctx.homePath("Library/Application Support/MobileSync/Backup")
        guard ctx.hasFullDiskAccess else { return [noAccess()] }
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [noAccess()] }

        var findings: [Finding] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            try Task.checkCancellation()
            let url = dir.appending(path: name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            var device = "iPhone-/iPad-Backup"
            var detail: String?
            if let data = try? Data(contentsOf: url.appending(path: "Info.plist")),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                if let d = plist["Device Name"] as? String, !d.isEmpty { device = d }
                if let date = plist["Last Backup Date"] as? Date { detail = "vom \(GermanDate.string(date))" }
            }
            let size = try? await ctx.sizer.size(of: url)
            let title = device == "iPhone-/iPad-Backup" ? device : "Backup von \(device)"
            let items = [FindingItem(id: url.path, url: url, name: name, size: size, detail: detail)]
            findings.append(Finding(
                id: FindingID(scannerID: id, key: name), category: .personalData, title: title,
                summary: "Eine lokale Sicherung deines Geräts. Prüfe, ob du das Gerät noch nutzt und ob die Sicherung aktuell in iCloud liegt – gelöscht ist sie weg.",
                risk: .review, method: .trash, items: items, size: size, blockingApps: [],
                keepSuggested: false, commandPreview: PathScanner.preview(.trash, items: items), needsFullDiskAccess: true))
        }
        return findings
    }
}

// MARK: - Alte Installer

public struct OldInstallerScanner: Scanner {
    public let id = "personal.installers"
    public init() {}

    static let extensions: Set<String> = ["dmg", "pkg", "zip", "xip", "ipsw"]

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let dir = ctx.homePath("Downloads")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let cutoff = ctx.now.addingTimeInterval(-30 * 86_400)
        var items: [FindingItem] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            try Task.checkCancellation()
            guard Self.extensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let url = dir.appending(path: name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let type = attrs[.type] as? FileAttributeType, type == .typeRegular || type == .typeDirectory,
                  let modified = attrs[.modificationDate] as? Date, modified < cutoff else { continue }
            let size = try? await ctx.sizer.size(of: url)
            items.append(FindingItem(id: url.path, url: url, name: name, size: size, date: modified,
                                     detail: "vom \(GermanDate.string(modified))"))
        }
        guard !items.isEmpty else { return [] }
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .personalData,
            title: "Alte Installer in Downloads",
            summary: "Installationsdateien (.dmg, .pkg, .zip, .xip, .ipsw) in deinem Downloads-Ordner, die älter als 30 Tage sind. Meist sind die Programme längst installiert.",
            risk: .review, method: .trash, items: items,
            size: items.compactMap(\.size).reduce(0, +), blockingApps: [], keepSuggested: false,
            commandPreview: PathScanner.preview(.trash, items: items), needsFullDiskAccess: false)]
    }
}

// MARK: - Nachrichten-Anhänge

public struct MessagesAttachmentsScanner: Scanner {
    public let id = "personal.messages"
    public init() {}

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let dir = ctx.homePath("Library/Messages/Attachments")
        let summary = "Bilder, Videos und Dateien aus deinen Unterhaltungen in Nachrichten. Klarschiff 2 löscht sie nicht selbst: Stelle in Nachrichten → Einstellungen → Nachrichten behalten auf „1 Jahr“, oder prüfe die Größe unter Systemeinstellungen → Allgemein → Speicher."
        guard ctx.hasFullDiskAccess else {
            return [Finding(
                id: FindingID(scannerID: id, key: "noAccess"), category: .personalData,
                title: "Nachrichten-Anhänge",
                summary: "Braucht Vollzugriff auf die Festplatte. " + summary,
                risk: .hintOnly, method: .hint(nil), items: [], size: nil, blockingApps: [],
                keepSuggested: false, commandPreview: [], needsFullDiskAccess: true)]
        }
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let size = try? await ctx.sizer.size(of: dir)
        return [Finding(
            id: FindingID(scannerID: id, key: "attachments"), category: .personalData,
            title: "Nachrichten-Anhänge", summary: summary, risk: .hintOnly, method: .hint(nil),
            items: [FindingItem(id: dir.path, url: dir, name: "Attachments", size: size)],
            size: size, blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: true)]
    }
}
