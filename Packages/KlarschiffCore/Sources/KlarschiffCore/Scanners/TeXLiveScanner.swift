import Foundation

/// TeX Live: ältere Jahrgänge einzeln, dazu „komplett entfernen“. Beides braucht Administratorrechte.
/// Gemessen wird unter dem Wurzel-Präfix, die Admin-Schritte nennen immer die echten absoluten Pfade.
public struct TeXLiveScanner: Scanner {
    public let id = "toolchains.texlive"
    public init() {}

    static let root = "/usr/local/texlive"
    static let completePaths = ["/usr/local/texlive", "/Library/TeX", "/Applications/TeX"]

    static func adminPreview(_ steps: [AdminStep]) -> [String] {
        steps.map { "sudo " + ([$0.executable] + $0.arguments).map(ShellQuote.quote).joined(separator: " ") }
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let base = ctx.absolute(Self.root)
        guard Self.isRealDirectory(base) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        let years = names
            .filter { $0.range(of: #"^\d{4}$"#, options: .regularExpression) != nil && Self.isRealDirectory(base.appending(path: $0)) }
            .compactMap { name in Int(name).map { (year: $0, name: name) } }
            .sorted { $0.year < $1.year }
        let newest = years.last?.year

        var findings: [Finding] = []
        for entry in years where entry.year != newest {
            try Task.checkCancellation()
            let url = base.appending(path: entry.name)
            let size = try? await ctx.sizer.size(of: url)
            let steps = [AdminStep(executable: "/bin/rm", arguments: ["-rf", "\(Self.root)/\(entry.name)"])]
            findings.append(Finding(
                id: FindingID(scannerID: id, key: entry.name), category: .toolchains,
                title: "TeX Live \(entry.name) (veraltet)",
                summary: "Ein älterer TeX-Live-Jahrgang. Solange der neueste Jahrgang installiert ist, brauchst du ihn nicht mehr. Zum Entfernen fragt macOS einmal nach deinem Passwort.",
                risk: .review, method: .admin(steps),
                items: [FindingItem(id: url.path, url: url, name: entry.name, size: size)],
                size: size, blockingApps: [], keepSuggested: false,
                commandPreview: Self.adminPreview(steps), needsFullDiskAccess: false))
        }

        var items: [FindingItem] = []
        var steps: [AdminStep] = []
        for real in Self.completePaths {
            try Task.checkCancellation()
            let url = ctx.absolute(real)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = try? await ctx.sizer.size(of: url)
            items.append(FindingItem(id: url.path, url: url, name: real, size: size))
            steps.append(AdminStep(executable: "/bin/rm", arguments: ["-rf", real]))
        }
        findings.append(Finding(
            id: FindingID(scannerID: id, key: "complete"), category: .toolchains,
            title: "TeX Live komplett entfernen",
            summary: "Entfernt TeX Live mit allen Jahrgängen samt Resten in /Library/TeX und /Applications/TeX. Alternative: das viel kleinere BasicTeX (brew install --cask basictex). Zum Entfernen fragt macOS einmal nach deinem Passwort.",
            risk: .review, method: .admin(steps), items: items,
            size: items.compactMap(\.size).reduce(0, +), blockingApps: [], keepSuggested: false,
            commandPreview: Self.adminPreview(steps), needsFullDiskAccess: false))
        return findings
    }
}
