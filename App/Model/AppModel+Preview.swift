import Foundation
import KlarschiffCore

// Fake-Daten für SwiftUI-Previews: kein echter Scan, keine echten Befehle, immer Trockenlauf.

extension AppModel {
    /// Modell mit Fake-Abhängigkeiten; der „Scan“ liefert feste Funde (Instruments, iOS-Runtimes, TeX Live …).
    static var preview: AppModel {
        let model = AppModel(dependencies: .preview)
        Task { await model.scan(includeSlowChecks: false) }
        return model
    }
}

extension AppDependencies {
    static var preview: AppDependencies {
        let home = URL(filePath: "/Users/vorschau")
        let disk: @Sendable () throws -> DiskSpace = { DiskSpace(free: 226_320_000_000, total: 494_380_000_000) }
        let runner = RemovalRunner(
            trash: PreviewRemover(), delete: PreviewRemover(), tool: PreviewRemover(),
            admin: AdminRemover(executor: PreviewExecutor(), guard: SafetyGuard.production(home: home)),
            runningApps: PreviewApps(), diskSpace: disk)
        let keepFile = FileManager.default.temporaryDirectory
            .appending(path: "klarschiff-preview-\(UUID().uuidString)").appending(path: "keep.json")
        return AppDependencies(
            engine: ScanEngine(scanners: [
                PreviewScanner(id: "preview.findings", findings: PreviewData.findings),
                PreviewFailingScanner(id: "appCaches.telegram"),
            ]),
            keepList: KeepList(fileURL: keepFile),
            runner: runner,
            diskSpace: disk,
            makeContext: { slow in
                ScanContext(
                    home: home, userCacheDir: home, rootPrefix: home, runner: PreviewCommands(),
                    tools: ToolLocator(searchPaths: [], fileExists: { _ in false }), sizer: SizeMeter(),
                    runningApps: PreviewApps(), claims: PathClaims(), now: Date(), hasFullDiskAccess: false,
                    includeSlowChecks: slow)
            },
            bigChunks: { _, _ in PreviewData.bigChunks },
            photos: { _ in PhotosInfo(librarySize: 33_440_000_000, libraryURL: home.appending(path: "Pictures/Fotos-Mediathek.photoslibrary")) },
            trash: { _ in 279_900_000 },
            fullDiskAccess: { false },
            emptyTrash: { _ in RemovalReport(results: [], freedBytes: 0, failures: []) },
            dryRun: true,
            terminate: { _ in false })
    }
}

private enum PreviewData {
    static let home = URL(filePath: "/Users/vorschau")
    static let claude = AppRef(bundleID: "com.anthropic.claudefordesktop", processName: "Claude", displayName: "Claude")

    static func item(_ path: String, size: Int64?, blocking: AppRef? = nil, date: Date? = nil) -> FindingItem {
        let url = home.appending(path: path)
        return FindingItem(id: path, url: url, name: url.lastPathComponent, size: size, date: date, blockingApp: blocking)
    }

    static func finding(
        _ scanner: String, _ key: String, _ category: KlarschiffCore.Category, _ title: String, _ summary: String,
        risk: Risk, method: RemovalMethod = .trash, items: [FindingItem], size: Int64? = nil,
        blocking: [AppRef] = [], keepSuggested: Bool = false, commands: [String] = [], needsFDA: Bool = false
    ) -> Finding {
        Finding(
            id: FindingID(scannerID: scanner, key: key), category: category, title: title, summary: summary,
            risk: risk, method: method, items: items,
            size: size ?? (needsFDA ? nil : items.reduce(0) { $0 + ($1.size ?? 0) }),
            blockingApps: blocking, keepSuggested: keepSuggested,
            commandPreview: commands.isEmpty ? items.compactMap { $0.url.map { "In den Papierkorb: \($0.path)" } } : commands,
            needsFullDiskAccess: needsFDA)
    }

    static func runtime(_ name: String, _ size: Int64, newest: Bool) -> Finding {
        let cmd = ToolCommand(tool: "xcrun", arguments: ["simctl", "runtime", "delete", name], timeout: .seconds(600))
        return finding(
            "sim.runtimes", name, .simulators, "Simulator-Runtime \(name)",
            "Wird von Xcode bei Bedarf neu geladen. Die neueste Version behältst du am besten.",
            risk: .review, method: .tool([cmd], fallback: nil),
            items: [FindingItem(id: name, name: name, size: size)], keepSuggested: newest, commands: [cmd.display])
    }

