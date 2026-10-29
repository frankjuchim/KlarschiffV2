import Foundation

/// Temporärer Dateibaum für Tests; räumt in `deinit` auf.
final class FixtureTree: Sendable {
    /// Aufgelöster Realpfad (z. B. `/private/var/...`).
    let root: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "klarschiff-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func url(_ relPath: String) -> URL { root.appending(path: relPath) }

    private func makeParent(of u: URL) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ relPath: String, bytes: Int) throws -> URL {
        let u = url(relPath)
        try makeParent(of: u)
        try Data(repeating: 0x41, count: bytes).write(to: u)
        return u
    }

    @discardableResult
    func dir(_ relPath: String) throws -> URL {
        let u = url(relPath)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func symlink(_ relPath: String, to target: URL) throws {
        let u = url(relPath)
        try makeParent(of: u)
        try FileManager.default.createSymbolicLink(at: u, withDestinationURL: target)
    }

    func hardlink(_ relPath: String, to existing: URL) throws {
        let u = url(relPath)
        try makeParent(of: u)
        try FileManager.default.linkItem(at: existing, to: u)
    }

    func setModified(_ relPath: String, daysAgo: Int) throws {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url(relPath).path)
    }
}
