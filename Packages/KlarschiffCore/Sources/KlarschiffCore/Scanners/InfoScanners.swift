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

/// Größe der Papierkörbe, die der Finder zeigt: `~/.Trash` (braucht Vollzugriff) plus der iCloud-Drive-Papierkorb
/// `~/Library/Mobile Documents/.Trash` (ohne Vollzugriff lesbar). Fehlende Ordner zählen 0.
/// `nil` nur, wenn der lokale Papierkorb nicht lesbar ist und der iCloud-Papierkorb leer ist (statt fälschlich 0).
public func trashSize(_ ctx: ScanContext) async -> Int64? {
    func size(at url: URL) async -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try? await ctx.sizer.size(of: url)
    }
    let iCloud = await size(at: ctx.homePath("Library/Mobile Documents/.Trash")) ?? 0
    let local = ctx.hasFullDiskAccess ? await size(at: ctx.homePath(".Trash")) : nil
    if let local { return local + iCloud }
    return iCloud > 0 ? iCloud : nil
}
