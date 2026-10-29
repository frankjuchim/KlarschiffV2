import Foundation
import Darwin

/// Aufräum-Funde der Systemdaten (Spec §5). Alle `.review`, nie vorausgewählt; jeder Fund beginnt mit „Achtung: “.
/// Gemessen wird unter dem Wurzel-Präfix, Admin-Schritte nennen immer echte, normalisierte absolute Pfade.
public enum SystemCleanup {
    public static func scanners() -> [any Scanner] {
        [TempScanner(), LibraryCachesScanner(), LibraryLogsScanner(), UnifiedLogScanner(), MacUpdateHintScanner()]
    }

    static let day: TimeInterval = 86_400

    static func summary(warning: String, explanation: String) -> String {
        "Achtung: \(warning) \(explanation)"
    }

    /// `lstat`-Attribute (folgt Symlinks nie).
    static func attributes(_ path: String) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: path)
    }

    static func type(_ path: String) -> FileAttributeType? {
        attributes(path)?[.type] as? FileAttributeType
    }

    /// Ein Name aus einer Verzeichnisliste, der sich sicher an einen Pfad hängen lässt.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.unicodeScalars.contains("\0")
    }

    static func measure(_ url: URL, _ ctx: ScanContext) async throws -> (size: Int64, complete: Bool) {
        do { return try await ctx.sizer.measure(url) } catch is CancellationError { throw CancellationError() } catch { return (0, false) }
    }
}

// MARK: - Temp

struct TempScanner: Scanner {
    let id = "sysdata.temp"
    static let warning = "Laufende Programme legen hier Arbeitsdateien ab. Nur Einträge älter als 3 Tage werden entfernt."

    func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let base = ctx.userTempDir
        guard SystemCleanup.type(base.path) == .typeDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return [] }
        let cutoff = ctx.now.addingTimeInterval(-3 * SystemCleanup.day)
        var items: [FindingItem] = []
        for name in names.sorted() where SystemCleanup.isSafeName(name) {
            try Task.checkCancellation()
            let url = base.appending(path: name)
            guard let attrs = SystemCleanup.attributes(url.path), let type = attrs[.type] as? FileAttributeType,
                  let date = attrs[.modificationDate] as? Date, date < cutoff else { continue }
            switch type {
            case .typeRegular: break
            case .typeDirectory: guard try Self.allOlder(url, than: cutoff) else { continue }
            default: continue   // Symlinks, Sockets, Pipes: nie anbieten
            }
            let size = try? await ctx.sizer.size(of: url)
            items.append(FindingItem(id: url.path, url: url, name: name, size: size, date: date))
        }
        guard !items.isEmpty else { return [] }
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .systemData,
            title: "Alte temporäre Dateien",
            summary: SystemCleanup.summary(warning: Self.warning,
                explanation: "Klarschiff 2 entfernt nur Einträge in deinem eigenen temporären Ordner, die seit mehr als 3 Tagen unverändert sind."),
            risk: .review, method: .delete, items: items, size: items.reduce(0) { $0 + ($1.size ?? 0) },
            blockingApps: [], keepSuggested: false,
            commandPreview: items.compactMap(\.url).map { "rm -rf " + ShellQuote.quote($0.path) },
            needsFullDiskAccess: false)]
    }

    /// `true`, wenn nichts unter `root` (auch Symlinks, lstat) jünger als `cutoff` ist. Unlesbar → `false`.
    static func allOlder(_ root: URL, than cutoff: Date) throws -> Bool {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root.path) else { return false }
        var count = 0
        while en.nextObject() != nil {
            count += 1
            if count % 500 == 0 { try Task.checkCancellation() }
            guard let attrs = en.fileAttributes, let date = attrs[.modificationDate] as? Date else { return false }
            if date >= cutoff { return false }
        }
        return true
    }
}

// MARK: - /Library/Caches

struct LibraryCachesScanner: Scanner {
    let id = "sysdata.libraryCaches"
    static let root = "/Library/Caches"
    static let warning = "macOS und Apps bauen diese Caches neu auf. Der erste Start einiger Apps dauert danach länger – ein Neustart wird empfohlen."
    /// Genau die drei Ausnahmen aus Spec §5 (kleingeschrieben, das Dateisystem ist nicht zwischen Groß-/Kleinschreibung unterscheidend).
    static let excluded: Set<String> = [
        "com.apple.iconservices.store", "com.apple.aned", "com.apple.amsengagementd.classicdatavault",
    ]

