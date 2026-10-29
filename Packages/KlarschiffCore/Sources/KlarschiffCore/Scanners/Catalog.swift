import Foundation

/// Katalog aller Scanner. Der Großteil sind deklarative `PathRule`s (Spec 5.1/5.2);
/// Spezial-Scanner (Tasks 7–12) werden in `allScanners()` ergänzt.
public enum Catalog {
    public static func allScanners() -> [Scanner] {
        pathRules().map { PathScanner(rule: $0) } + [SnapshotScanner(), SoftwareUpdateScanner(), SimulatorRuntimeScanner(), UnavailableSimulatorsScanner(), HomebrewCleanupScanner(), HomebrewCaskScanner(),
            CondaScanner(), OllamaScanner(), RustupScanner(),
            VersionedDirScanner.deviceSupport, VersionedDirScanner.nvm, VersionedDirScanner.pyenv, VersionedDirScanner.rbenv,
            TeXLiveScanner(), MobileBackupScanner(), OldInstallerScanner(), MessagesAttachmentsScanner(),
            UnusedAppsScanner(), LeftoverAppDataScanner(), ExtraXcodeScanner(),
            AppStoreCachesScanner(), OtherCachesScanner()]
    }

    /// Regel zu einer ID (für Tests und Neu-Scans einzelner Regeln). Unbekannte ID ist ein Programmierfehler.
    public static func rule(_ id: String) -> PathRule {
        guard let rule = pathRules().first(where: { $0.id == id }) else {
            fatalError("Unbekannte PathRule-ID: \(id)")
        }
        return rule
    }

    public static func pathRules() -> [PathRule] {
        system + aiLeftovers + appCaches + personalData + xcode + simulators + languages + toolchains
    }

    // MARK: - Laufende Apps

    static let xcodeApps: [AppRef] = [
        AppRef(bundleID: "com.apple.dt.Xcode", processName: nil, displayName: "Xcode"),
        AppRef(bundleID: "com.apple.dt.Instruments", processName: nil, displayName: "Instruments"),
        AppRef(bundleID: nil, processName: "xctrace", displayName: "xctrace"),
        AppRef(bundleID: nil, processName: "instruments", displayName: "instruments"),
    ]
    static let claudeApp = [AppRef(bundleID: "com.anthropic.claudefordesktop", processName: nil, displayName: "Claude")]
    static let telegramApp = [AppRef(bundleID: "ru.keepcoder.Telegram", processName: nil, displayName: "Telegram")]
    static let simulatorApp = [AppRef(bundleID: "com.apple.iphonesimulator", processName: nil, displayName: "Simulator")]
    static let spotifyApp = [AppRef(bundleID: "com.spotify.client", processName: nil, displayName: "Spotify")]
    static let lmStudioApp = [AppRef(bundleID: "ai.elementlabs.lmstudio", processName: nil, displayName: "LM Studio")]
    static let mailApp = [AppRef(bundleID: "com.apple.mail", processName: nil, displayName: "Mail")]

    private static func tool(_ name: String, _ args: String...) -> ToolCommand {
        ToolCommand(tool: name, arguments: args, timeout: .seconds(120))
    }

    // MARK: - Speicher: System

    static let system: [PathRule] = [
        PathRule(
            id: "system.oldLogs", category: .system,
            title: "Alte Protokolle",
            summary: "Protokolldateien von Apps und System, die älter als 30 Tage sind. Sie dienen nur der Fehlersuche und werden praktisch nie mehr gebraucht.",
            base: .home, patterns: ["Library/Logs"],
            risk: .safe, method: .trash, minAgeDays: 30, excludeNames: ["CoreSimulator"]),
        PathRule(
            id: "system.iosUpdates", category: .system,
            title: "iPhone- und iPad-Softwareupdates",
            summary: "Heruntergeladene Updates für iPhone oder iPad (.ipsw). Nach der Installation braucht sie niemand mehr – bei Bedarf lädt der Mac sie neu.",
            base: .home,
            patterns: ["Library/iTunes/iPhone Software Updates", "Library/iTunes/iPad Software Updates"],
            risk: .safe, method: .trash),
    ]

