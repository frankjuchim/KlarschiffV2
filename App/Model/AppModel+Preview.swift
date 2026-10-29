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
            measureSystemData: { _, _ in PreviewSystemData.report },
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

/// Fake-Systemdaten in Franks Größenordnungen (Deine Daten 248 GB, AssetsV2 33 GB, `/private/var/db` 7 GB,
/// Simulator-Volume 18 GB). Erklärungen kurz gehalten; die echten stehen im Katalog.
private enum PreviewSystemData {
    static let gb: Int64 = 1_000_000_000

    static func area(_ id: String, _ path: String, _ title: String, _ summary: String, _ verdict: AreaVerdict,
                     _ size: Int64?, lower: Bool = false, children: [SystemArea] = []) -> SystemArea {
        SystemArea(id: id, url: URL(filePath: path), title: title, summary: summary, verdict: verdict,
                   size: size, isLowerBound: lower, children: children)
    }

    static func cleanup(_ scanner: String, _ title: String, _ explanation: String, method: RemovalMethod,
                        paths: [(String, Int64)]) -> Finding {
        let items = paths.map { FindingItem(id: $0.0, url: URL(filePath: $0.0), name: URL(filePath: $0.0).lastPathComponent, size: $0.1) }
        return Finding(
            id: FindingID(scannerID: scanner, key: "all"), category: .systemData, title: title,
            summary: "Achtung: \(SystemCleanup.warning(for: scanner) ?? "") \(explanation)",
            risk: .review, method: method, items: items, size: items.reduce(0) { $0 + ($1.size ?? 0) },
            blockingApps: [], keepSuggested: false, commandPreview: items.map { "rm -rf \($0.id)" },
            needsFullDiskAccess: false)
    }

