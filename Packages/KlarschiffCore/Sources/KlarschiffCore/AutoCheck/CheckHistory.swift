import Foundation

/// Verlauf der Check-Läufe (neueste zuerst, höchstens 52). JSON, atomar geschrieben;
/// fehlende oder defekte Datei ergibt einen leeren Verlauf. Eine defekte Datei wird vor dem nächsten Schreiben
/// nach `history.json.bad` verschoben (ältere `.bad` wird ersetzt), nie stillschweigend überschrieben. Vor jedem Schreiben wird die
/// Datei neu gelesen, damit parallele Prozesse (App und `--check`) sich nicht überschreiben.
public actor CheckHistory {
    public static let maxEntries = 52
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(home: URL) -> URL {
        home.appending(path: "Library/Application Support/Klarschiff2/history.json")
    }

    public func all() -> [CheckSnapshot] { load() }

    public func latest() -> CheckSnapshot? { load().first }

    public var backupURL: URL { fileURL.appendingPathExtension("bad") }

    public func append(_ s: CheckSnapshot) throws {
        let fm = FileManager.default
        let existing = read()
        if case .corrupt = existing {
            if fm.fileExists(atPath: backupURL.path) { try fm.removeItem(at: backupURL) }
            try fm.moveItem(at: fileURL, to: backupURL)
        }
        var entries = (existing.entries ?? []).filter { $0.date != s.date }
        entries.append(s)
        entries.sort { $0.date > $1.date }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private enum Contents {
        case missing, corrupt, valid([CheckSnapshot])
        var entries: [CheckSnapshot]? { if case .valid(let e) = self { e } else { nil } }
    }

    private func read() -> Contents {
        guard let data = try? Data(contentsOf: fileURL) else {
            // Vorhanden, aber unlesbar, gilt ebenfalls als defekt.
            return FileManager.default.fileExists(atPath: fileURL.path) ? .corrupt : .missing
        }
        guard let decoded = try? JSONDecoder().decode([CheckSnapshot].self, from: data) else { return .corrupt }
        return .valid(decoded.sorted { $0.date > $1.date })
    }

    private func load() -> [CheckSnapshot] { read().entries ?? [] }
}