    // MARK: - Speicher: KI-Reste

    static let aiLeftovers: [PathRule] = [
        PathRule(
            id: "ai.claudeCache", category: .aiLeftovers,
            title: "Claude Desktop – Cache",
            summary: "Zwischenspeicher der Claude-App (Webinhalte, Grafik-Shader). Deine Unterhaltungen bleiben erhalten; Claude legt den Cache beim nächsten Start neu an.",
            base: .home,
            patterns: [
                "Library/Application Support/Claude/Cache",
                "Library/Application Support/Claude/Code Cache",
                "Library/Application Support/Claude/GPUCache",
                "Library/Application Support/Claude/DawnGraphiteCache",
                "Library/Application Support/Claude/DawnWebGPUCache",
                "Library/Caches/com.anthropic.claudefordesktop*",
            ],
            risk: .safe, method: .trash, blockingApps: claudeApp),
        PathRule(
            id: "ai.coworkVM", category: .aiLeftovers,
            title: "Claude Cowork – virtuelle Maschine",
            summary: "Virtuelle Maschine für Cowork. Wird bei der nächsten Nutzung erneut heruntergeladen (~12 GB). Lohnt sich, wenn du Cowork selten nutzt.",
            base: .home, patterns: ["Library/Application Support/Claude/vm_bundles"],
            risk: .review, method: .delete, blockingApps: claudeApp),
        PathRule(
            id: "ai.cliCaches", category: .aiLeftovers,
            title: "Codex-, Gemini- und Copilot-Caches",
            summary: "Protokolle und temporäre Dateien der KI-Kommandozeilen-Werkzeuge. Anmeldedaten, Einstellungen und Sitzungen werden nicht angefasst.",
            base: .home,
            patterns: [".codex", ".gemini", ".copilot"].flatMap { dir in
                ["log", "logs", "tmp", "cache", ".cache"].map { "\(dir)/\($0)" }
            },
            risk: .safe, method: .trash),
        PathRule(
            id: "ai.lmStudio", category: .aiLeftovers,
            title: "LM Studio – Modelle",
            summary: "Heruntergeladene Sprachmodelle von LM Studio und deren Cache. Prüfe, welche Modelle du noch nutzt – gelöschte musst du erneut herunterladen.",
            base: .home, patterns: [".lmstudio/models/*/*", ".cache/lm-studio"],
            risk: .review, method: .delete, blockingApps: lmStudioApp),
        PathRule(
            id: "ai.huggingFace", category: .aiLeftovers,
            title: "Hugging Face",
            summary: "Ein heruntergeladenes Modell oder Datenset aus dem Hugging-Face-Cache. Wird es noch gebraucht, lädt das jeweilige Programm es beim nächsten Mal erneut herunter.",
            base: .home,
            patterns: [".cache/huggingface/hub/models--*", ".cache/huggingface/hub/datasets--*"],
            risk: .review, method: .delete, grouping: .perMatch, matchName: .huggingFace),
    ]

    // MARK: - Speicher: App-Caches

    static let appCaches: [PathRule] = [
        PathRule(
            id: "appCaches.telegram", category: .appCaches,
            title: "Telegram – Medien-Cache",
            summary: "Bilder, Videos und Dateien, die Telegram aus Chats zwischengespeichert hat. Sie liegen weiter in der Cloud und werden beim Öffnen erneut geladen.",
            base: .home,
            patterns: ["Library/Group Containers/*.ru.keepcoder.Telegram/*/*/postbox/media"],
            risk: .review, method: .trash, blockingApps: telegramApp),
        PathRule(
            id: "appCaches.spotify", category: .appCaches,
            title: "Spotify – Offline-Cache",
            summary: "Zwischengespeicherte Musik von Spotify. Offline gespeicherte Titel musst du danach eventuell erneut herunterladen.",
            base: .home, patterns: ["Library/Application Support/Spotify/PersistentCache"],
            risk: .safe, method: .trash, blockingApps: spotifyApp),
        PathRule(
            id: "appCaches.adobe", category: .appCaches,
            title: "Adobe – Mediencache",
            summary: "Vorschau- und Audiodateien, die Premiere, After Effects & Co. beim Bearbeiten anlegen. Die Programme erzeugen sie bei Bedarf neu.",
            base: .home,
            patterns: [
                "Library/Application Support/Adobe/Common/Media Cache Files",
                "Library/Application Support/Adobe/Common/Media Cache",
            ],
            risk: .safe, method: .trash),
    ]

