import Foundation

/// Dauerhaft „Behalten“-markierte Funde. JSON-Datei, atomar geschrieben;
/// fehlende oder defekte Datei ergibt eine leere Liste.
public actor KeepList {
    private let fileURL: URL
    private var ids: Set<FindingID>

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([FindingID].self, from: data) {
            ids = Set(decoded)
        } else {
            ids = []
        }
    }

    public static func defaultFileURL(home: URL) -> URL {
        home.appending(path: "Library/Application Support/Klarschiff2/keep.json")
    }

    public var all: Set<FindingID> { ids }

    public func contains(_ id: FindingID) -> Bool { ids.contains(id) }

    public func add(_ id: FindingID) throws {
        var next = ids
        next.insert(id)
        try persist(next)
        ids = next
    }

    public func remove(_ id: FindingID) throws {
        var next = ids
        next.remove(id)
        try persist(next)
        ids = next
    }

    private func persist(_ set: Set<FindingID>) throws {
        let sorted = set.sorted { ($0.scannerID, $0.key) < ($1.scannerID, $1.key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sorted)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