    func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let base = ctx.absolute(Self.root)
        guard SystemCleanup.type(base.path) == .typeDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return [] }
        var items: [FindingItem] = []
        var steps: [AdminStep] = []
        for name in names.sorted() where SystemCleanup.isSafeName(name) && !Self.excluded.contains(name.lowercased()) {
            try Task.checkCancellation()
            let url = base.appending(path: name)
            guard let type = SystemCleanup.type(url.path), type == .typeDirectory || type == .typeRegular else { continue }
            let m = try await SystemCleanup.measure(url, ctx)
            items.append(FindingItem(
                id: url.path, url: url, name: name, size: m.complete ? m.size : nil,
                detail: m.complete ? nil : "Größe nicht vollständig messbar"))
            steps.append(AdminStep(executable: "/bin/rm", arguments: ["-rf", "\(Self.root)/\(name)"]))
        }
        guard !items.isEmpty else { return [] }
        let allKnown = items.allSatisfy { $0.size != nil }
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .systemData,
            title: "Systemweite Caches",
            summary: SystemCleanup.summary(warning: Self.warning,
                explanation: "Entfernt die Cache-Ordner in /Library/Caches (ohne drei geschützte Apple-Ordner). Zum Entfernen fragt macOS einmal nach deinem Passwort."),
            risk: .review, method: .admin(steps), items: items,
            size: allKnown ? items.reduce(0) { $0 + ($1.size ?? 0) } : nil,
            blockingApps: [], keepSuggested: false,
            commandPreview: TeXLiveScanner.adminPreview(steps), needsFullDiskAccess: false)]
    }
}

// MARK: - /Library/Logs

struct LibraryLogsScanner: Scanner {
    let id = "sysdata.libraryLogs"
    static let root = "/Library/Logs"
    static let warning = "Alte Protokolle helfen bei der Fehlersuche. Danach sind sie weg."

    /// Systemkonto = uid/gid < 500 (in Tests ersetzbar, weil Fixture-Ordner dem Testbenutzer gehören).
    let isSystemAccount: @Sendable (UInt) -> Bool

    init(isSystemAccount: @escaping @Sendable (UInt) -> Bool = { $0 < 500 }) {
        self.isSystemAccount = isSystemAccount
    }

    /// Ordner gehört einem Systemkonto und ist nie für „alle“, für die Gruppe nur bei einer Systemgruppe beschreibbar.
    private func isTrustedDirectory(_ attrs: [FileAttributeKey: Any]) -> Bool {
        guard let uid = (attrs[.ownerAccountID] as? NSNumber)?.uintValue,
              let gid = (attrs[.groupOwnerAccountID] as? NSNumber)?.uintValue,
              let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
        return isSystemAccount(uid)
            && mode & UInt16(S_IWOTH) == 0
            && (mode & UInt16(S_IWGRP) == 0 || isSystemAccount(gid))
    }

    func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let base = ctx.absolute(Self.root)
        guard SystemCleanup.type(base.path) == .typeDirectory else { return [] }
        let cutoff = ctx.now.addingTimeInterval(-30 * SystemCleanup.day)
        var found: [(url: URL, real: String, date: Date)] = []
        try walk(url: base, real: Self.root, cutoff: cutoff, into: &found)
        guard !found.isEmpty else { return [] }
        found.sort { $0.real < $1.real }

