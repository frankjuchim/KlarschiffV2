import Foundation

public struct BigChunk: Sendable, Identifiable {
    public var id: URL { url }
    public var url: URL
    public var displayName: String
    public var size: Int64
    public var cleanableSize: Int64

    public init(url: URL, displayName: String, size: Int64, cleanableSize: Int64) {
        self.url = url
        self.displayName = displayName
        self.size = size
        self.cleanableSize = cleanableSize
    }
}

/// Läuft nach der ScanEngine (kein `Scanner`): Kinder großer Wurzeln über 1 GB.
public struct BigChunksScanner: Sendable {
    let sizeOf: (@Sendable (URL) async throws -> Int64)?
    static let threshold: Int64 = 1_000_000_000

    /// `sizeOf` nil: `ctx.sizer`.
    public init(sizeOf: (@Sendable (URL) async throws -> Int64)? = nil) {
        self.sizeOf = sizeOf
    }

    public func scan(_ ctx: ScanContext, findings: [Finding]) async -> [BigChunk] {
        let roots: [(url: URL, skip: Set<String>)] = [
            (ctx.home, ["Library"]),
            (ctx.homePath("Library/Application Support"), []),
            (ctx.homePath("Library/Containers"), []),
            (ctx.homePath("Library/Group Containers"), []),
            (ctx.homePath("Library/Developer"), []),
            (ctx.absolute("/Applications"), []),
            (ctx.absolute("/Library/Developer"), []),
            (ctx.absolute("/opt"), []),
            (ctx.absolute("/usr/local"), []),
        ]
        let cleanable = findings.filter { $0.risk != .hintOnly }
        var chunks: [BigChunk] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.url.path) else { continue }
            for name in names.sorted() where !root.skip.contains(name) {
                if Task.isCancelled { return chunks.sorted { $0.size > $1.size } }
                let url = root.url.appending(path: name)
                let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
                guard type != .typeSymbolicLink else { continue }
                let size: Int64
                do {
                    if let sizeOf { size = try await sizeOf(url) } else { size = try await ctx.sizer.size(of: url) }
                } catch { continue }
                guard size > Self.threshold else { continue }
                // Überlappende Funde (z. B. TeX komplett + Jahrgänge) können mehr als den Ordner melden.
                let claimed = await ctx.claims.claimedSize(under: url, findings: cleanable)
                chunks.append(BigChunk(
                    url: url, displayName: FileManager.default.displayName(atPath: url.path), size: size,
                    cleanableSize: min(claimed, size)))
            }
        }
        return chunks.sorted { $0.size > $1.size }
    }
}
