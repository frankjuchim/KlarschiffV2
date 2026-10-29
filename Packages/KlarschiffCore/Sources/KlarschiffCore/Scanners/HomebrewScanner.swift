import Foundation

private func runBrew(_ ctx: ScanContext, _ brew: String, _ args: [String]) async throws -> String {
    let result = try await ctx.runner.run(brew, args, timeout: .seconds(120), environment: ctx.tools.environment(for: brew, base: ToolLocator.brewEnvironment))
    guard result.succeeded else {
        let excerpt = String(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        throw CommandError.launchFailed("brew \(args.joined(separator: " ")): Exit \(result.exitCode) \(excerpt)")
    }
    return result.stdout
}

private func brewLine(_ out: String) -> String? {
    let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : line
}

/// Erkennt Homebrews Weigerung, aus einem nicht vertrauenswürdigen Tap zu laden.
public enum HomebrewErrors {
    private static let regexes: [NSRegularExpression] = [
        #"untrusted tap\s+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"#,
        #"tap\s+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\s+is not trusted"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Tap-Name (`owner/repo`) oder `nil`, wenn kein Tap-Vertrauensproblem vorliegt.
    public static func untrustedTap(in stderr: String) -> String? {
        for re in regexes {
            guard let m = re.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
                  let r = Range(m.range(at: 1), in: stderr) else { continue }
            var name = String(stderr[r])
            while name.hasSuffix(".") { name.removeLast() }
            return name
        }
        return nil
    }
}

/// `brew cleanup --prune=all` und `brew autoremove` als ein Fund.
public struct HomebrewCleanupScanner: Scanner {
    public let id = "brew.cleanup"
    public init() {}

    private static let removeRegex = try? NSRegularExpression(pattern: #"^Would remove: (.+?) \([^()]*\)$"#)

    static func parseCleanup(_ out: String) -> [String] {
        var paths: [String] = []
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Would remove: ") else { continue }
            let path: String
            if let m = removeRegex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(m.range(at: 1), in: line) {
                path = String(line[r])
            } else {
                path = String(line.dropFirst("Would remove: ".count))
            }
            if !path.isEmpty, !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    static func parseAutoremove(_ out: String) -> [String] {
        var names: [String] = []
        var inList = false
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==>") { inList = line.contains("Would autoremove"); continue }
            if inList, !line.isEmpty, !names.contains(line) { names.append(line) }
        }
        return names
    }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        guard let brew = ctx.tools.path(for: "brew") else { return [] }
        let cleanupOut = try await runBrew(ctx, brew, ["cleanup", "--prune=all", "-n"])
        let autoremoveOut = try await runBrew(ctx, brew, ["autoremove", "-n"])
        let paths = Self.parseCleanup(cleanupOut)
        let formulae = Self.parseAutoremove(autoremoveOut)
        if let cache = brewLine(try await runBrew(ctx, brew, ["--cache"])) {
            await ctx.claims.claim([URL(fileURLWithPath: cache)])
        }
        guard !paths.isEmpty || !formulae.isEmpty else { return [] }

        let prefix = brewLine(try await runBrew(ctx, brew, ["--prefix"])) ?? "/opt/homebrew"

        var items: [FindingItem] = []
        for p in paths {
            let url = URL(fileURLWithPath: p)
            items.append(FindingItem(id: p, url: url, name: url.lastPathComponent, size: try? await ctx.sizer.size(of: url)))
        }
        for name in formulae {
            let url = URL(fileURLWithPath: "\(prefix)/Cellar/\(name)")
            items.append(FindingItem(id: "formula:\(name)", url: url, name: name,
                                     size: try? await ctx.sizer.size(of: url), detail: "nicht mehr benötigt"))
        }

        let cmds = [
            ToolCommand(tool: "brew", arguments: ["cleanup", "--prune=all"], timeout: .seconds(300)),
            ToolCommand(tool: "brew", arguments: ["autoremove"], timeout: .seconds(300)),
        ]
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .homebrew,
            title: "Homebrew aufräumen",
            summary: "Alte Programmversionen, Download-Reste und nicht mehr benötigte Hilfspakete von Homebrew. Homebrew räumt sie selbst auf; bei Bedarf lädt es Pakete neu herunter.",
            risk: .safe, method: .tool(cmds, fallback: nil), items: items,
            size: items.compactMap(\.size).reduce(0, +), blockingApps: [],
            keepSuggested: false, commandPreview: cmds.map(\.display), needsFullDiskAccess: false)]
    }
}

/// Große Homebrew-Casks (Programme) ab 200 MB, je Cask ein Fund.
public struct HomebrewCaskScanner: Scanner {
    public let id = "brew.cask"
    private let sizeOf: (@Sendable (URL) async throws -> Int64)?
    static let minimumSize: Int64 = 200_000_000

    public init(sizeOf: (@Sendable (URL) async throws -> Int64)? = nil) {
        self.sizeOf = sizeOf
    }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        guard let brew = ctx.tools.path(for: "brew") else { return [] }
        let prefix = brewLine(try await runBrew(ctx, brew, ["--prefix"])) ?? "/opt/homebrew"
        let names = try await runBrew(ctx, brew, ["list", "--cask"])
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let measure = sizeOf ?? { [sizer = ctx.sizer] in try await sizer.size(of: $0) }

        var findings: [Finding] = []
        for name in names {
            let url = URL(fileURLWithPath: "\(prefix)/Caskroom/\(name)")
            guard let size = try? await measure(url), size >= Self.minimumSize else { continue }
            let cmd = ToolCommand(tool: "brew", arguments: ["uninstall", "--cask", name], timeout: .seconds(300))
            findings.append(Finding(
                id: FindingID(scannerID: id, key: name), category: .homebrew,
                title: "\(name) (Homebrew-Cask)",
                summary: "Ein über Homebrew installiertes Programm. Es wird sauber über Homebrew deinstalliert; optional lassen sich auch seine Einstellungen und Daten entfernen („inkl. Einstellungen (zap)“).",
                risk: .review, method: .tool([cmd], fallback: nil),
                items: [FindingItem(id: name, url: url, name: name, size: size)],
                size: size, blockingApps: [], keepSuggested: false,
                commandPreview: [cmd.display], needsFullDiskAccess: false))
        }
        return findings
    }
}
