import Foundation

public struct DeleteRemover: Remover {
    private let safety: SafetyGuard

    public init(guard safety: SafetyGuard) { self.safety = safety }

    public func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] {
        removePathItems(finding, items: items, dryRun: dryRun, guard: safety) { url in
            let fm = FileManager.default
            do {
                try fm.removeItem(at: url)
            } catch where Self.isPermissionError(error) {
                // Schreibgeschützte Bäume (z. B. Go-Modulcache): nur unterhalb des geprüften Pfads beschreibbar machen.
                Self.makeWritable(url.path)
                try fm.removeItem(at: url)
            }
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }

    /// Setzt `u+rwx` (Ordner) bzw. `u+w` (Dateien); folgt keinen Symlinks und ändert sie nicht.
    private static func makeWritable(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK { return }
        if type == S_IFDIR {
            _ = chmod(path, (st.st_mode & 0o7777) | 0o700)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
            for name in names { makeWritable(path + "/" + name) }
        } else if type == S_IFREG {
            _ = chmod(path, (st.st_mode & 0o7777) | 0o200)
        }
    }
}
