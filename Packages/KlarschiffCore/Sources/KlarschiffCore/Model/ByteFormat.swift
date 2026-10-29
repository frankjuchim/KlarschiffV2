import Foundation

public enum ByteFormat {
    /// Deutsch formatierte Größe (`.file`-Stil, Locale `de_DE`), z. B. „11,99 GB“.
    /// `ByteCountFormatter` kennt kein `locale`; daher `ByteCountFormatStyle`.
    public static func string(_ bytes: Int64) -> String {
        let raw = bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "de_DE")))
        // Das Format liefert ein geschütztes Leerzeichen; normales Leerzeichen erleichtert Vergleiche und Kopieren.
        return String(raw.map { $0.isWhitespace ? " " : $0 })
    }
}
