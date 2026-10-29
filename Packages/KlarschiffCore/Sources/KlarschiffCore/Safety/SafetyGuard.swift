import Foundation

public enum SafetyVerdict: Equatable, Sendable {
    case allowed
    case denied(String)
}

/// Letzte Verteidigungslinie: jeder Pfad wird vor trash/delete/admin-rm geprüft.
/// Alles, was nicht ausdrücklich erlaubt ist, wird verweigert.
public struct SafetyGuard: Sendable {
    public static let defaultAllowedCacheSubdirs: Set<String> = [
        "com.apple.dt.Instruments", "com.apple.dt.InstrumentsCLI", "clang",
        "org.llvm.clang", "org.llvm.clang.ModuleCache",
    ]

    private let homeParts: [String]
    private let cacheParts: [String]
    private let allowedCache: Set<String>

    private static let reasonSystem = "Geschützter Systemordner"
    private static let reasonCreds = "Zugangsdaten werden nie angefasst"
    private static let reasonBrew = "Nur über Homebrew entfernbar"
    private static let reasonOutside = "Liegt außerhalb der erlaubten Ordner"
    private static let reasonSymlink = "Symlink zeigt aus dem erlaubten Ordner heraus"
    private static let reasonHome = "Persönlicher Ordner – wird nie angefasst"

    private static let credentialDirs: Set<String> = [".ssh", ".gnupg", ".aws", ".kube", ".config"]
    private static let toolDirs: Set<String> = [".codex", ".gemini", ".copilot"]
    private static let credentialPatterns = [
        "auth*.json", "credentials*", "config*", "*.toml", ".env", ".env.*", "oauth*", "token*", "keychain*",
    ]
    private static let absoluteRoots: [[String]] = [
        ["usr", "local", "texlive"], ["library", "tex"], ["applications", "tex"],
        ["opt", "anaconda3"], ["opt", "miniconda3"], ["library", "developer", "xcode"],
    ]

    public init(home: URL, userCacheDir: URL, allowedCacheSubdirs: Set<String>) {
        homeParts = Self.canonicalPhysical(home.path).map { $0.lowercased() }
        cacheParts = Self.canonicalPhysical(userCacheDir.path).map { $0.lowercased() }
        allowedCache = Set(allowedCacheSubdirs.map { $0.lowercased() })
    }

    /// Produktiv-Variante: `DARWIN_USER_CACHE_DIR` per `confstr`.
    public static func production(home: URL = URL(filePath: NSHomeDirectory())) -> SafetyGuard {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
        let cache = n > 0 ? URL(filePath: String(cString: buf)) : URL(filePath: "/var/empty/klarschiff-no-cache-dir")
        return SafetyGuard(home: home, userCacheDir: cache, allowedCacheSubdirs: defaultAllowedCacheSubdirs)
    }

    public func check(_ url: URL) -> SafetyVerdict {
        let raw = url.path
        guard raw.hasPrefix("/") else { return .denied(Self.reasonOutside) }

        let lexical = Self.aliased(Self.normalize(raw.split(separator: "/").map(String.init)))
        let lexicalLower = lexical.map { $0.lowercased() }
        let verdict = evaluate(lexicalLower)
        if case .denied = verdict { return verdict }

        // Aufgelöste Formen (Symlinks); beide müssen erlaubt sein.
        var resolvedForms: [[String]] = []
        resolvedForms.append(Self.canonicalPhysical(Self.path(lexical)).map { $0.lowercased() })
        resolvedForms.append(Self.canonicalPhysical(raw).map { $0.lowercased() })
        for form in resolvedForms where form != lexicalLower {
            if case .denied(let reason) = evaluate(form) {
                // Credential-/Homebrew-Gründe bleiben aussagekräftig, sonst Symlink-Hinweis.
                let keep = [Self.reasonCreds, Self.reasonBrew]
                return .denied(keep.contains(reason) ? reason : Self.reasonSymlink)
            }
        }
        return .allowed
    }

    // MARK: - Regeln (Komponenten bereits klein geschrieben, normalisiert, kanonisch)

