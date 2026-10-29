import Foundation

/// Verlauf der Check-Läufe (neueste zuerst, höchstens 52). JSON, atomar geschrieben;
/// fehlende oder defekte Datei ergibt einen leeren Verlauf. Vor jedem Schreiben wird die
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

    public func append(_ s: CheckSnapshot) throws {
        var entries = load().filter { $0.date != s.date }
        entries.append(s)
        entries.sort { $0.date > $1.date }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func load() -> [CheckSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CheckSnapshot].self, from: data) else { return [] }
        return decoded.sorted { $0.date > $1.date }
    }
}
