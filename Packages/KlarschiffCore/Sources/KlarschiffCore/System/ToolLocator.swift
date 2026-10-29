import Foundation

public struct ToolLocator: Sendable {
    private let searchPaths: [String]
    private let fileExists: @Sendable (String) -> Bool

    public init(searchPaths: [String], fileExists: @escaping @Sendable (String) -> Bool) {
        self.searchPaths = searchPaths
        self.fileExists = fileExists
    }

    /// Erster Treffer in der Reihenfolge der Suchpfade.
    public func path(for tool: String) -> String? {
        for dir in searchPaths {
            let candidate = dir + "/" + tool
            if fileExists(candidate) { return candidate }
        }
        return nil
    }

    /// Umgebung für ein aufgelöstes Werkzeug: `base` plus `PATH` aus Werkzeug-Ordner, Suchpfaden und Systempfaden.
    /// Aus der GUI gestartet fehlt sonst ein brauchbarer `PATH` (z. B. `#!/usr/bin/env node` bei Homebrew-npm).
    public func environment(for toolPath: String, base: [String: String]) -> [String: String] {
        let home = NSHomeDirectory()
        let toolDir = (toolPath as NSString).deletingLastPathComponent
        let expanded = searchPaths.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        var seen = Set<String>()
        let dirs = ([toolDir] + expanded + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        var env = base
        env["PATH"] = dirs.joined(separator: ":")
        return env
    }

    public static let defaultSearchPaths: [String] = {
        let fixed = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let home = ["~/.cargo/bin", "~/go/bin", "/opt/anaconda3/bin", "/opt/miniconda3/bin",
                    "~/anaconda3/bin", "~/miniconda3/bin", "~/.bun/bin"]
        let h = NSHomeDirectory()
        return fixed + home.map { $0.hasPrefix("~") ? h + $0.dropFirst() : $0 }
    }()

    public static let standard = ToolLocator(
        searchPaths: defaultSearchPaths,
        fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
    )

    public static let brewEnvironment: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    ]

    /// `true` nur, wenn ein vollständiges Xcode gewählt ist (mit reinen Command Line Tools fehlt `xcrun simctl`).
    public static func xcrunAvailable(runner: CommandRunner) async -> Bool {
        guard let r = try? await runner.run("/usr/bin/xcode-select", ["-p"], timeout: .seconds(5), environment: [:]),
              r.succeeded else { return false }
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && !path.hasSuffix("CommandLineTools")
    }
}