    // MARK: - Speicher: Persönliche Daten

    static let personalData: [PathRule] = [
        PathRule(
            id: "personal.mailDownloads", category: .personalData,
            title: "Mail – Kopien geöffneter Anhänge",
            summary: "Kopien von Anhängen, die du in Mail geöffnet hast. Die Originale bleiben in deinen E-Mails erhalten.",
            base: .home, patterns: ["Library/Containers/com.apple.mail/Data/Library/Mail Downloads"],
            risk: .safe, method: .trash, blockingApps: mailApp, needsFullDiskAccess: true),
    ]

    // MARK: - Entwickler: Xcode

    static let xcode: [PathRule] = [
        PathRule(
            id: "xcode.instruments", category: .xcode,
            title: "Instruments-Caches",
            summary: "Zwischenspeicher von Instruments (Symbole, Aufzeichnungsdaten). Wird beim nächsten Profiling automatisch neu erstellt.",
            base: .userCache, patterns: ["com.apple.dt.Instruments", "com.apple.dt.InstrumentsCLI"],
            risk: .safe, method: .delete, blockingApps: xcodeApps),
        PathRule(
            id: "xcode.clang", category: .xcode,
            title: "Clang-Modul-Cache",
            summary: "Vorübersetzte Module des Compilers. Werden beim nächsten Build automatisch neu erstellt – der erste Build dauert dann etwas länger.",
            base: .userCache, patterns: ["clang/ModuleCache", "org.llvm.clang*"],
            risk: .safe, method: .delete, blockingApps: xcodeApps),
        PathRule(
            id: "xcode.derivedData", category: .xcode,
            title: "DerivedData",
            summary: "Zwischenspeicher von Xcode. Wird beim nächsten Build automatisch neu erstellt.",
            base: .home, patterns: ["Library/Developer/Xcode/DerivedData/*"],
            risk: .safe, method: .delete, blockingApps: xcodeApps),
        PathRule(
            id: "xcode.previews", category: .xcode,
            title: "SwiftUI-Previews",
            summary: "Daten der SwiftUI-Vorschau in Xcode. Werden beim nächsten Öffnen einer Vorschau neu angelegt.",
            base: .home, patterns: ["Library/Developer/Xcode/UserData/Previews"],
            risk: .safe, method: .delete, blockingApps: xcodeApps),
        PathRule(
            id: "xcode.archives", category: .xcode,
            title: "Archiv",
            summary: "Ein mit Xcode erstelltes App-Archiv. Brauchst du es noch zum Hochladen oder für Absturzberichte (dSYMs), behalte es.",
            base: .home, patterns: ["Library/Developer/Xcode/Archives/*/*"],
            risk: .review, method: .trash, grouping: .perMatch, matchName: .withoutExtension),
        PathRule(
            id: "xcode.deviceLogs", category: .xcode,
            title: "Geräte-Protokolle",
            summary: "Protokolle und Build-Produkte angeschlossener Geräte. Xcode legt sie bei Bedarf neu an.",
            base: .home,
            patterns: ["Library/Developer/Xcode/iOS Device Logs", "Library/Developer/Xcode/Products"],
            risk: .safe, method: .trash, blockingApps: xcodeApps),
        PathRule(
            id: "xcode.documentationCache", category: .xcode,
            title: "Dokumentations-Cache",
            summary: "Zwischengespeicherte Entwickler-Dokumentation. Xcode lädt sie bei Bedarf erneut.",
            base: .home,
            patterns: ["Library/Developer/Xcode/DocumentationCache", "Library/Developer/Xcode/DocumentationIndex"],
            risk: .safe, method: .delete, blockingApps: xcodeApps),
        PathRule(
            id: "xcode.libraryDeveloper", category: .xcode,
            title: "/Library/Developer",
            summary: "Systemweite Entwickler-Daten (Command Line Tools, Simulator-Laufzeiten). Nur zur Übersicht – Simulator-Laufzeiten entfernst du sicher über den Fund „Simulator-Runtimes“.",
            base: .absolute,
            patterns: ["/Library/Developer/CommandLineTools", "/Library/Developer/CoreSimulator/Volumes"],
            risk: .hintOnly, method: .hint(nil), grouping: .perMatch),
    ]