        var items: [FindingItem] = []
        var steps: [AdminStep] = []
        for f in found {
            try Task.checkCancellation()
            let size = try? await ctx.sizer.size(of: f.url)
            items.append(FindingItem(id: f.url.path, url: f.url, name: f.url.lastPathComponent, size: size, date: f.date))
            steps.append(AdminStep(executable: "/bin/rm", arguments: ["-f", f.real]))
        }
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .systemData,
            title: "Alte System-Protokolle",
            summary: SystemCleanup.summary(warning: Self.warning,
                explanation: "Entfernt Protokolldateien in /Library/Logs, die seit mehr als 30 Tagen unverändert sind. Zum Entfernen fragt macOS einmal nach deinem Passwort."),
            risk: .review, method: .admin(steps), items: items,
            size: items.reduce(0) { $0 + ($1.size ?? 0) },
            blockingApps: [], keepSuggested: false,
            commandPreview: TeXLiveScanner.adminPreview(steps), needsFullDiskAccess: false)]
    }

    /// Geht Ordner rekursiv durch. In Unterordner steigt er nur, wenn sie einem Systemkonto gehören (sonst könnte ein
    /// Benutzer sie vor dem Löschen gegen einen Symlink tauschen). Unlesbare Ordner werden still übersprungen.
    private func walk(url: URL, real: String, cutoff: Date, into found: inout [(url: URL, real: String, date: Date)]) throws {
        try Task.checkCancellation()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
        for name in names where SystemCleanup.isSafeName(name) {
            let child = url.appending(path: name)
            let childReal = "\(real)/\(name)"
            guard let attrs = SystemCleanup.attributes(child.path), let type = attrs[.type] as? FileAttributeType else { continue }
            switch type {
            case .typeRegular:
                if let date = attrs[.modificationDate] as? Date, date < cutoff { found.append((child, childReal, date)) }
            case .typeDirectory:
                guard isTrustedDirectory(attrs) else { continue }
                try walk(url: child, real: childReal, cutoff: cutoff, into: &found)
            default: continue
            }
        }
    }
}

// MARK: - Unified Log

struct UnifiedLogScanner: Scanner {
    let id = "sysdata.unifiedLog"
    static let warning = "Das komplette Systemprotokoll wird gelöscht. Für die Fehlersuche bei Problemen der letzten Tage fehlt es danach."
    static let paths = ["/private/var/db/diagnostics", "/private/var/db/uuidtext"]

    func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let urls = Self.paths.map(ctx.absolute).filter { SystemCleanup.attributes($0.path) != nil }
        guard let first = urls.first else { return [] }
        var total: Int64 = 0
        var complete = urls.count == Self.paths.count
        for url in urls {
            let m = try await SystemCleanup.measure(url, ctx)
            total += m.size
            if !m.complete { complete = false }
        }
        let steps = [AdminStep(executable: "/usr/bin/log", arguments: ["erase", "--all"])]
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .systemData,
            title: "Diagnosedaten (Systemprotokoll)",
            summary: SystemCleanup.summary(warning: Self.warning,
                explanation: "Löscht das Systemprotokoll mit dem Befehl „log erase --all“. Die angezeigte Größe ist eine Untergrenze. Zum Entfernen fragt macOS einmal nach deinem Passwort."),
            risk: .review, method: .admin(steps),
            items: [FindingItem(id: first.path, url: first, name: "Systemprotokoll", size: total,
                                detail: complete ? nil : "mindestens")],
            size: total, blockingApps: [], keepSuggested: false,
            commandPreview: TeXLiveScanner.adminPreview(steps), needsFullDiskAccess: false)]
    }
}

// MARK: - Heruntergeladenes macOS-Update

struct MacUpdateHintScanner: Scanner {
    let id = "sysdata.macUpdate"
    static let assets = "/System/Volumes/Data/System/Library/AssetsV2"
    static let prefix = "com_apple_MobileAsset_MacSoftwareUpdate"

    func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let base = ctx.absolute(Self.assets)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return [] }
        var total: Int64 = 0
        var items: [FindingItem] = []
        for name in names.sorted() where name.hasPrefix(Self.prefix) && SystemCleanup.type(base.appending(path: name).path) == .typeDirectory {
            let url = base.appending(path: name)
            let m = try await SystemCleanup.measure(url, ctx)
            total += m.size
            items.append(FindingItem(id: url.path, url: url, name: name, size: m.size))
        }
        guard total > 0 else { return [] }
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .systemData,
            title: "Heruntergeladenes macOS-Update",
            summary: "Installiere das Update oder warte – macOS räumt die Datei selbst weg. Klarschiff 2 entfernt sie nicht, weil sie zum Update gehört.",
            risk: .hintOnly, method: .hint(.openURL(softwareUpdateURL)), items: items, size: total,
            blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)]
    }
}