    static var report: SystemDataReport {
        let updateURL = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
        let areas: [SystemArea] = [
            area("var.folders", "/private/var/folders", "Benutzer-Ordner des Systems",
                 "Hier legt macOS pro Benutzer Caches und temporäre Dateien ab.", .keep, 12 * gb, children: [
                    area("var.folders.caches", "/private/var/folders/*/*/C", "Benutzer-Caches (System)",
                         "Zwischenspeicher von macOS und Programmen. Instruments- und Clang-Caches daraus findest du im Tab Entwickler.",
                         .keep, 9 * gb),
                    area("var.folders.temp", "/private/var/folders/*/*/T", "Temporäre Dateien",
                         "Arbeitsdateien von Programmen.", .cleanable, 2_400_000_000),
                    area("var.folders.other", "/private/var/folders", "Sonstige Systemordner",
                         "Alles in „Benutzer-Ordner des Systems“, was nicht zu den Bereichen darüber gehört.", .keep, 600_000_000),
                 ]),
            area("var.vm", "/private/var/vm", "Auslagerung & Ruhezustand",
                 "macOS lagert hier Arbeitsspeicher aus. Bitte nicht anfassen.", .keep, 4 * gb),
            area("var.db", "/private/var/db", "System-Datenbanken",
                 "Datenbanken und Protokolle, die macOS im Hintergrund pflegt.", .keep, 7 * gb, lower: true, children: [
                    area("var.db.diagnostics", "/private/var/db/diagnostics", "Diagnosedaten (Systemprotokoll)",
                         "Das Systemprotokoll von macOS samt Zuordnungsdateien.", .cleanable, 2_100_000_000),
                    area("var.db.other", "/private/var/db", "Weitere System-Datenbanken",
                         "Alles in „System-Datenbanken“, was nicht zu den Bereichen darüber gehört.", .keep, 4_900_000_000, lower: true),
                 ]),
            area("library", "/Library", "Systemweite Bibliothek",
                 "Einstellungen und Komponenten, die für alle Benutzer dieses Macs gelten.", .keep, 9 * gb, children: [
                    area("library.caches", "/Library/Caches", "Systemweite Caches",
                         "Zwischenspeicher, den macOS und Apps für alle Benutzer anlegen.", .cleanable, 1_800_000_000),
                    area("library.logs", "/Library/Logs", "System-Protokolle",
                         "Protokolldateien von macOS und Programmen.", .cleanable, 700_000_000),
                    area("developer", "/Library/Developer", "Entwicklerwerkzeuge",
                         "Command Line Tools und Simulator-Laufzeiten.",
                         .seeFinding(scannerID: "xcode.libraryDeveloper", tab: .developer), 4_200_000_000),
                    area("library.other", "/Library", "Systemweite Einstellungen & Komponenten",
                         "Alles in „Systemweite Bibliothek“, was nicht zu den Bereichen darüber gehört.", .keep, 2_300_000_000),
                 ]),
            area("assets", "/System/Volumes/Data/System/Library/AssetsV2", "macOS-Komponenten (Assets)",
                 "Von macOS nachgeladene Zusatzdaten wie Sprachmodelle, Schriften und Simulator-Laufzeiten.", .keep, 33 * gb, children: [
                    area("assets.com_apple_MobileAsset_iOSSimulatorRuntime", "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime",
                         "iOS-Simulator", "Laufzeit für den iOS-Simulator.",
                         .seeFinding(scannerID: "sim.runtimes", tab: .developer), 21 * gb),
                    area("assets.com_apple_MobileAsset_MacSoftwareUpdate", "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate",
                         "Heruntergeladenes macOS-Update", "Ein von macOS vorab geladenes Update.", .keep, 8 * gb),
                    area("assets.com_apple_MobileAsset_UAF_Siri_Understanding", "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_Understanding",
                         "Siri-Sprachdaten", "Sprachmodelle für Siri.", .keep, 4 * gb),
                 ]),
            area("opt", "/opt", "Zusatzsoftware", "Programme, die du nachinstalliert hast, zum Beispiel Homebrew.",
                 .seeFinding(scannerID: "brew.cleanup", tab: .developer), 6 * gb),
            area("usrlocal", "/usr/local", "Zusatzsoftware (/usr/local)", "Programme und Bibliotheken, die nicht zu macOS gehören.",
                 .keep, nil, lower: true),
        ]
        let systemTotal = areas.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let inventory = VolumeInventoryResult(
            containerSize: 494_380_000_000, containerFree: 80 * gb,
            volumes: [
                APFSVolume(name: "Macintosh HD", role: .system, consumed: 11 * gb),
                APFSVolume(name: "Preboot", role: .preboot, consumed: 7 * gb),
                APFSVolume(name: "Recovery", role: .recovery, consumed: 1_300_000_000),
                APFSVolume(name: "VM", role: .vm, consumed: 4 * gb),
                APFSVolume(name: "Macintosh HD - Daten", role: .data, consumed: 390 * gb),
            ],
            simulatorVolumes: [APFSVolume(name: "iOS 26.0 Simulator", role: .simulator, consumed: 18 * gb)])
        let userData: Int64 = 248 * gb
        let tm = Finding(
            id: FindingID(scannerID: "system.snapshots", key: "timeMachine"), category: .system,
            title: "Time-Machine-Schnappschüsse", summary: "Lokale Kopien deiner Time-Machine-Sicherung.",
            risk: .review, method: .admin([]), items: [FindingItem(id: "s1", name: "27.10.2026, 10:15:00")],
            size: nil, blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)
        let macUpdate = Finding(
            id: FindingID(scannerID: "sysdata.macUpdate", key: "all"), category: .systemData,
            title: "Heruntergeladenes macOS-Update",
            summary: "Installiere das Update oder warte – macOS räumt die Datei selbst weg.",
            risk: .hintOnly, method: .hint(.openURL(updateURL)), items: [], size: 8 * gb,
            blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)
        return SystemDataReport(
            measuredAt: Date(), inventory: inventory, areas: areas, userData: userData,
            systemAreasTotal: systemTotal, unaccounted: max(0, 390 * gb - userData - systemTotal),
            unaccountedIsUpperBound: true, snapshotFindings: [tm],
            cleanupFindings: [
                cleanup("sysdata.temp", "Alte temporäre Dateien", "Nur dein eigener temporärer Ordner.",
                        method: .delete, paths: [("/private/var/folders/xy/abc/T/alt.tmp", 1_200_000_000)]),
                cleanup("sysdata.libraryCaches", "Systemweite Caches", "Je Ordner ein Admin-Schritt.",
                        method: .admin([]), paths: [("/Library/Caches/com.example.cache", 1_500_000_000)]),
                cleanup("sysdata.libraryLogs", "Alte System-Protokolle", "Nur Dateien älter als 30 Tage.",
                        method: .admin([]), paths: [("/Library/Logs/DiagnosticReports/alt.ips", 300_000_000)]),
                cleanup("sysdata.unifiedLog", "Diagnosedaten", "Braucht dein Admin-Passwort.",
                        method: .admin([]), paths: [("/private/var/db/diagnostics", 2_100_000_000)]),
                macUpdate,
            ],
            failures: [ScanFailure(scannerID: "systemdata.unaccounted",
                message: "Einige Bereiche konnten nicht vollständig gemessen werden – „nicht zugeordnet“ ist daher eher zu hoch.")])
    }
}