    // MARK: - Entwickler: Simulatoren

    static let simulators: [PathRule] = [
        PathRule(
            id: "simulators.caches", category: .simulators,
            title: "CoreSimulator-Caches",
            summary: "Zwischenspeicher der Simulatoren. Werden beim nächsten Start eines Simulators automatisch neu erstellt.",
            base: .home, patterns: ["Library/Developer/CoreSimulator/Caches"],
            risk: .safe, method: .delete, blockingApps: simulatorApp),
        PathRule(
            id: "simulators.logs", category: .simulators,
            title: "Simulator-Protokolle",
            summary: "Protokolldateien der Simulatoren. Sie dienen nur der Fehlersuche.",
            base: .home, patterns: ["Library/Logs/CoreSimulator"],
            risk: .safe, method: .trash),
    ]

    // MARK: - Entwickler: Sprachen & Paketmanager

    static let languages: [PathRule] = [
        PathRule(
            id: "languages.npm", category: .languages,
            title: "npm-Cache",
            summary: "Heruntergeladene Pakete von npm. Werden bei der nächsten Installation bei Bedarf neu geladen.",
            base: .home, patterns: [".npm/_cacache"],
            risk: .safe, method: .tool([tool("npm", "cache", "clean", "--force")], fallback: .delete)),
        PathRule(
            id: "languages.yarn", category: .languages,
            title: "Yarn-Cache",
            summary: "Heruntergeladene Pakete von Yarn. Werden bei der nächsten Installation bei Bedarf neu geladen.",
            base: .home, patterns: ["Library/Caches/Yarn"],
            risk: .safe, method: .delete),
        PathRule(
            id: "languages.pnpm", category: .languages,
            title: "pnpm-Store",
            summary: "Der Paketspeicher von pnpm. Aufgeräumt wird mit pnpm selbst – dabei bleiben Pakete erhalten, die deine Projekte noch nutzen. Ist pnpm nicht installiert, bleibt es beim Hinweis.",
            base: .home, patterns: ["Library/pnpm/store"],
            risk: .safe, method: .tool([tool("pnpm", "store", "prune")], fallback: nil)),
        PathRule(
            id: "languages.bun", category: .languages,
            title: "Bun-Cache",
            summary: "Heruntergeladene Pakete von Bun. Werden bei der nächsten Installation bei Bedarf neu geladen.",
            base: .home, patterns: [".bun/install/cache"],
            risk: .safe, method: .delete),
        PathRule(
            id: "languages.pip", category: .languages,
            title: "pip-Cache",
            summary: "Heruntergeladene Python-Pakete von pip. Werden bei der nächsten Installation bei Bedarf neu geladen.",
            base: .home, patterns: ["Library/Caches/pip"],
            risk: .safe, method: .delete),
        PathRule(
            id: "languages.uv", category: .languages,
            title: "uv-Cache",
            summary: "Heruntergeladene Python-Pakete von uv. Werden bei der nächsten Installation bei Bedarf neu geladen.",
            base: .home, patterns: [".cache/uv"],
            risk: .safe, method: .delete),
        PathRule(
            id: "languages.poetry", category: .languages,
            title: "Poetry-Cache",
            summary: "Heruntergeladene Python-Pakete von Poetry. Werden bei der nächsten Installation bei Bedarf neu geladen.",
            base: .home, patterns: ["Library/Caches/pypoetry"],
            risk: .safe, method: .delete),
        PathRule(
            id: "languages.gradle", category: .languages,
            title: "Gradle",
            summary: "Caches, heruntergeladene Gradle-Versionen und Daemon-Daten. Der nächste Build lädt alles Nötige neu – das kann dauern und braucht Internet.",
            base: .home, patterns: [".gradle/caches", ".gradle/wrapper/dists", ".gradle/daemon"],
            risk: .review, method: .trash),
        PathRule(
            id: "languages.androidAvd", category: .languages,
            title: "Android-Emulator",
            summary: "Ein virtuelles Android-Gerät samt Daten. Prüfe, ob du es noch zum Testen brauchst.",
            base: .home, patterns: [".android/avd/*.avd"],
            risk: .review, method: .trash, grouping: .perMatch, matchName: .withoutExtension,
            companionExtensions: ["ini"]),
        PathRule(
            id: "languages.androidSdk", category: .languages,
            title: "Android-SDK",
            summary: "Das Android-SDK mit Plattformen und Werkzeugen. Nur entfernen, wenn du keine Android-Apps mehr entwickelst. Per Homebrew installiert? Dann besser über den Homebrew-Fund.",
            base: .home, patterns: ["Library/Android/sdk"],
            risk: .review, method: .trash),
        PathRule(
            id: "languages.maven", category: .languages,
            title: "Maven-Repository",
            summary: "Heruntergeladene Java-Bibliotheken von Maven. Der nächste Build lädt sie neu – das kann dauern und braucht Internet.",
            base: .home, patterns: [".m2/repository"],
            risk: .review, method: .trash),
        PathRule(
            id: "languages.flutter", category: .languages,
            title: "Flutter/Dart",
            summary: "Paket-Cache und Werkzeugdaten von Flutter und Dart. Werden bei Bedarf neu geladen. Ein per Homebrew installiertes Flutter-SDK findest du beim Homebrew-Fund.",
            base: .home, patterns: [".pub-cache", ".dart-tool", ".dartServer", ".flutter"],
            risk: .review, method: .trash),
        PathRule(
            id: "languages.swiftpm", category: .languages,
            title: "SwiftPM-Cache",
            summary: "Heruntergeladene Swift-Pakete. Werden beim nächsten Auflösen der Abhängigkeiten neu geladen.",
            base: .home, patterns: ["Library/Caches/org.swift.swiftpm", ".swiftpm/cache"],
            risk: .safe, method: .delete),
        PathRule(
            id: "languages.cocoapods", category: .languages,
            title: "CocoaPods-Cache",
            summary: "Heruntergeladene Pods. Werden beim nächsten „pod install“ bei Bedarf neu geladen.",
            base: .home, patterns: ["Library/Caches/CocoaPods"],
            risk: .safe, method: .delete),
        PathRule(
            id: "languages.carthage", category: .languages,
            title: "Carthage-Cache",
            summary: "Heruntergeladene Carthage-Abhängigkeiten. Werden beim nächsten Build bei Bedarf neu geladen.",
            base: .home, patterns: ["Library/Caches/org.carthage.CarthageKit"],
            risk: .safe, method: .delete),
        PathRule(
            id: "languages.cargo", category: .languages,
            title: "Rust – Cargo-Caches",
            summary: "Heruntergeladene Crates und Git-Abhängigkeiten von Cargo. Werden beim nächsten Build bei Bedarf neu geladen.",
            base: .home, patterns: [".cargo/registry/cache", ".cargo/git/db"],
            risk: .safe, method: .delete),
        PathRule(
            id: "languages.goModules", category: .languages,
            title: "Go-Modul-Cache",
            summary: "Heruntergeladene Go-Module. Werden beim nächsten Build bei Bedarf neu geladen.",
            base: .home, patterns: ["go/pkg/mod"],
            risk: .safe, method: .tool([tool("go", "clean", "-modcache")], fallback: .delete)),
        PathRule(
            id: "languages.goBuild", category: .languages,
            title: "Go-Build-Cache",
            summary: "Zwischenergebnisse des Go-Compilers. Werden beim nächsten Build automatisch neu erstellt.",
            base: .home, patterns: ["Library/Caches/go-build"],
            risk: .safe, method: .tool([tool("go", "clean", "-cache")], fallback: .delete)),
        PathRule(
            id: "languages.ruby", category: .languages,
            title: "Ruby-Gems und -Versionen",
            summary: "Installierte Gems und über rbenv installierte Ruby-Versionen. Prüfe, ob deine Projekte sie noch brauchen. Deine RubyGems-Zugangsdaten bleiben unangetastet.",
            base: .home, patterns: [".gem/*", ".rbenv/versions/*"],
            risk: .review, method: .trash, excludeNames: ["credentials"]),
        PathRule(
            id: "languages.testBrowsers", category: .languages,
            title: "Browser für Tests",
            summary: "Browser, die Playwright, Puppeteer, Cypress oder Electron für automatisierte Tests heruntergeladen haben. Werden beim nächsten Testlauf neu geladen.",
            base: .home,
            patterns: [
                "Library/Caches/ms-playwright", ".cache/puppeteer",
                "Library/Caches/Cypress", "Library/Caches/electron",
            ],
            risk: .safe, method: .delete),
    ]