    static var findings: [Finding] {
        let updateURL = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
        let cask = ToolCommand(tool: "brew", arguments: ["uninstall", "--cask", "android-studio"], timeout: .seconds(300))
        return [
            finding(
                "ai.claude", "cache", .aiLeftovers, "Claude Desktop – Cache",
                "Browser-Cache der Claude-App. Wird beim nächsten Start neu aufgebaut.",
                risk: .safe,
                items: [item("Library/Application Support/Claude/Cache", size: 46_500_000, blocking: claude)],
                blocking: [claude]),
            finding(
                "appCaches.appStore", "all", .appCaches, "Caches von App-Store-Apps",
                "Zwischenspeicher von Safari und anderen Apps aus dem App Store. Werden bei Bedarf neu aufgebaut.",
                risk: .safe,
                items: (1...14).map { item("Library/Containers/app\($0)/Data/Library/Caches", size: Int64($0) * 2_800_000) }),
            finding(
                "personal.mail", "attachments", .personalData, "Mail-Anhänge",
                "Heruntergeladene Anhänge aus Mail. Mail lädt sie beim Öffnen erneut.",
                risk: .review, items: [item("Library/Containers/com.apple.mail/Data/Library/Mail Downloads", size: nil)],
                needsFDA: true),
            finding(
                "system.snapshots", "update", .system, "Schnappschüsse von macOS-Updates",
                "Diese Schnappschüsse hält macOS für ein ausstehendes Update fest. Sie verschwinden, sobald du das Update installierst und neu startest.",
                risk: .hintOnly, method: .hint(.openURL(updateURL)),
                items: [FindingItem(id: "com.apple.os.update-1", name: "com.apple.os.update-1")]),
            finding(
                "xcode.instruments", "traces", .xcode, "Instruments-Aufzeichnungen",
                "Alte Trace-Dateien aus Instruments. Brauchst du sie nicht mehr, kannst du sie entfernen.",
                risk: .review, items: [item("Library/Application Support/Instruments", size: 102_000_000_000, date: Date(timeIntervalSince1970: 1_700_000_000))]),
            runtime("iOS 18.2", 8_100_000_000, newest: false),
            runtime("iOS 26.0", 9_400_000_000, newest: true),
            finding(
                "toolchains.texlive", "2022", .toolchains, "TeX Live 2022",
                "Ältere TeX-Live-Version. Die neuere Version ist installiert.",
                risk: .review, items: [FindingItem(id: "2022", url: URL(filePath: "/usr/local/texlive/2022"), name: "2022", size: 5_200_000_000)]),
            finding(
                "brew.cask", "android-studio", .homebrew, "Android Studio (Homebrew)",
                "Seit über einem Jahr nicht geöffnet. Homebrew entfernt die App sauber.",
                risk: .review, method: .tool([cask], fallback: nil),
                items: [FindingItem(id: "android-studio", name: "Android Studio", size: 3_100_000_000)],
                commands: [cask.display]),
        ]
    }

    static var bigChunks: [BigChunk] {
        [
            BigChunk(url: home.appending(path: "Pictures"), displayName: "Bilder", size: 33_440_000_000, cleanableSize: 0),
            BigChunk(url: home.appending(path: "Library/Application Support/Claude"), displayName: "Claude", size: 13_060_000_000, cleanableSize: 12_040_000_000),
            BigChunk(url: URL(filePath: "/Applications/Xcode.app"), displayName: "Xcode", size: 4_140_000_000, cleanableSize: 0),
        ]
    }
}

private struct PreviewScanner: KlarschiffCore.Scanner {
    let id: String
    let findings: [Finding]
    func scan(_ ctx: ScanContext) async throws -> [Finding] { findings }
}

private struct PreviewFailure: LocalizedError {
    var errorDescription: String? { "Ordner ist nicht lesbar." }
}

private struct PreviewFailingScanner: KlarschiffCore.Scanner {
    let id: String
    func scan(_ ctx: ScanContext) async throws -> [Finding] { throw PreviewFailure() }
}

private struct PreviewApps: RunningApps {
    func running(_ refs: [AppRef]) -> [AppRef] { [] }
    func terminate(_ ref: AppRef) async -> Bool { false }
}

private struct PreviewCommands: CommandRunner {
    func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]) async throws -> CommandResult {
        CommandResult(exitCode: 127, stdout: "", stderr: "")
    }
}

/// Entfernt nichts, meldet jeden Eintrag als „Trockenlauf“.
private struct PreviewRemover: Remover {
    func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] {
        items.map { ItemResult(findingID: finding.id, itemID: $0.id, outcome: .skipped("Trockenlauf")) }
    }
}

private struct PreviewExecutor: PrivilegedExecutor {
    func run(_ steps: [AdminStep]) async -> AdminRunResult { .cancelled }
}
