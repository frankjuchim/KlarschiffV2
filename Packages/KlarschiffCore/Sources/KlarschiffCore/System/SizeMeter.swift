import Foundation

/// Misst belegte Blöcke (nicht logische Größe) von Dateien und Ordnerbäumen.
/// Symlinks werden nie verfolgt; harte Links zählen pro `size(of:)`-Aufruf einmal.
public struct SizeMeter: Sendable {
    public init() {}

    public func size(of url: URL) async throws -> Int64 {
        try Task.checkCancellation()
        return try Self.measure(url)
    }

    public func sizes(of urls: [URL]) async throws -> [URL: Int64] {
        try await withThrowingTaskGroup(of: (URL, Int64).self) { group in
            for url in urls {
                group.addTask { (url, try await self.size(of: url)) }
            }
            var result: [URL: Int64] = [:]
            for try await (url, size) in group { result[url] = size }
            return result
        }
    }

    private static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey,
        .isRegularFileKey, .linkCountKey, .fileResourceIdentifierKey
    ]

    private static func measure(_ root: URL) throws -> Int64 {
        let fm = FileManager.default
        // lstat-artig prüfen, ohne Symlinks zu folgen; fehlender Pfad -> 0.
        guard let attrs = try? fm.attributesOfItem(atPath: root.path) else { return 0 }
        var seen = Set<AnyHashable>()
        var total: Int64 = 0
        let type = attrs[.type] as? FileAttributeType
        if type != .typeDirectory {
            return allocated(of: root, seen: &seen)
        }
        total += allocated(of: root, seen: &seen)
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [], errorHandler: { _, _ in true }) else { return total }
        var count = 0
        for case let item as URL in en {
            count += 1
            if count % 500 == 0 { try Task.checkCancellation() }
            total += allocated(of: item, seen: &seen)
        }
        return total
    }

    /// Belegte Größe eines einzelnen Eintrags (Symlink: Größe des Links selbst, nie des Ziels).
    private static func allocated(of url: URL, seen: inout Set<AnyHashable>) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if v.isSymbolicLink != true, v.isRegularFile == true,
           let links = v.linkCount, links > 1, let id = v.fileResourceIdentifier {
            if !seen.insert(id as! AnyHashable).inserted { return 0 }
        }
        return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }
}