    // MARK: - Entwickler: Toolchains & SDKs

    static let toolchains: [PathRule] = [
        PathRule(
            id: "toolchains.arduinoStaging", category: .toolchains,
            title: "Arduino – Download-Reste",
            summary: "Zwischengespeicherte Downloads aus dem Board- und Bibliotheksverwalter der Arduino IDE. Werden nach der Installation nicht mehr gebraucht.",
            base: .home, patterns: ["Library/Arduino15/staging"],
            risk: .safe, method: .trash),
        PathRule(
            id: "toolchains.arduinoPackages", category: .toolchains,
            title: "Arduino-Boardpaket",
            summary: "Installierte Board-Unterstützung der Arduino IDE. Nicht mehr benötigte Pakete entfernst du am besten im Board-Verwalter der Arduino IDE.",
            base: .home, patterns: ["Library/Arduino15/packages/*"],
            risk: .hintOnly, method: .hint(nil), grouping: .perMatch),
        PathRule(
            id: "toolchains.docker", category: .toolchains,
            title: "Docker – virtuelle Maschine",
            summary: "Die virtuelle Festplatte von Docker Desktop mit allen Images und Containern. Aufräumen mit „docker system prune -a“ im Terminal oder in Docker Desktop unter „Troubleshoot“.",
            base: .home, patterns: ["Library/Containers/com.docker.docker/Data/vms"],
            risk: .hintOnly, method: .hint(nil)),
        PathRule(
            id: "toolchains.utm", category: .toolchains,
            title: "UTM-VM",
            summary: "Eine virtuelle Maschine von UTM. Nicht mehr benötigte VMs entfernst du am besten direkt in UTM.",
            base: .home, patterns: ["Library/Containers/com.utmapp.UTM/Data/Documents/*.utm"],
            risk: .hintOnly, method: .hint(nil), grouping: .perMatch, matchName: .withoutExtension),
        PathRule(
            id: "toolchains.parallels", category: .toolchains,
            title: "Parallels-VM",
            summary: "Eine virtuelle Maschine von Parallels Desktop. Nicht mehr benötigte VMs entfernst du am besten im Kontrollcenter von Parallels.",
            base: .home, patterns: ["Parallels/*.pvm"],
            risk: .hintOnly, method: .hint(nil), grouping: .perMatch, matchName: .withoutExtension),
        PathRule(
            id: "toolchains.orbstack", category: .toolchains,
            title: "OrbStack-Daten",
            summary: "Daten von OrbStack mit Containern, Images und Linux-Maschinen. Aufräumen mit „docker system prune -a“ oder direkt in OrbStack.",
            base: .home, patterns: [".orbstack", "Library/Group Containers/*.dev.orbstack"],
            risk: .hintOnly, method: .hint(nil)),
    ]
}
