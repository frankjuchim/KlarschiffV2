import Foundation

/// Prüft den Vollzugriff (Datenschutz „Alle Dateien“) durch Lesen geschützter Ordner.
public enum FullDiskAccess {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Gewährt, wenn einer der geschützten Ordner unter `home` lesbar ist.
    public static func isGranted(home: URL) -> Bool {
        let probes = ["Library/Containers/com.apple.stocks", "Library/Safari"]
        return probes.contains { relPath in
            let path = home.appending(path: relPath).path
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        }
    }
}
