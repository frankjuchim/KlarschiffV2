import Foundation

public struct PhotosInfo: Sendable {
    public var librarySize: Int64
    public var libraryURL: URL

    public init(librarySize: Int64, libraryURL: URL) {
        self.librarySize = librarySize
        self.libraryURL = libraryURL
    }
}

/// Größte `~/Pictures/*.photoslibrary` – nur zur Anzeige, keine Löschfunktion.
public func photosInfo(_ ctx: ScanContext) async -> PhotosInfo? {
    let dir = ctx.homePath("Pictures")
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
    var best: PhotosInfo?
    for name in names.sorted() where name.hasSuffix(".photoslibrary") {
        let url = dir.appending(path: name)
        guard let size = try? await ctx.sizer.size(of: url) else { continue }
        if best == nil || size > best!.librarySize { best = PhotosInfo(librarySize: size, libraryURL: url) }
    }
    return best
}

/// Größe von `~/.Trash`; `nil` ohne Vollzugriff (statt fälschlich 0), 0 wenn der Ordner fehlt.
public func trashSize(_ ctx: ScanContext) async -> Int64? {
    guard ctx.hasFullDiskAccess else { return nil }
    let url = ctx.homePath(".Trash")
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
    return try? await ctx.sizer.size(of: url)
}