    private func evaluate(_ p: [String]) -> SafetyVerdict {
        // Globale Verbote – gelten überall, auch innerhalb erlaubter Wurzeln.
        if p.contains("caskroom") || p.contains("cellar") { return .denied(Self.reasonBrew) }
        if Self.hasPrefix(p, ["system", "volumes", "data", "system", "library", "assetsv2"]) {
            return .denied("Nur über simctl entfernbar")
        }

        if let rel = Self.relative(p, to: homeParts) { return evaluateHome(rel) }

        if let rel = Self.relative(p, to: cacheParts) {
            if let first = rel.first, allowedCache.contains(first) { return .allowed }
            return .denied(Self.reasonSystem)
        }

        for root in Self.absoluteRoots where Self.hasPrefix(p, root) { return .allowed }

        if p.count >= 2, p[0] == "applications", p[1].hasSuffix(".app") { return .allowed }

        return .denied(Self.defaultReason(p))
    }

    private func evaluateHome(_ rel: [String]) -> SafetyVerdict {
        guard let first = rel.first else { return .denied(Self.reasonHome) }
        if Self.credentialDirs.contains(first) { return .denied(Self.reasonCreds) }
        if first == ".docker", rel.count >= 2, rel[1] == "config.json" { return .denied(Self.reasonCreds) }
        if first == "library", rel.count == 1 { return .denied(Self.reasonHome) }
        if first == "library", rel.count >= 2, rel[1] == "keychains" { return .denied(Self.reasonCreds) }
        if first == "documents" || first == "desktop" { return .denied(Self.reasonHome) }
        if rel.contains(where: { $0.hasSuffix(".photoslibrary") }) { return .denied("Fotos-Mediathek wird nie angefasst") }
        if Self.toolDirs.contains(first) {
            if rel.count == 1 { return .denied(Self.reasonCreds) }
            for comp in rel.dropFirst() where Self.matchesCredential(comp) { return .denied(Self.reasonCreds) }
        }
        return .allowed
    }

    private static func matchesCredential(_ name: String) -> Bool {
        credentialPatterns.contains { fnmatch($0, name, 0) == 0 }
    }

    private static func defaultReason(_ p: [String]) -> String {
        if p.isEmpty { return reasonSystem }
        let systemFirst: Set<String> = ["system", "usr", "bin", "sbin", "private", "var", "etc", "tmp", "library", "applications"]
        return systemFirst.contains(p[0]) ? reasonSystem : reasonOutside
    }

    // MARK: - Pfad-Helfer

    private static func hasPrefix(_ p: [String], _ prefix: [String]) -> Bool {
        p.count >= prefix.count && Array(p.prefix(prefix.count)) == prefix
    }

    private static func relative(_ p: [String], to root: [String]) -> [String]? {
        hasPrefix(p, root) ? Array(p.dropFirst(root.count)) : nil
    }

    private static func path(_ parts: [String]) -> String { "/" + parts.joined(separator: "/") }

    /// Entfernt `.`/`..` rein lexikalisch.
    private static func normalize(_ parts: [String]) -> [String] {
        var out: [String] = []
        for c in parts {
            if c == "." || c.isEmpty { continue }
            if c == ".." { _ = out.popLast(); continue }
            out.append(c)
        }
        return out
    }

    /// `/var`, `/tmp`, `/etc` sind Symlinks nach `/private/...`.
    private static func aliased(_ parts: [String]) -> [String] {
        guard let f = parts.first, ["var", "tmp", "etc"].contains(f.lowercased()) else { return parts }
        return ["private"] + parts
    }

    /// `realpath(3)` auf dem tiefsten existierenden Vorfahren, Rest wird angehängt.
    private static func canonicalPhysical(_ path: String) -> [String] {
        var parts = path.split(separator: "/").map(String.init)
        var remainder: [String] = []
        while true {
            let candidate = "/" + parts.joined(separator: "/")
            if let r = realpath(candidate, nil) {
                let resolved = String(cString: r)
                free(r)
                let base = resolved.split(separator: "/").map(String.init)
                return aliased(normalize(base + remainder))
            }
            guard let last = parts.popLast() else { return aliased(normalize(remainder)) }
            remainder.insert(last, at: 0)
        }
    }
}
