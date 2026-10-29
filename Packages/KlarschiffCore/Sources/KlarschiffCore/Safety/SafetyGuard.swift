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
    private let cacheParts: [String]?
    private let tempParts: [String]?
    private let allowedCache: Set<String>
    private let isValid: Bool

    private static let reasonSystem = "Geschützter Systemordner"
    private static let reasonCreds = "Zugangsdaten werden nie angefasst"
    private static let reasonBrew = "Nur über Homebrew entfernbar"
    private static let reasonOutside = "Liegt außerhalb der erlaubten Ordner"
    private static let reasonSymlink = "Symlink zeigt aus dem erlaubten Ordner heraus"
    private static let reasonInvalid = "Ungültige Sicherheitskonfiguration – es wird nichts angefasst"
    private static let reasonUnresolvable = "Pfad lässt sich nicht sicher auflösen"
    private static let reasonHome = "Persönlicher Ordner – wird nie angefasst"

    private static let toolDirs: Set<String> = [".codex", ".gemini", ".copilot"]
    private static let credentialPatterns = [
        "auth*.json", "credentials*", "config*", "*.toml", ".env", ".env.*", "oauth*", "token*", "keychain*",
    ]
    private static let absoluteRoots: [[String]] = [
        ["usr", "local", "texlive"], ["library", "tex"], ["applications", "tex"],
        ["opt", "anaconda3"], ["opt", "miniconda3"], ["library", "developer", "xcode"],
    ]

    /// Fest definierte, geschützte Pfade relativ zu Home. Jeder Vorfahre davon ist ebenfalls gesperrt.
    private static let protectedHomePaths: [[String]] = [
        [".ssh"], [".gnupg"], [".aws"], [".kube"], [".config"], [".docker", "config.json"],
        ["library", "keychains"], ["documents"], ["desktop"],
    ]

    public init(home: URL, userCacheDir: URL, allowedCacheSubdirs: Set<String>, userTempDir: URL? = nil) {
        allowedCache = Set(allowedCacheSubdirs.map { $0.lowercased() })
        let h = Self.canonicalPhysical(home.path)?.map { $0.lowercased() }
        // Home muss unter /Users/<name> oder /private/var/<...> liegen; sonst ist die Konfiguration ungültig.
        var valid = false
        if let h {
            if h.count >= 2, h[0] == "users" { valid = true }
            else if h.count >= 3, h[0] == "private", h[1] == "var", h[2] != "folders" { valid = true }
            else if h.count >= 5, h[0] == "private", h[1] == "var", h[2] == "folders" { valid = true }
        }
        isValid = valid
        homeParts = valid ? h ?? [] : []
        // Cache-Ordner muss unter /private/var/folders/<a>/<b>/<C> liegen; sonst keine Cache-Freigaben.
        if let c = Self.canonicalPhysical(userCacheDir.path)?.map({ $0.lowercased() }),
           c.count >= 6, c[0] == "private", c[1] == "var", c[2] == "folders" {
            cacheParts = c
        } else {
            cacheParts = nil
        }
        // Temp-Ordner (`DARWIN_USER_TEMP_DIR`) gleich validiert; darf nicht der Cache-Ordner sein.
        if let userTempDir,
           let t = Self.canonicalPhysical(userTempDir.path)?.map({ $0.lowercased() }),
           t.count == 6, t[0] == "private", t[1] == "var", t[2] == "folders", t[5] == "t", t != cacheParts {
            tempParts = t
        } else {
            tempParts = nil
        }
    }

    /// Ersatz, wenn `DARWIN_USER_CACHE_DIR` nicht ermittelbar ist (liegt nie unter /private/var/folders → keine Cache-Freigaben).
    public static let missingUserCacheDirectory = URL(filePath: "/var/empty/klarschiff-no-cache-dir")

    /// `DARWIN_USER_CACHE_DIR` per `confstr`; `nil`, wenn nicht ermittelbar.
    /// Einzige Quelle für Scan-Kontext und Guard, damit beide nicht auseinanderlaufen.
    public static func userCacheDirectory() -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
        guard n > 0 else { return nil }
        let text = String(decoding: buf.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        return text.isEmpty ? nil : URL(filePath: text)
    }

    /// `DARWIN_USER_TEMP_DIR` per `confstr`; `nil`, wenn nicht ermittelbar.
    public static func userTempDirectory() -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        guard n > 0 else { return nil }
        let text = String(decoding: buf.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        return text.isEmpty ? nil : URL(filePath: text)
    }

    /// Produktiv-Variante: `DARWIN_USER_CACHE_DIR` per `userCacheDirectory()`.
    public static func production(home: URL = URL(filePath: NSHomeDirectory())) -> SafetyGuard {
        let cache = userCacheDirectory() ?? missingUserCacheDirectory
        return SafetyGuard(home: home, userCacheDir: cache, allowedCacheSubdirs: defaultAllowedCacheSubdirs,
                           userTempDir: userTempDirectory())
    }

    public func check(_ url: URL) -> SafetyVerdict {
        guard isValid else { return .denied(Self.reasonInvalid) }
        let raw = url.path
        guard raw.unicodeScalars.first == "/" else { return .denied(Self.reasonOutside) }

        let lexical = Self.aliased(Self.normalize(Self.split(raw)))
        let lexicalLower = lexical.map { $0.lowercased() }
        let verdict = evaluate(lexicalLower)
        if case .denied = verdict { return verdict }

        // Aufgelöste Formen (Symlinks); beide müssen erlaubt sein.
        guard let r1 = Self.canonicalPhysical(Self.path(lexical)),
              let r2 = Self.canonicalPhysical(raw) else { return .denied(Self.reasonUnresolvable) }
        let resolvedForms = [r1, r2].map { $0.map { $0.lowercased() } }
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

        if let cacheParts, let rel = Self.relative(p, to: cacheParts) {
            if let first = rel.first, allowedCache.contains(first) { return .allowed }
            return .denied(Self.reasonSystem)
        }

        if let tempParts, let rel = Self.relative(p, to: tempParts) {
            return rel.isEmpty ? .denied(Self.reasonSystem) : .allowed
        }

        // Kinder von /Library/Caches und /Library/Logs (nie die Ordner selbst).
        if p.count >= 3, p[0] == "library", p[1] == "caches" || p[1] == "logs" { return .allowed }

        // Direkte `*.plist`-Kinder von /Library/LaunchAgents und /Library/LaunchDaemons (nie die Ordner, keine Unterordner).
        if p.count == 3, p[0] == "library", Self.launchDirs.contains(p[1]), Self.isPlistName(p[2]) { return .allowed }

        for root in Self.absoluteRoots where Self.hasPrefix(p, root) { return .allowed }

        if p.count >= 2, p[0] == "applications", p[1].count > 4, p[1].hasSuffix(".app") { return .allowed }

        return .denied(Self.defaultReason(p))
    }

    private func evaluateHome(_ rel: [String]) -> SafetyVerdict {
        guard let first = rel.first else { return .denied(Self.reasonHome) }
        // Geschützte Pfade: gleich, darunter oder Vorfahre davon.
        for prot in Self.protectedHomePaths {
            if Self.hasPrefix(rel, prot) || Self.hasPrefix(prot, rel) {
                let personal = ["documents", "desktop"].contains(prot[0]) || (prot[0] == "library" && rel.count == 1)
                return .denied(personal ? Self.reasonHome : Self.reasonCreds)
            }
        }
        if rel == ["pictures"] { return .denied(Self.reasonHome) }
        if first == "library", rel.count == 1 { return .denied(Self.reasonHome) }
        if rel.contains(where: { $0.hasSuffix(".photoslibrary") }) { return .denied("Fotos-Mediathek wird nie angefasst") }
        if Self.toolDirs.contains(first) {
            if rel.count == 1 { return .denied(Self.reasonCreds) }
            for comp in rel.dropFirst() where Self.matchesCredential(comp) { return .denied(Self.reasonCreds) }
        }
        return .allowed
    }

    static let launchDirs: Set<String> = ["launchagents", "launchdaemons"]

    /// `<name>.plist` mit nicht-leerem Namen; Vergleich auf Unicode-Skalaren (ein Combining Mark nach `.plist` zählt nicht).
    static func isPlistName(_ lowercasedName: String) -> Bool {
        let scalars = Array(lowercasedName.unicodeScalars)
        let suffix = Array(".plist".unicodeScalars)
        return scalars.count > suffix.count && Array(scalars.suffix(suffix.count)) == suffix
    }

    private static func matchesCredential(_ name: String) -> Bool {
        // Kombinierende Zeichen entfernen, damit „U+0301 + auth.json“ nicht an den Mustern vorbeirutscht.
        let marks: Set<Unicode.GeneralCategory> = [.nonspacingMark, .spacingMark, .enclosingMark]
        let stripped = String(String.UnicodeScalarView(name.unicodeScalars.filter { !marks.contains($0.properties.generalCategory) }))
        return credentialPatterns.contains { fnmatch($0, name, 0) == 0 || fnmatch($0, stripped, 0) == 0 }
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

    /// Trennt auf Unicode-Skalaren (nicht Graphemen): `/` + Combining Mark bleibt ein Trenner, wie im Kernel.
    private static func split(_ s: String) -> [String] {
        s.unicodeScalars.split(separator: "/", omittingEmptySubsequences: true)
            .map { String(String.UnicodeScalarView($0)) }
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
    /// `nil`, wenn die Auflösung aus anderem Grund als „existiert nicht“ scheitert (EACCES, ELOOP …).
    private static func canonicalPhysical(_ path: String) -> [String]? {
        var parts = split(path)
        var remainder: [String] = []
        while true {
            let candidate = "/" + parts.joined(separator: "/")
            if let r = realpath(candidate, nil) {
                let resolved = String(cString: r)
                free(r)
                return aliased(normalize(split(resolved) + remainder))
            }
            guard errno == ENOENT || errno == ENOTDIR else { return nil }
            guard let last = parts.popLast() else { return nil }
            remainder.insert(last, at: 0)
        }
    }
}
