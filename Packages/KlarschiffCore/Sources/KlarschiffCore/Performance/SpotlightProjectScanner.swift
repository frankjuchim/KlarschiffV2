import Foundation

/// Ein großer Projektordner, den Spotlight vermutlich unnötig durchsucht.
public struct SpotlightCandidate: Sendable, Identifiable {
    public let id: String
    public let url: URL
    public let kind: String
    public let size: Int64

    public init(url: URL, kind: String, size: Int64) {
        self.id = url.path
        self.url = url
        self.kind = kind
        self.size = size
    }
}

/// Sucht lesend nach großen Projektordnern (`node_modules`, `.build` …) im Home. Ändert nichts.
public struct SpotlightProjectScanner: Sendable {
    public static let minimumSize: Int64 = 100_000_000
    public static let maxDepth = 6

    private static let plainKinds: Set<String> = [
        "node_modules", ".build", "Pods", ".venv", "venv", "__pycache__", "DerivedData", ".gradle",
    ]

    private let sizeOf: (@Sendable (URL) async throws -> Int64)?
    private let timeLimit: TimeInterval

    public init(sizeOf: (@Sendable (URL) async throws -> Int64)? = nil, timeLimit: TimeInterval = 60) {
        self.sizeOf = sizeOf
        self.timeLimit = timeLimit
    }

    public func scan(_ ctx: ScanContext) async -> [SpotlightCandidate] {
        let deadline = Date().addingTimeInterval(timeLimit)
        let measure: @Sendable (URL) async throws -> Int64 = sizeOf ?? { [sizer = ctx.sizer] in try await sizer.size(of: $0) }
        var found: [(URL, String)] = []
        walk(ctx.home, depth: 0, ctx: ctx, deadline: deadline, into: &found)

        var result: [SpotlightCandidate] = []
        for (url, kind) in found {
            if Task.isCancelled || Date() >= deadline { break }
            guard let size = try? await measure(url), size >= Self.minimumSize else { continue }
            result.append(SpotlightCandidate(url: url, kind: kind, size: size))
        }
        return result.sorted { $0.size != $1.size ? $0.size > $1.size : $0.id < $1.id }
    }

    private func walk(_ dir: URL, depth: Int, ctx: ScanContext, deadline: Date, into found: inout [(URL, String)]) {
        if Task.isCancelled || Date() >= deadline { return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        let names = Set(entries.map(\.lastPathComponent))
        // Ein Ordner mit .metadata_never_index ist samt Inhalt von Spotlight ausgeschlossen.
        if names.contains(".metadata_never_index") { return }

        for entry in entries {
            if Task.isCancelled || Date() >= deadline { return }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { continue }
            let name = entry.lastPathComponent

            if depth == 0 {
                let lower = name.lowercased()
                if lower == "library" || lower == ".trash" { continue }
                if !ctx.hasFullDiskAccess, ["desktop", "documents", "downloads"].contains(lower) { continue }
            }
            if name.hasSuffix(".noindex") { continue }

            if let kind = Self.kind(of: name, siblings: names) {
                // Ausgeschlossene Ordner und Treffer werden nicht betreten.
                if !fm.fileExists(atPath: entry.appending(path: ".metadata_never_index").path) {
                    found.append((entry, kind))
                }
                continue
            }
            if name.hasPrefix(".") || values?.isPackage == true { continue }
            // Einträge von `dir` liegen auf Tiefe depth + 1 (≤ 6); Unterordner nur betreten, solange deren Inhalt ≤ 6 bleibt.
            if depth < Self.maxDepth - 1 {
                walk(entry, depth: depth + 1, ctx: ctx, deadline: deadline, into: &found)
            }
        }
    }

    private static func kind(of name: String, siblings: Set<String>) -> String? {
        if plainKinds.contains(name) { return name }
        if name == "target", siblings.contains("Cargo.toml") { return name }
        if name == "build", siblings.contains("build.gradle") || siblings.contains("CMakeLists.txt") { return name }
        return nil
    }
}
