import Foundation

public struct ScanContext: Sendable {
    public var home: URL
    public var userCacheDir: URL
    /// "/" in Produktion, Fixture-Wurzel in Tests – für absolute Pfade wie /usr/local.
    public var rootPrefix: URL
    public var runner: CommandRunner
    public var tools: ToolLocator
    public var sizer: SizeMeter
    public var runningApps: RunningApps
    public var claims: PathClaims
    public var now: Date
    public var hasFullDiskAccess: Bool

    public init(
        home: URL, userCacheDir: URL, rootPrefix: URL, runner: CommandRunner, tools: ToolLocator,
        sizer: SizeMeter, runningApps: RunningApps, claims: PathClaims, now: Date, hasFullDiskAccess: Bool
    ) {
        self.home = home
        self.userCacheDir = userCacheDir
        self.rootPrefix = rootPrefix
        self.runner = runner
        self.tools = tools
        self.sizer = sizer
        self.runningApps = runningApps
        self.claims = claims
        self.now = now
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    /// Absoluter Pfad unterhalb des Wurzel-Präfixes, z. B. `absolute("/usr/local/texlive")`.
    public func absolute(_ path: String) -> URL { append(path, to: rootPrefix) }
    public func homePath(_ rel: String) -> URL { append(rel, to: home) }
    public func cachePath(_ rel: String) -> URL { append(rel, to: userCacheDir) }

    private func append(_ path: String, to base: URL) -> URL {
        let rel = path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        return rel.isEmpty ? base : base.appending(path: rel)
    }
}
