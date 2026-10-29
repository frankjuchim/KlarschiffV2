import Foundation

/// Numerischer Versionsvergleich („3.12.0“ > „3.9.1“). Nutzt die erste Ziffernfolge `\d+(\.\d+)*` im Text.
public enum VersionCompare {
    public static func components(_ s: String) -> [Int]? {
        guard let r = s.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return nil }
        return s[r].split(separator: ".").map { Int($0) ?? 0 }
    }

    /// `true`, wenn `a` echt neuer ist als `b`. Fehlende Komponenten zählen als 0; ohne Zahl nie neuer.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = components(a), let y = components(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
