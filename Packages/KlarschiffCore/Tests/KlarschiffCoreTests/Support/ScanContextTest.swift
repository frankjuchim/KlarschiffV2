import Foundation
@testable import KlarschiffCore

extension ScanContext {
    static func test(
        root: URL = FileManager.default.temporaryDirectory
            .appending(path: "klarschiff-ctx-\(UUID().uuidString)", directoryHint: .isDirectory),
        runner: CommandRunner = FakeCommandRunner(),
        running: Set<String> = [],
        tools: ToolLocator = ToolLocator(searchPaths: [], fileExists: { _ in false }),
        hasFullDiskAccess: Bool = true,
        now: Date = Date(),
        includeSlowChecks: Bool = false
    ) -> ScanContext {
        ScanContext(
            home: root.appending(path: "home", directoryHint: .isDirectory),
            userCacheDir: root.appending(path: "C", directoryHint: .isDirectory),
            rootPrefix: root,
            runner: runner,
            tools: tools,
            sizer: SizeMeter(),
            runningApps: FakeRunningApps(running: running),
            claims: PathClaims(),
            now: now,
            hasFullDiskAccess: hasFullDiskAccess,
            includeSlowChecks: includeSlowChecks
        )
    }
}
