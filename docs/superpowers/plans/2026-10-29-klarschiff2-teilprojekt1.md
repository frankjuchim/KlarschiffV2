# Klarschiff 2 – Teilprojekt 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS-App „Klarschiff 2“ mit Fundament, Tab „Speicher“ und Tab „Entwickler“, die den kompletten Scanner-Katalog findet, erklärt und sicher entfernt.

**Architecture:** Gesamte Logik im Swift Package `KlarschiffCore` (Modelle, Scanner, Remover, SafetyGuard), per `swift test` gegen Fixture-Bäume und aufgezeichnete Werkzeug-Ausgaben getestet. Dünne SwiftUI-App (Liquid Glass) erzeugt per XcodeGen. Shell-Werkzeuge nur über das Protokoll `CommandRunner`, Admin-Schritte gebündelt über `PrivilegedExecutor`.

**Tech Stack:** Swift 6 (Strict Concurrency), SwiftUI, macOS 26, Swift Testing (`import Testing`), XcodeGen, GitHub Actions (macOS-Runner).

**Spec:** `docs/superpowers/specs/2026-10-29-klarschiff2-teilprojekt1-design.md` (Ausführende lesen Spec **und** Plan; Katalog-Details – Pfade, Stufen, Methoden – stehen in Spec Abschnitt 5 und werden hier nicht wiederholt.)

## Global Constraints

- Bundle-ID `de.frankjuchim.klarschiff2`, Produktname „Klarschiff“, Deployment Target **macOS 26.0**, keine Sandbox, Hardened Runtime an.
- Swift 6 Language Mode, Strict Concurrency complete.
- Gesamte UI-Sprache Deutsch, Du-Form, Tonalität wie Klarschiff 1; Bytes immer über `ByteFormat.string(_:)` (Locale `de_DE`, `.file`).
- Kein Pfad wird je gelöscht/verschoben, ohne vorher `SafetyGuard.check(_:)` zu passieren.
- Kopierbare Befehle (`commandPreview`) enthalten niemals `#`.
- Shell-Werkzeuge nur über `CommandRunner`; nie `/bin/sh -c` mit unquotierten Pfaden (Ausnahme: das gequotete Admin-Skript).
- Alle Pfade in Scannern kommen aus `ScanContext` (Home, Cache-Dir, Wurzel-Präfix) – keine fest verdrahteten `NSHomeDirectory()`-Aufrufe in Scannern.
- `DEVELOPMENT_TEAM` nie einchecken (`Config/Local.xcconfig` in `.gitignore`).

## Review Focus

1. **Pfade mit Leerzeichen, Umlauten, `'`, `"`, `$`** (z. B. `Application Support`, `Mobile Documents`) im Admin-Skript und in `commandPreview` → werden korrekt gequotet, nichts anderes wird gelöscht. Test in Task 15.
2. **Symlink, der aus einer erlaubten Wurzel herauszeigt** (z. B. `~/Library/Caches/x → ~/Documents`) → SafetyGuard verweigert, SizeMeter zählt ihn nicht. Tests in Task 4 und Task 5.
3. **Werkzeug installiert, aber kaputt/hängend** (`brew` hängt bei Auto-Update, `xcrun` ohne Xcode zeigt Dialog) → Timeout, Scanner meldet „konnte nicht geprüft werden“, Rest läuft. Tests in Task 3 und Task 8.
4. **App startet während des Aufräumens bzw. läuft noch** (Xcode, Claude) → Fund wird übersprungen und als „App läuft“ gemeldet, nicht halb gelöscht. Test in Task 15.
5. **Abgebrochene Passwortabfrage** → alle Admin-Schritte „abgebrochen“, Papierkorb-/Tool-Schritte desselben Laufs bleiben gültig, Ergebnis zeigt das ehrlich. Test in Task 15.

---

## Dateistruktur

```
project.yml                                  XcodeGen (App + App-Tests)
Config/Base.xcconfig, Config/Local.xcconfig.example
App/KlarschiffApp.swift                      @main, Fenster
App/Model/AppModel.swift                     @Observable Brücke zum Core
App/Views/Chrome/*.swift                     Hintergrund, Header, TabBar, CapacityCard, Placeholder
App/Views/Cleanup/*.swift                    SummaryCard, CategorySection, FindingCard, FindingItemsList,
                                             CommandSheet, KeepSection, ConfirmSheet, ResultBanner,
                                             FullDiskAccessCard, BigChunksCard, PhotosCard
App/Resources/Assets.xcassets, App/Klarschiff.entitlements
Packages/KlarschiffCore/Package.swift
Packages/KlarschiffCore/Sources/KlarschiffCore/
  Model/        Risk.swift, RemovalMethod.swift, Category.swift, Finding.swift, ByteFormat.swift
  System/       CommandRunner.swift, ProcessCommandRunner.swift, ToolLocator.swift, SizeMeter.swift,
                RunningApps.swift, DiskInfo.swift, FullDiskAccess.swift
  Safety/       SafetyGuard.swift, KeepList.swift
  Scanning/     Scanner.swift, ScanContext.swift, PathClaims.swift, ScanEngine.swift
  Scanners/     PathRule.swift, PathScanner.swift, Catalog.swift, SnapshotScanner.swift,
                SimulatorScanner.swift, HomebrewScanner.swift, ToolCacheScanners.swift,
                VersionedDirScanner.swift, TeXLiveScanner.swift, PersonalDataScanners.swift,
                AppScanners.swift, CollectorScanners.swift, BigChunksScanner.swift, InfoScanners.swift
  Removal/      Remover.swift, TrashRemover.swift, DeleteRemover.swift, ToolRemover.swift,
                PrivilegedExecutor.swift, AdminScriptBuilder.swift, AppleScriptPrivilegedExecutor.swift,
                RemovalPlan.swift, RemovalRunner.swift
Packages/KlarschiffCore/Tests/KlarschiffCoreTests/
  Support/FixtureTree.swift, Support/FakeCommandRunner.swift, Support/FakeRunningApps.swift
  Fixtures/*.json|*.txt                       aufgezeichnete Werkzeug-Ausgaben
  <je Task eine Testdatei>
scripts/release.sh
.github/workflows/ci.yml
```

---

### Task 1: Gerüst, CI und Modelle

**Files:**
- Create: `project.yml`, `Config/Base.xcconfig`, `Config/Local.xcconfig.example`, `.gitignore`, `App/KlarschiffApp.swift` (leeres Fenster „Klarschiff“), `App/Klarschiff.entitlements` (leer, keine Sandbox), `Packages/KlarschiffCore/Package.swift`, `Model/Risk.swift`, `Model/RemovalMethod.swift`, `Model/Category.swift`, `Model/Finding.swift`, `Model/ByteFormat.swift`, `.github/workflows/ci.yml`
- Test: `Tests/KlarschiffCoreTests/FindingTests.swift`, `ByteFormatTests.swift`

**Interfaces:**
- Produces:
  - `enum Risk: String, Codable, Sendable { case safe, review, hintOnly }` mit `var label: String` → „Sicher“ / „Prüfen“ / „Nur Hinweis“.
  - `struct ToolCommand: Hashable, Codable, Sendable { var tool: String; var arguments: [String]; var timeout: Duration }` mit `var display: String` (gequotet, für `commandPreview`).
  - `struct AdminStep: Hashable, Codable, Sendable { var executable: String; var arguments: [String] }`.
  - `enum HintAction: Hashable, Codable, Sendable { case openURL(URL), revealInFinder(URL) }`.
  - `enum RemovalMethod: Hashable, Codable, Sendable { case trash, delete, tool([ToolCommand], fallback: Fallback?), admin([AdminStep]), hint(HintAction?) }`, `enum Fallback { case delete, trash }`.
  - `enum AppTab: String, CaseIterable, Sendable { case storage, developer, systemData, services, performance }` mit `title` („Speicher“, „Entwickler“, „Systemdaten“, „Hintergrunddienste“, „Leistung“) und `symbol` (Spec 4.1).
  - `enum Category: String, CaseIterable, Sendable` mit `tab: AppTab`, `title: String`, `symbol: String`, `sortOrder: Int`. Fälle: Speicher → `system` „System“, `aiLeftovers` „KI-Reste“, `appCaches` „App-Caches“, `personalData` „Persönliche Daten“, `apps` „Apps“; Entwickler → `xcode` „Xcode“, `simulators` „Simulatoren“, `homebrew` „Homebrew“, `languages` „Sprachen & Paketmanager“, `toolchains` „Toolchains & SDKs“.
  - `struct FindingID: Hashable, Codable, Sendable { var scannerID: String; var key: String }`.
  - `struct AppRef: Hashable, Sendable { var bundleID: String?; var processName: String?; var displayName: String }`.
  - `struct FindingItem: Hashable, Sendable, Identifiable { var id: String; var url: URL?; var name: String; var size: Int64?; var date: Date?; var detail: String? }`.
  - `struct Finding: Identifiable, Sendable` mit den Feldern aus Spec 3.2 (`id: FindingID`, `category`, `title`, `summary`, `risk`, `method`, `items`, `size: Int64?`, `blockingApps: [AppRef]`, `keepSuggested: Bool`, `commandPreview: [String]`, `needsFullDiskAccess: Bool`) plus `var tab: AppTab { category.tab }` und `func isPreselected(isKept: Bool) -> Bool`.
  - `enum ByteFormat { static func string(_ bytes: Int64) -> String }`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func preselectedOnlyWhenSafeNotKeptNotBlockedNotSuggested() {
  let base = Finding.sample(risk: .safe)
  #expect(base.isPreselected(isKept: false))
  #expect(!base.isPreselected(isKept: true))
  #expect(!Finding.sample(risk: .review).isPreselected(isKept: false))
  #expect(!Finding.sample(risk: .hintOnly).isPreselected(isKept: false))
  #expect(!Finding.sample(risk: .safe, keepSuggested: true).isPreselected(isKept: false))
  #expect(!Finding.sample(risk: .safe, blockingApps: [AppRef(bundleID: "com.apple.dt.Xcode", processName: nil, displayName: "Xcode")]).isPreselected(isKept: false))
}
@Test func germanByteFormatting() {
  #expect(ByteFormat.string(11_990_000_000) == "11,99 GB")
  #expect(ByteFormat.string(250_400_000) == "250,4 MB")
}
@Test func categoriesMapToTabs() {
  #expect(Category.xcode.tab == .developer)
  #expect(Category.aiLeftovers.tab == .storage)
  #expect(Category.aiLeftovers.title == "KI-Reste")
}
@Test func toolCommandDisplayQuotesAndHasNoHash() {
  let c = ToolCommand(tool: "xcrun", arguments: ["simctl", "runtime", "delete", "ABC-123"], timeout: .seconds(600))
  #expect(c.display == "xcrun simctl runtime delete ABC-123")
  #expect(ToolCommand(tool: "brew", arguments: ["uninstall", "--cask", "my app"], timeout: .seconds(120)).display == "brew uninstall --cask 'my app'")
}
```
`Finding.sample(...)` ist ein Test-Helfer in `Support/FindingSample.swift` mit Defaults.

- [ ] **Step 2: Run** `swift test --package-path Packages/KlarschiffCore` → Expected: FAIL (Typen fehlen).
- [ ] **Step 3: Implement** Modelle und `ByteFormat` (ByteCountFormatter `.file`, `locale = Locale(identifier: "de_DE")`). Gemeinsamer Quoting-Helfer `ShellQuote.quote(_:) -> String` in `Model/RemovalMethod.swift` (POSIX-Single-Quote: harmlose Zeichen `[A-Za-z0-9_./:@%+=,-]` unverändert, sonst `'…'` mit `'\''`).
- [ ] **Step 4: Gerüst** `project.yml` (Target `Klarschiff`, `PRODUCT_BUNDLE_IDENTIFIER=de.frankjuchim.klarschiff2`, `MACOSX_DEPLOYMENT_TARGET=26.0`, `ENABLE_HARDENED_RUNTIME=YES`, `SWIFT_VERSION=6.0`, lokales Paket `Packages/KlarschiffCore`, `configFiles` → `Config/Base.xcconfig`, das optional `#include? "Local.xcconfig"`). `.gitignore`: `*.xcodeproj`, `Config/Local.xcconfig`, `.build/`, `DerivedData/`, `build/`.
- [ ] **Step 5: CI** `.github/workflows/ci.yml`: `runs-on: macos-26` (Fallback `macos-latest`, falls das Image fehlt), Schritte `brew install xcodegen`, `swift test --package-path Packages/KlarschiffCore`, `xcodegen generate`, `xcodebuild -scheme Klarschiff -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`.
- [ ] **Step 6: Run** Tests → PASS; `xcodegen generate && xcodebuild … build` → `BUILD SUCCEEDED`.
- [ ] **Step 7: Commit** `feat: Gerüst, CI und Kernmodelle`

---

### Task 2: CommandRunner, ToolLocator

**Files:**
- Create: `System/CommandRunner.swift`, `System/ProcessCommandRunner.swift`, `System/ToolLocator.swift`
- Test: `CommandRunnerTests.swift`, `ToolLocatorTests.swift`, `Support/FakeCommandRunner.swift`

**Interfaces:**
- Produces:
  - `struct CommandResult: Sendable { var exitCode: Int32; var stdout: String; var stderr: String; var succeeded: Bool { exitCode == 0 } }`
  - `enum CommandError: Error, Equatable { case timeout, launchFailed(String) }`
  - `protocol CommandRunner: Sendable { func run(_ executable: String, _ arguments: [String], timeout: Duration, environment: [String: String]) async throws -> CommandResult }`
  - `struct ProcessCommandRunner: CommandRunner` (Process, Pipes asynchron lesen, bei Timeout `terminate()` dann nach 2 s `kill`, wirft `.timeout`; Logging über `Logger(subsystem: "de.frankjuchim.klarschiff2", category: "command")`).
  - `final class FakeCommandRunner: CommandRunner` (Test-Support): `func stub(_ executable: String, _ arguments: [String], result: CommandResult)`, `func stubTimeout(...)`, `var calls: [(String, [String])]`; unbekannter Aufruf → `CommandResult(exitCode: 127, …)`.
  - `struct ToolLocator: Sendable { init(searchPaths: [String], fileExists: @Sendable (String) -> Bool); func path(for tool: String) -> String?; static let defaultSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + ["~/.cargo/bin", "~/go/bin", "/opt/anaconda3/bin", "/opt/miniconda3/bin", "~/anaconda3/bin", "~/miniconda3/bin", "~/.bun/bin"] (Tilde expandiert) }`
  - `static let brewEnvironment: [String: String] = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1"]` in `ToolLocator`.
  - `func xcrunAvailable(runner: CommandRunner) async -> Bool` in `ToolLocator`: `true` nur wenn `/usr/bin/xcode-select -p` exit 0 **und** der Pfad nicht auf `CommandLineTools` endet (sonst würde `xcrun simctl` fehlen).

- [ ] **Step 1: Failing tests**
```swift
@Test func runsProcessAndCapturesOutput() async throws {
  let r = try await ProcessCommandRunner().run("/bin/echo", ["hallo welt"], timeout: .seconds(5), environment: [:])
  #expect(r.succeeded); #expect(r.stdout == "hallo welt\n")
}
@Test func timesOut() async {
  await #expect(throws: CommandError.timeout) {
    try await ProcessCommandRunner().run("/bin/sleep", ["5"], timeout: .milliseconds(200), environment: [:])
  }
}
@Test func locatorPrefersFirstSearchPath() {
  let l = ToolLocator(searchPaths: ["/a", "/b"], fileExists: { $0 == "/b/brew" || $0 == "/a/brew" })
  #expect(l.path(for: "brew") == "/a/brew"); #expect(l.path(for: "conda") == nil)
}
@Test func xcrunUnavailableWithOnlyCommandLineTools() async {
  let fake = FakeCommandRunner()
  fake.stub("/usr/bin/xcode-select", ["-p"], result: .init(exitCode: 0, stdout: "/Library/Developer/CommandLineTools\n", stderr: ""))
  #expect(await ToolLocator.xcrunAvailable(runner: fake) == false)
}
```
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: CommandRunner und ToolLocator`

---

### Task 3: SizeMeter

**Files:** Create `System/SizeMeter.swift`; Test `SizeMeterTests.swift`, `Support/FixtureTree.swift`

**Interfaces:**
- Produces:
  - `struct SizeMeter: Sendable { func size(of url: URL) async throws -> Int64; func sizes(of urls: [URL]) async throws -> [URL: Int64] }` – belegte Blöcke (`totalFileAllocatedSizeKey`, Fallback `fileAllocatedSizeKey`), Symlinks nicht verfolgen, harte Links (`linkCount > 1`) per `fileResourceIdentifierKey` einmal zählen, `Task.checkCancellation()` alle 500 Einträge, nicht lesbare Unterordner überspringen. `sizes` parallel per TaskGroup. Nicht existierender Pfad → 0.
  - Test-Support `struct FixtureTree { let root: URL; init() throws  /* temp dir */; func file(_ relPath: String, bytes: Int) throws -> URL; func dir(_ relPath: String) throws -> URL; func symlink(_ relPath: String, to target: URL) throws; func hardlink(_ relPath: String, to existing: URL) throws; func setModified(_ relPath: String, daysAgo: Int) throws }`, räumt in `deinit` auf.

- [ ] **Step 1: Failing tests**
```swift
@Test func sumsAllocatedSize() async throws {
  let t = try FixtureTree(); try t.file("a/x.bin", bytes: 1_000_000); try t.file("a/b/y.bin", bytes: 2_000_000)
  let s = try await SizeMeter().size(of: t.root.appending(path: "a"))
  #expect(s >= 3_000_000 && s < 3_200_000)
}
@Test func hardLinksCountedOnce() async throws {
  let t = try FixtureTree(); let f = try t.file("a/x.bin", bytes: 1_000_000); try t.hardlink("a/y.bin", to: f)
  #expect(try await SizeMeter().size(of: t.root.appending(path: "a")) < 1_100_000)
}
@Test func symlinksNotFollowed() async throws {
  let t = try FixtureTree(); let big = try t.file("outside/big.bin", bytes: 5_000_000)
  try t.dir("a"); try t.symlink("a/link", to: big.deletingLastPathComponent())
  #expect(try await SizeMeter().size(of: t.root.appending(path: "a")) < 100_000)
}
@Test func missingPathIsZero() async throws {
  #expect(try await SizeMeter().size(of: URL(filePath: "/nonexistent/klarschiff")) == 0)
}
```
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: SizeMeter`

---

### Task 4: SafetyGuard und KeepList

**Files:** Create `Safety/SafetyGuard.swift`, `Safety/KeepList.swift`; Test `SafetyGuardTests.swift`, `KeepListTests.swift`

**Interfaces:**
- Produces:
  - `struct SafetyGuard: Sendable { init(home: URL, userCacheDir: URL, allowedCacheSubdirs: Set<String>); func check(_ url: URL) -> SafetyVerdict }`
  - `enum SafetyVerdict: Equatable, Sendable { case allowed, denied(String) }` (Grund deutsch, z. B. „Geschützter Systemordner“).
  - `allowedCacheSubdirs` Default (`SafetyGuard.defaultAllowedCacheSubdirs`): `["com.apple.dt.Instruments", "com.apple.dt.InstrumentsCLI", "clang", "org.llvm.clang", "org.llvm.clang.ModuleCache"]`.
  - Regeln: exakt Spec 3.3 „SafetyGuard“. Pfad wird vor der Prüfung mit `resolvingSymlinksInPath()` aufgelöst **und** die unaufgelöste Form geprüft; beide müssen erlaubt sein. Erlaubt ist nur, was unter `home` (nicht gleich `home`, `~/Library`, `~/Documents`, `~/Desktop`), unter `userCacheDir/<allowed>`, unter `/Applications/*.app`, `/usr/local/texlive`, `/Library/TeX`, `/opt/anaconda3`, `/opt/miniconda3`, `/Library/Developer/Xcode` liegt; alles andere `denied`.
  - `actor KeepList { init(fileURL: URL); func contains(_ id: FindingID) -> Bool; func add(_ id: FindingID) throws; func remove(_ id: FindingID) throws; var all: Set<FindingID> }` – JSON, atomar geschrieben, fehlende/defekte Datei → leer. Default-Datei `~/Library/Application Support/Klarschiff2/keep.json`.

- [ ] **Step 1: Failing tests** (`home = /Users/test`, `cache = /private/var/folders/ab/xyz/C`)
```swift
@Test(arguments: ["/", "/System/Library", "/usr/bin", "/private/var/folders/ab/xyz/C",
  "/private/var/folders/ab/xyz/T/foo", "/private/var/folders/ab/xyz/C/com.apple.Safari",
  "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime",
  "/opt/homebrew/Caskroom/flutter", "/opt/homebrew/Cellar/git", "/Users/test", "/Users/test/Library",
  "/Users/test/Documents/x", "/Users/test/Pictures/Fotos.photoslibrary",
  "/Users/test/.codex/auth.json", "/Users/test/.gemini/oauth_creds.json", "/Users/test/.config/gh/hosts.yml"])
func denies(_ path: String) { #expect(guardUnderTest.check(URL(filePath: path)) != .allowed) }

@Test(arguments: ["/private/var/folders/ab/xyz/C/com.apple.dt.Instruments",
  "/Users/test/Library/Developer/Xcode/DerivedData/App-abc", "/usr/local/texlive/2022",
  "/Users/test/.codex/log", "/Applications/Xcode-beta.app"])
func allows(_ path: String) { #expect(guardUnderTest.check(URL(filePath: path)) == .allowed) }

@Test func deniesSymlinkEscapingRoot() throws {
  let t = try FixtureTree(); let docs = try t.dir("home/Documents"); try t.symlink("home/Library/Caches/evil", to: docs)
  let g = SafetyGuard(home: t.root.appending(path: "home"), userCacheDir: t.root.appending(path: "C"), allowedCacheSubdirs: [])
  #expect(g.check(t.root.appending(path: "home/Library/Caches/evil")) != .allowed)
}
@Test func keepListPersists() async throws {
  let t = try FixtureTree(); let file = t.root.appending(path: "keep.json")
  let id = FindingID(scannerID: "brew.cask", key: "mitmproxy")
  try await KeepList(fileURL: file).add(id)
  #expect(await KeepList(fileURL: file).contains(id))
}
```
Hinweis: `/private/var/folders/…` wird in Tests als String geprüft (nicht existent); `resolvingSymlinksInPath` auf nicht existente Pfade ist No-op.
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: SafetyGuard und KeepList`

---

### Task 5: Scanner-Protokoll, ScanContext, PathClaims, ScanEngine, RunningApps

**Files:** Create `Scanning/Scanner.swift`, `Scanning/ScanContext.swift`, `Scanning/PathClaims.swift`, `Scanning/ScanEngine.swift`, `System/RunningApps.swift`; Test `ScanEngineTests.swift`, `Support/FakeRunningApps.swift`

**Interfaces:**
- Consumes: `CommandRunner`, `ToolLocator`, `SizeMeter` (Tasks 2–3), `Finding` (Task 1).
- Produces:
  - `enum ScannerPhase: Int, Sendable { case specific = 0, collector = 1 }`
  - `protocol Scanner: Sendable { var id: String { get }; var phase: ScannerPhase { get }; func scan(_ ctx: ScanContext) async throws -> [Finding] }` (Default `phase = .specific`).
  - `struct ScanContext: Sendable { var home: URL; var userCacheDir: URL; var rootPrefix: URL /* "/" in Produktion, Fixture-Root in Tests – für absolute Pfade wie /usr/local */; var runner: CommandRunner; var tools: ToolLocator; var sizer: SizeMeter; var runningApps: RunningApps; var claims: PathClaims; var now: Date; var hasFullDiskAccess: Bool; func absolute(_ path: String) -> URL /* rootPrefix + path */; func homePath(_ rel: String) -> URL; func cachePath(_ rel: String) -> URL }`
  - `actor PathClaims { func claim(_ urls: [URL]); func isClaimed(_ url: URL) -> Bool /* true, wenn url gleich oder unterhalb eines beanspruchten Pfads ist */; func claimedSize(under url: URL, findings: [Finding]) -> Int64 }`
  - `protocol RunningApps: Sendable { func running(_ refs: [AppRef]) -> [AppRef]; func terminate(_ ref: AppRef) async -> Bool }`; Produktion `WorkspaceRunningApps` (NSWorkspace für Bundle-IDs, `ProcessCommandRunner` mit `/usr/bin/pgrep -x <name>` für Prozessnamen); Test-Support `FakeRunningApps(running: Set<String>)`.
  - `struct ScanFailure: Sendable { var scannerID: String; var message: String }`
  - `struct ScanReport: Sendable { var findings: [Finding]; var failures: [ScanFailure] }`
  - `struct ScanEngine: Sendable { init(scanners: [Scanner], perScannerTimeout: Duration = .seconds(180)); func run(_ ctx: ScanContext, progress: @Sendable (Int, Int) -> Void) async -> ScanReport }` – erst alle `.specific` parallel, deren Item-URLs claimen, dann `.collector` parallel; ein werfender Scanner bzw. Timeout → `ScanFailure`, Rest läuft. Funde mit `size == 0` und ohne Items werden verworfen (außer `risk == .hintOnly`).

- [ ] **Step 1: Failing tests** (mit kleinen Inline-Scannern `StubScanner(id:phase:result:)`)
```swift
@Test func collectorSkipsClaimedPaths() async { /* specific claimt /x/a; collector meldet /x/a und /x/b nur wenn !isClaimed → report enthält /x/a einmal */ }
@Test func failingScannerBecomesFailure() async {
  let r = await ScanEngine(scanners: [ThrowingScanner(id: "kaputt"), StubScanner.one(id: "ok")]).run(.test(), progress: { _, _ in })
  #expect(r.failures.map(\.scannerID) == ["kaputt"]); #expect(r.findings.count == 1)
}
@Test func hangingScannerTimesOut() async {
  let r = await ScanEngine(scanners: [HangingScanner(id: "haengt")], perScannerTimeout: .milliseconds(200)).run(.test(), progress: { _, _ in })
  #expect(r.failures.first?.scannerID == "haengt")
}
@Test func claimsCoverDescendants() async {
  let c = PathClaims(); await c.claim([URL(filePath: "/a/b")])
  #expect(await c.isClaimed(URL(filePath: "/a/b/c"))); #expect(!(await c.isClaimed(URL(filePath: "/a/bc"))))
}
```
`ScanContext.test(root:runner:running:)` ist ein Test-Helfer.
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: ScanEngine mit PathClaims und Fehlerisolation`

---

### Task 6: PathRule, PathScanner und Katalog (dateibasierte Funde)

**Files:** Create `Scanners/PathRule.swift`, `Scanners/PathScanner.swift`, `Scanners/Catalog.swift`; Test `PathScannerTests.swift`, `CatalogTests.swift`

**Interfaces:**
- Consumes: `Scanner`, `ScanContext` (Task 5).
- Produces:
  - `enum PathBase: Sendable { case home, userCache, absolute }`
  - `enum Grouping: Sendable { case single /* ein Fund, Einträge = getroffene Pfade */, perMatch /* je getroffener Pfad ein eigener Fund (key = Pfad) */ }`
  - `struct PathRule: Sendable { var id: String; var category: Category; var title: String; var summary: String; var base: PathBase; var patterns: [String] /* "*" = genau eine Pfadkomponente */; var risk: Risk; var method: RemovalMethod; var blockingApps: [AppRef] = []; var minAgeDays: Int? = nil /* nur Dateien älter als n Tage, rekursiv */; var minSize: Int64 = 1; var grouping: Grouping = .single; var needsFullDiskAccess: Bool = false; var excludeNames: Set<String> = [] }`
  - `struct PathScanner: Scanner { init(rule: PathRule) }` – löst Muster auf, misst Größe (bei `minAgeDays` nur passende Dateien), setzt `blockingApps` = `ctx.runningApps.running(rule.blockingApps)`, erzeugt `commandPreview`: `trash` → „In den Papierkorb: <pfad>“, `delete` → `rm -rf '<pfad>'`, `tool` → `ToolCommand.display`. Ist `method == .tool` und das Werkzeug nicht über `ctx.tools` auffindbar → Methode wird zum `fallback`, ohne Fallback → `.hint(nil)`.
  - `enum Catalog { static func pathRules() -> [PathRule]; static func allScanners() -> [Scanner] }` – `pathRules()` enthält **alle** reinen Pfad-Einträge aus Spec 5.1/5.2 (System: Alte Protokolle, iPhone-Softwareupdates; KI: Claude Cache, Codex/Gemini/Copilot-Unterordner (nur `log`, `logs`, `tmp`, `cache`, `.cache`), LM Studio, Hugging Face (perMatch); App-Caches: Telegram, Spotify, Adobe; Persönlich: Mail-Anhänge; Xcode: Instruments, Clang, DerivedData, Previews, Geräte-Protokolle, Dokumentations-Cache; Simulatoren: CoreSimulator-Caches, Simulator-Protokolle; Sprachen: npm (tool+fallback delete), Yarn, pnpm (tool, fallback nil), Bun, pip, uv, Poetry, Gradle, Android-AVDs (perMatch), Android-SDK, Maven, Flutter/Dart, SwiftPM, CocoaPods, Carthage, Cargo-Caches, Go (tool+fallback delete), Ruby, Test-Browser; Toolchains: Arduino-staging (S) und Arduino-packages (H), Docker/UTM/Parallels/OrbStack (H); Xcode: `/Library/Developer` aufgeschlüsselt (H, base `.absolute`)). `allScanners()` = PathScanner für jede Regel + alle Spezial-Scanner der Tasks 7–12.
  - Bundle-IDs „App läuft“: Xcode-Regeln `[com.apple.dt.Xcode, com.apple.dt.Instruments, proc:xctrace, proc:instruments]`, Claude `com.anthropic.claudefordesktop`, Telegram `ru.keepcoder.Telegram`, Simulator `com.apple.iphonesimulator`, Spotify `com.spotify.client`, LM Studio `ai.elementlabs.lmstudio`, Mail `com.apple.mail`.

- [ ] **Step 1: Failing tests**
```swift
@Test func derivedDataFoundWithSizeAndDeleteCommand() async throws {
  let t = try FixtureTree(); try t.file("home/Library/Developer/Xcode/DerivedData/App-abc/x.o", bytes: 2_000_000)
  let f = try await PathScanner(rule: Catalog.rule("xcode.derivedData")).scan(.test(root: t.root)).first!
  #expect(f.category == .xcode && f.risk == .safe && f.method == .delete)
  #expect(f.size! >= 2_000_000)
  #expect(f.commandPreview.allSatisfy { !$0.contains("#") })
}
@Test func instrumentsCacheUsesUserCacheDirAndBlocksWhenXcodeRuns() async throws {
  let t = try FixtureTree(); try t.file("C/com.apple.dt.Instruments/a", bytes: 1000); try t.file("C/com.apple.dt.InstrumentsCLI/b", bytes: 1000)
  let f = try await PathScanner(rule: Catalog.rule("xcode.instruments")).scan(.test(root: t.root, running: ["com.apple.dt.Xcode"])).first!
  #expect(f.items.count == 2); #expect(f.blockingApps.map(\.displayName) == ["Xcode"])
}
@Test func missingPathsYieldNothing() async throws {
  #expect(try await PathScanner(rule: Catalog.rule("languages.gradle")).scan(.test(root: FixtureTree().root)).isEmpty)
}
@Test func minAgeFiltersYoungFiles() async throws { /* Logs: alte Datei 40 Tage → zählt, neue 1 Tag → nicht */ }
@Test func toolFallsBackWhenToolMissing() async throws { /* npm-Regel ohne npm im Locator → method == .delete */ }
@Test func codexOnlyWhitelistedSubfolders() async throws {
  let t = try FixtureTree(); try t.file("home/.codex/log/a.log", bytes: 10); try t.file("home/.codex/auth.json", bytes: 10); try t.file("home/.codex/sessions/s.jsonl", bytes: 10)
  let urls = try await PathScanner(rule: Catalog.rule("ai.cliCaches")).scan(.test(root: t.root)).flatMap(\.items).compactMap(\.url?.lastPathComponent)
  #expect(urls == ["log"])
}
@Test func everyCatalogRuleHasGermanTextAndNoHashInPreviews() {
  for r in Catalog.pathRules() { #expect(!r.title.isEmpty && !r.summary.isEmpty) }
}
```
`Catalog.rule(_ id: String) -> PathRule` (für Tests, `fatalError` bei unbekannter ID).
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: PathScanner und Pfad-Katalog`

---

### Task 7: Snapshots, Softwareupdate, Time Machine

**Files:** Create `Scanners/SnapshotScanner.swift`; Fixtures `tmutil-listlocalsnapshots.txt`, `softwareupdate-l.txt`; Test `SnapshotScannerTests.swift`

**Interfaces:**
- Produces: `struct SnapshotScanner: Scanner` (id `system.snapshots`) – ruft `/usr/bin/tmutil listlocalsnapshots /` auf. Liefert bis zu zwei Funde:
  - `system.snapshots.update`: Risk `.hintOnly`, `size: nil`, Items je Snapshot-Name mit `com.apple.os.update` oder `MSUPrepareUpdate`, Methode `.hint(.openURL(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!))`, Summary: „Diese Schnappschüsse hält macOS für ein ausstehendes Update fest. Sie verschwinden, sobald du das Update installierst und neu startest.“
  - `system.snapshots.timeMachine`: Risk `.review`, Items je `com.apple.TimeMachine.<Datum>.local`, Methode `.admin([AdminStep(executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", "<Datum>"])])`.
- `struct SoftwareUpdateScanner: Scanner` (id `system.softwareupdate`) – `/usr/sbin/softwareupdate -l`, Timeout 60 s; bei „* Label:“-Zeilen ein `.hintOnly`-Fund mit Update-Namen. Nur aktiv, wenn `ScanContext.includeSlowChecks == true` (neues Feld `var includeSlowChecks: Bool` in `ScanContext`, Default `false`; manuelles „Neu scannen“ setzt es `true`).

- [ ] **Step 1: Failing tests**
```swift
@Test func parsesUpdateAndTimeMachineSnapshots() async throws {
  let fake = FakeCommandRunner(); fake.stub("/usr/bin/tmutil", ["listlocalsnapshots", "/"], result: .fixture("tmutil-listlocalsnapshots.txt"))
  let fs = try await SnapshotScanner().scan(.test(runner: fake))
  let upd = fs.first { $0.id.key == "update" }!; #expect(upd.risk == .hintOnly && upd.size == nil && upd.items.count == 2)
  let tm = fs.first { $0.id.key == "timeMachine" }!; #expect(tm.method == .admin([AdminStep(executable: "/usr/bin/tmutil", arguments: ["deletelocalsnapshots", "2026-10-27-101500"])]))
}
@Test func noSnapshotsNoFinding() async throws { /* leere Ausgabe "Snapshots for disk /:" → [] */ }
```
Fixture-Inhalt `tmutil-listlocalsnapshots.txt`:
```
Snapshots for disk /:
com.apple.os.update-8F1C2E3A4B5D6E7F8091A2B3C4D5E6F708192A3B4C5D6E7F8091A2B3C4D5E6F7
com.apple.os.update-MSUPrepareUpdate
com.apple.TimeMachine.2026-10-27-101500.local
```
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: Snapshot- und Softwareupdate-Scanner`

---

### Task 8: Simulator-Scanner

**Files:** Create `Scanners/SimulatorScanner.swift`; Fixtures `simctl-runtime-list.json`, `simctl-devices-unavailable.json`; Test `SimulatorScannerTests.swift`

**Interfaces:**
- Consumes: `ToolLocator.xcrunAvailable` (Task 2).
- Produces:
  - `struct SimulatorRuntimeScanner: Scanner` (id `sim.runtimes`): nur wenn `xcrunAvailable`; `/usr/bin/xcrun simctl runtime list -j`, Timeout 60 s. Je Runtime ein Fund (`grouping` perMatch, key = `identifier`), Titel z. B. „iOS 18.2 Simulator“ (Plattform aus `platformIdentifier`: `com.apple.platform.iphonesimulator` → „iOS“, `xrsimulator` → „visionOS“, `watchsimulator` → „watchOS“, `appletvsimulator` → „tvOS“), `size = sizeBytes`, Risk `.review`, Methode `.tool([ToolCommand(tool: "xcrun", arguments: ["simctl", "runtime", "delete", id], timeout: .seconds(600))], fallback: nil)`, `keepSuggested = true` für die höchste Version je Plattform (Vergleich per numerischer Versionskomponenten), blocking `com.apple.iphonesimulator`. Status `"Deleting"` → überspringen.
  - `struct UnavailableSimulatorsScanner: Scanner` (id `sim.unavailable`): `xcrun simctl list devices unavailable -j`; ≥1 Gerät → ein Fund `.safe`, Methode `.tool([ToolCommand(tool: "xcrun", arguments: ["simctl", "delete", "unavailable"], timeout: .seconds(120))], fallback: nil)`, Größe = Summe der `dataPath`-Ordner via SizeMeter.

- [ ] **Step 1: Failing tests**
```swift
@Test func runtimesWithNewestPerPlatformKept() async throws {
  // Fixture: iOS 17.5, 18.0, 18.2, 26.0; xrOS 2.0; watchOS 11.0; tvOS 18.0 (Größen wie Briefing: iOS gesamt 32 GB, visionOS 6,8 GB …)
  let fs = try await SimulatorRuntimeScanner().scan(.test(runner: fakeWithXcodeAndFixture()))
  #expect(fs.count == 7)
  #expect(fs.filter(\.keepSuggested).map(\.title).sorted() == ["iOS 26.0 Simulator", "tvOS 18.0 Simulator", "visionOS 2.0 Simulator", "watchOS 11.0 Simulator"])
  #expect(fs.allSatisfy { $0.risk == .review && !$0.isPreselected(isKept: false) })
}
@Test func noXcodeNoRuntimes() async throws { /* xcode-select → CommandLineTools → [] und kein simctl-Aufruf in fake.calls */ }
```
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: Simulator-Runtimes über simctl`

---

### Task 9: Homebrew

**Files:** Create `Scanners/HomebrewScanner.swift`; Fixtures `brew-cleanup-n.txt`, `brew-autoremove-n.txt`, `brew-list-cask.txt`; Test `HomebrewScannerTests.swift`

**Interfaces:**
- Produces:
  - `struct HomebrewCleanupScanner: Scanner` (id `brew.cleanup`): brew-Pfad via `ctx.tools`, Env `ToolLocator.brewEnvironment`. Parst `brew cleanup --prune=all -n` Zeilen `Would remove: <pfad> (<größe>)` und `brew autoremove -n` (Formel-Namen nach `==> Would autoremove`). Ein Fund `.safe`, Items = Pfade (Größe gemessen) + Formeln, Methode `.tool([cleanup --prune=all, autoremove], fallback: nil)`. Claimt auch `brew --cache`.
  - `struct HomebrewCaskScanner: Scanner` (id `brew.cask`): `brew --prefix` → `<prefix>/Caskroom/<name>` für jeden Namen aus `brew list --cask`; Größe ≥ 200 MB → Fund `.review` (perMatch, key = Cask-Name), Methode `.tool([ToolCommand(tool: "brew", arguments: ["uninstall", "--cask", name], timeout: .seconds(300))], fallback: nil)`. Zap-Variante: `RemovalOptions.zap` (Task 15) hängt `--zap` an.
  - `enum HomebrewErrors { static func untrustedTap(in stderr: String) -> String? }` – erkennt „untrusted tap“ und liefert Tap-Namen; `ToolRemover` (Task 15) baut daraus den Hinweis.

- [ ] **Step 1: Failing tests**
```swift
@Test func parsesCleanupDryRun() async throws { /* Fixture mit 2 portable-ruby-Pfaden → 1 Fund, items enthalten beide Pfade, method tool mit "cleanup","--prune=all" und "autoremove" */ }
@Test func casksAbove200MBOnly() async throws { /* Caskroom/flutter 3,7 GB (Fixture-Datei groß genug simuliert via stub-SizeMeter? → stattdessen FixtureTree mit 210 MB sparse file) ; Caskroom/tiny 1 MB → nur flutter */ }
@Test func detectsUntrustedTap() {
  #expect(HomebrewErrors.untrustedTap(in: "Error: Refusing to load cask from untrusted tap homebrew/cask-versions") == "homebrew/cask-versions")
}
@Test func noBrewNoFindings() async throws { }
```
`FixtureTree.sparseFile(_:bytes:)` ergänzen (Datei mit `truncate`, belegte Größe klein!) – deshalb erhält `HomebrewCaskScanner` einen injizierbaren Größen-Callback `sizeOf: @Sendable (URL) async throws -> Int64` (Default `ctx.sizer.size`), damit der Test 3,7 GB vorgeben kann.
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: Homebrew-Aufräumen und Casks`

---

### Task 10: Werkzeug-Scanner Conda, Ollama, Rustup + Versionsordner

**Files:** Create `Scanners/ToolCacheScanners.swift`, `Scanners/VersionedDirScanner.swift`; Fixtures `ollama-list.txt`, `rustup-toolchain-list.txt`; Test `ToolCacheScannerTests.swift`, `VersionedDirScannerTests.swift`

**Interfaces:**
- Produces:
  - `struct CondaScanner: Scanner` (id `toolchains.conda`): findet Installationen (`/opt/anaconda3`, `/opt/miniconda3`, `~/anaconda3`, `~/miniconda3` via `ctx.absolute`/`homePath`); Fund 1 „Conda – Paket-Cache“ (`<inst>/pkgs` + `~/.conda/pkgs`, `.review`, `.tool([conda clean --all -y], fallback: nil)`); Fund 2 „Anaconda – ganze Installation“ (`.hintOnly`, Größe der Installation, Hinweis auf die offizielle Deinstallation `anaconda-clean` + Ordner entfernen).
  - `struct OllamaScanner: Scanner` (id `ai.ollama`): mit `ollama`: `ollama list` parsen (NAME, SIZE), je Modell Fund `.review`, `.tool([ollama rm <name>])`; ohne `ollama`: `~/.ollama/models` als ein Fund `.review`, `.delete`.
  - `struct RustupScanner: Scanner` (id `languages.rustup`): `rustup toolchain list` → je Toolchain `~/.rustup/toolchains/<name>`, `.review`, `.tool([rustup toolchain uninstall <name>])`, `keepSuggested` für die mit `(default)` markierte.
  - `struct VersionedDirScanner: Scanner { init(id: String, category: Category, titlePrefix: String, summary: String, base: PathBase, parent: String, risk: Risk, method: RemovalMethod, groupBy: @Sendable (String) -> String /* Plattform-Schlüssel */ ) }` – je Unterordner ein Fund, höchste Version je Gruppe `keepSuggested`. Versionsvergleich: `VersionCompare.isNewer(_ a: String, than b: String) -> Bool` (extrahiert erste `\d+(\.\d+)*`-Folge). Instanzen in `Catalog.allScanners()`: Device Support (`~/Library/Developer/Xcode/*DeviceSupport`, Gruppe = Elternordner), nvm (`~/.nvm/versions/node`), pyenv (`~/.pyenv/versions`), rbenv (`~/.rbenv/versions`).

- [ ] **Step 1: Failing tests**
```swift
@Test func versionCompare() {
  #expect(VersionCompare.isNewer("18.2 (22C150)", than: "17.5 (21F79)"))
  #expect(VersionCompare.isNewer("v22.11.0", than: "v20.18.0"))
  #expect(!VersionCompare.isNewer("3.9.1", than: "3.12.0"))
}
@Test func deviceSupportKeepsNewestPerPlatform() async throws { /* iOS DeviceSupport/17.5, 18.2; watchOS DeviceSupport/11.0 → keepSuggested für 18.2 und 11.0 */ }
@Test func ollamaUsesRmWhenInstalled() async throws { }
@Test func ollamaFallsBackToDeleteWithoutCli() async throws { }
@Test func condaCacheUsesCondaClean() async throws { }
```
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: Conda, Ollama, Rustup und Versionsordner`

---

### Task 11: TeX Live, persönliche Daten, Apps, Xcode-Versionen

**Files:** Create `Scanners/TeXLiveScanner.swift`, `Scanners/PersonalDataScanners.swift`, `Scanners/AppScanners.swift`; Test `TeXLiveScannerTests.swift`, `PersonalDataScannerTests.swift`, `AppScannerTests.swift`

**Interfaces:**
- Produces:
  - `struct TeXLiveScanner: Scanner` (id `toolchains.texlive`): Ordner `ctx.absolute("/usr/local/texlive")/<JJJJ>` (Regex `^\d{4}$`). Neuester = Fund mit `keepSuggested` **nicht** erzeugt, sondern ältere je ein Fund (`.review`, `.admin([AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive/<JJJJ>"])])`, Titel „TeX Live <JJJJ> (veraltet)“). Zusätzlich Fund „TeX Live komplett entfernen“ (`.review`, admin mit drei `rm -rf` für `/usr/local/texlive`, `/Library/TeX`, `/Applications/TeX`, Summary nennt BasicTeX-Alternative `brew install --cask basictex`). Admin-Pfade sind immer die **echten** absoluten Pfade (nicht `rootPrefix`), Messung über `rootPrefix`.
  - `struct MobileBackupScanner: Scanner` (id `personal.backups`): `~/Library/Application Support/MobileSync/Backup/*`, je Backup Fund (`.review`, `.trash`, `needsFullDiskAccess: true`), Gerät aus `Info.plist` Schlüssel `Device Name`, Datum `Last Backup Date`; Titel „Backup von <Gerät>“, Item-Detail „vom <Datum>“. Ohne Vollzugriff → ein Fund mit `size: nil`, Summary „Braucht Vollzugriff auf die Festplatte“.
  - `struct OldInstallerScanner: Scanner` (id `personal.installers`): `~/Downloads/*.{dmg,pkg,zip,xip,ipsw}` mit Änderungsdatum älter als 30 Tage (`ctx.now`), ein Fund `.review`, `.trash`, Items je Datei mit Datum.
  - `struct MessagesAttachmentsScanner: Scanner` (id `personal.messages`): `~/Library/Messages/Attachments` Größe, `.hintOnly`, Hinweis-Text aus Spec.
  - `struct UnusedAppsScanner: Scanner` (id `apps.unused`): `/Applications/*.app`, ohne Bundle-ID-Präfix `com.apple.` und ohne `de.frankjuchim.klarschiff2`; letzte Nutzung über injizierbaren Callback `lastUsed: @Sendable (URL) -> Date?` (Produktion: `MDItemCreate` + `kMDItemLastUsedDate`); älter als 180 Tage → ein Fund `.review`, `.trash`, Items je App mit Datum „zuletzt geöffnet am …“ bzw. „nie geöffnet“.
  - `struct LeftoverAppDataScanner: Scanner` (id `apps.leftovers`, `phase: .collector`): Kinder von `~/Library/{Containers,Application Support,Caches,HTTPStorages,WebKit}`, Name passt auf `^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+){2,}$`, nicht `com.apple.*`, nicht beansprucht, `isInstalled: @Sendable (String) -> Bool` (Produktion: `NSWorkspace.shared.urlForApplication(withBundleIdentifier:) != nil`) liefert false, Größe ≥ 10 MB → ein Fund `.review`, `.trash`, Items gruppiert nach Bundle-ID.
  - `struct ExtraXcodeScanner: Scanner` (id `xcode.extraVersions`): `/Applications/Xcode*.app` außer der aus `xcode-select -p` (Pfad bis `.app`), je App Fund `.review`, `.trash`.

- [ ] **Step 1: Failing tests**
```swift
@Test func texLiveOldYearsAreAdminFindings() async throws {
  let t = try FixtureTree(); try t.file("usr/local/texlive/2022/a", bytes: 1000); try t.file("usr/local/texlive/2025/a", bytes: 1000); try t.dir("usr/local/texlive/texmf-local")
  let fs = try await TeXLiveScanner().scan(.test(root: t.root))
  #expect(fs.map(\.title).contains("TeX Live 2022 (veraltet)"))
  #expect(!fs.map(\.title).contains("TeX Live 2025 (veraltet)"))
  #expect(fs.first { $0.title.contains("2022") }!.method == .admin([AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive/2022"])]))
}
@Test func installersOlderThan30Days() async throws { /* a.dmg 40 Tage, b.pkg 5 Tage, c.txt 90 Tage → nur a.dmg */ }
@Test func backupShowsDeviceAndNeedsFDA() async throws { /* Info.plist mit Device Name "Franks iPhone" → Titel "Backup von Franks iPhone"; hasFullDiskAccess=false → size nil */ }
@Test func leftoversOnlyUninstalledReverseDNS() async throws { /* com.foo.bar (nicht installiert, 20 MB) → Fund; com.apple.x, Google (kein DNS), com.installed.app → nicht */ }
@Test func unusedAppsSkipApple() async throws { }
```
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: TeX Live, persönliche Daten und App-Scanner`

---

### Task 12: Sammel-Scanner, Große Brocken, Fotos, Papierkorb

**Files:** Create `Scanners/CollectorScanners.swift`, `Scanners/BigChunksScanner.swift`, `Scanners/InfoScanners.swift`; Test `CollectorScannerTests.swift`, `BigChunksScannerTests.swift`

**Interfaces:**
- Produces:
  - `struct AppStoreCachesScanner: Scanner` (id `appCaches.appStore`, `.collector`): `~/Library/Containers/*/Data/Library/Caches/*` nicht beansprucht, ein Fund `.safe`, `.trash`, Items gruppiert je Container (Name über `displayName` der App, falls installiert), `needsFullDiskAccess: true`.
  - `struct OtherCachesScanner: Scanner` (id `appCaches.other`, `.collector`): `~/Library/Caches/*` nicht beansprucht, ausgenommen `com.apple.bird`, `CloudKit`, `com.apple.Safari.SafeBrowsing`, `com.apple.akd`, `com.apple.ap.adprivacyd`, `FamilyCircle`; ein Fund `.safe`, `.trash`, blocking = laufende Apps, deren Bundle-ID dem Ordnernamen entspricht (die betreffenden Items werden abgewählt, nicht der ganze Fund).
  - `struct BigChunk: Sendable, Identifiable { var id: URL { url }; var url: URL; var displayName: String; var size: Int64; var cleanableSize: Int64 }`
  - `struct BigChunksScanner: Sendable { func scan(_ ctx: ScanContext, findings: [Finding]) async -> [BigChunk] }` – Wurzeln und Regeln aus Spec 5.1, Schwelle 1 GB (1_000_000_000), absteigend sortiert, `cleanableSize` = Summe der Item-Größen aller Funde unter `url`. (Kein `Scanner`, läuft nach der ScanEngine.)
  - `struct PhotosInfo: Sendable { var librarySize: Int64; var libraryURL: URL }`, `func photosInfo(_ ctx: ScanContext) async -> PhotosInfo?` (`~/Pictures/*.photoslibrary`, größte).
  - `func trashSize(_ ctx: ScanContext) async -> Int64?` (`~/.Trash`; `nil` ohne Vollzugriff).

- [ ] **Step 1: Failing tests**
```swift
@Test func otherCachesSkipClaimedAndSystemSpecials() async throws { /* Caches/com.spotify.client (frei), Caches/com.apple.bird, Caches/org.swift.swiftpm (claimed) → nur spotify */ }
@Test func bigChunksAboveOneGBWithCleanablePart() async throws {
  // stub sizes: Application Support/Claude = 13_060_000_000, Autodesk = 11_110_000_000, Small = 500_000_000; Finding mit Item unter Claude, 12_040_000_000
  let chunks = await BigChunksScanner(sizeOf: stub).scan(ctx, findings: [claudeFinding])
  #expect(chunks.map(\.displayName) == ["Claude", "Autodesk"])
  #expect(chunks[0].cleanableSize == 12_040_000_000)
}
```
`BigChunksScanner(sizeOf:)` mit injizierbarem Größen-Callback wie in Task 9.
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: Sammel-Scanner, Große Brocken, Fotos, Papierkorb`

---

### Task 13: DiskInfo und FullDiskAccess

**Files:** Create `System/DiskInfo.swift`, `System/FullDiskAccess.swift`; Test `DiskInfoTests.swift`

**Interfaces:**
- Produces:
  - `struct DiskSpace: Sendable, Equatable { var free: Int64; var total: Int64 }`, `enum DiskInfo { static func current(volume: URL = URL(filePath: "/System/Volumes/Data")) throws -> DiskSpace }` (`volumeAvailableCapacityForImportantUsageKey`, `volumeTotalCapacityKey`).
  - `enum FullDiskAccess { static func isGranted(home: URL) -> Bool /* versucht contentsOfDirectory von ~/Library/Containers/com.apple.stocks, dann ~/Library/Safari; true bei Erfolg */; static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")! }`
- [ ] **Step 1: Failing test** `@Test func diskInfoReportsPlausibleValues() throws { let d = try DiskInfo.current(volume: URL(filePath: "/")); #expect(d.total > 0 && d.free > 0 && d.free <= d.total) }`
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: DiskInfo und Vollzugriffsprüfung`

---

### Task 14: Remover und Admin-Skript

**Files:** Create `Removal/Remover.swift`, `Removal/TrashRemover.swift`, `Removal/DeleteRemover.swift`, `Removal/ToolRemover.swift`, `Removal/PrivilegedExecutor.swift`, `Removal/AdminScriptBuilder.swift`, `Removal/AppleScriptPrivilegedExecutor.swift`; Test `RemoverTests.swift`, `AdminScriptBuilderTests.swift`

**Interfaces:**
- Consumes: `SafetyGuard` (Task 4), `CommandRunner` (Task 2), `HomebrewErrors` (Task 9).
- Produces:
  - `enum ItemOutcome: Sendable, Equatable { case removed(freed: Int64?), skipped(String), failed(String), cancelled }`
  - `struct ItemResult: Sendable { var findingID: FindingID; var itemID: String?; var outcome: ItemOutcome }`
  - `protocol Remover: Sendable { func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] }`
  - `struct TrashRemover: Remover { init(guard: SafetyGuard) }` (`FileManager.trashItem`), `struct DeleteRemover: Remover { init(guard: SafetyGuard) }` (`removeItem`). Beide: jedes Item zuerst `guard.check` → bei `.denied(reason)` `failed("Gesperrt: \(reason)")`. `dryRun` → `skipped("Trockenlauf")`, nichts passiert.
  - `struct ToolRemover: Remover { init(runner: CommandRunner, tools: ToolLocator) }` – führt die `ToolCommand`s des Funds der Reihe nach aus (Executable via `tools.path(for:)`, `xcrun` = `/usr/bin/xcrun`, Env bei brew `ToolLocator.brewEnvironment`); Exit ≠ 0 → `failed(stderr gekürzt)`; untrusted tap → `failed("Homebrew vertraut diesem Tap nicht. Führe nacheinander aus: brew trust <tap> · brew uninstall --cask <name> · brew untap <tap>")`.
  - `protocol PrivilegedExecutor: Sendable { func run(_ steps: [AdminStep]) async -> AdminRunResult }`, `enum AdminRunResult: Sendable, Equatable { case completed([Int32]) /* Exit je Schritt */, cancelled, failed(String) }`.
  - `enum AdminScriptBuilder { static func script(for steps: [AdminStep]) -> String; static func parse(_ output: String, stepCount: Int) -> [Int32] }` – Skript: je Schritt eine Zeile `<quoted exe> <quoted args…>; echo "KS_STEP <n> $?"` (kein `set -e`, damit alle Schritte laufen), Quoting über `ShellQuote.quote`.
  - `struct AppleScriptPrivilegedExecutor: PrivilegedExecutor` – `NSAppleScript(source: "do shell script \(appleScriptString(script)) with administrator privileges")`, auf dem Main Actor ausgeführt; Fehler `-128` → `.cancelled`.
  - `struct AdminRemover { init(executor: PrivilegedExecutor, guard: SafetyGuard); func remove(_ batch: [(Finding, [FindingItem])], dryRun: Bool) async -> [ItemResult] }` – prüft jedes `rm`-Ziel (letztes Argument von `/bin/rm`) mit `guard`; gesperrte Schritte fallen raus (`failed`), Rest in **einem** `executor.run`.

- [ ] **Step 1: Failing tests**
```swift
@Test func scriptQuotesHostilePaths() {
  let s = AdminScriptBuilder.script(for: [AdminStep(executable: "/bin/rm", arguments: ["-rf", "/usr/local/texlive/20 22'$(touch x)\""])])
  #expect(s == "/bin/rm -rf '/usr/local/texlive/20 22'\\''$(touch x)\"'; echo \"KS_STEP 0 $?\"")
}
@Test func parsesStepMarkers() {
  #expect(AdminScriptBuilder.parse("foo\nKS_STEP 0 0\nKS_STEP 1 1\n", stepCount: 2) == [0, 1])
  #expect(AdminScriptBuilder.parse("KS_STEP 0 0\n", stepCount: 2) == [0, -1])
}
@Test func trashRemoverRefusesGuardedPath() async throws { /* Item ~/Documents/x → failed("Gesperrt: …"), Datei existiert noch */ }
@Test func trashRemoverMovesFile() async throws { }
@Test func dryRunTouchesNothing() async throws { }
@Test func cancelledAdminMarksAllCancelled() async { /* FakeExecutor → .cancelled → alle ItemResults .cancelled */ }
@Test func adminSkipsGuardedRmTarget() async { /* Schritt rm -rf /System → failed, Executor bekommt nur den erlaubten Schritt */ }
@Test func toolRemoverReportsUntrustedTap() async { }
```
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: Remover mit SafetyGuard und gebündeltem Admin-Skript`

---

### Task 15: RemovalPlan und RemovalRunner

**Files:** Create `Removal/RemovalPlan.swift`, `Removal/RemovalRunner.swift`; Test `RemovalRunnerTests.swift`

**Interfaces:**
- Consumes: alle Remover (Task 14), `RunningApps` (Task 5), `DiskInfo` (Task 13).
- Produces:
  - `struct RemovalOptions: Sendable { var deleteDirectly: Set<FindingID> /* P > 10 GB, im Dialog gewählt */; var zap: Set<FindingID>; var dryRun: Bool }`
  - `struct RemovalPlan: Sendable { init(findings: [Finding], selection: [FindingID: Set<String>] /* gewählte Item-IDs, wie AppModel.selection */, options: RemovalOptions); var toolSteps, trashSteps, deleteSteps, adminSteps: [(Finding, [FindingItem])]; var needsAdmin: Bool; var totalSize: Int64; var directDeleteCandidates: [Finding] /* risk == .review, method == .trash, size > 10_000_000_000 */; var commandPreview: [String] }` – `.hint` wird nie eingeplant; `deleteDirectly` verschiebt aus trash nach delete; `zap` hängt `--zap` an brew-uninstall an.
  - `struct RemovalReport: Sendable { var results: [ItemResult]; var freedBytes: Int64 /* DiskInfo nachher − vorher, min 0 */; var failures: [ItemResult] }`
  - `struct RemovalRunner: Sendable { init(trash: Remover, delete: Remover, tool: Remover, admin: AdminRemover, runningApps: RunningApps, diskSpace: @Sendable () throws -> DiskSpace); func run(_ plan: RemovalPlan, progress: @Sendable (String) -> Void) async -> RemovalReport }` – Reihenfolge: (1) blockierende Apps **unmittelbar vor jedem Fund neu prüfen** → `skipped("<App> läuft – vorher beenden")`; (2) tool, (3) trash, (4) delete, (5) admin gebündelt.

- [ ] **Step 1: Failing tests**
```swift
@Test func orderIsToolTrashDeleteAdmin() async { /* RecordingRemover-Attrappen protokollieren Reihenfolge */ }
@Test func skipsFindingWhoseAppStartedMeanwhile() async { /* FakeRunningApps meldet Xcode erst zur Laufzeit → Instruments-Fund skipped("Xcode läuft – vorher beenden"), Rest läuft */ }
@Test func hintsAreNeverPlanned() { }
@Test func bigReviewItemsOfferDirectDelete() { /* review+trash 12 GB → in directDeleteCandidates; mit options.deleteDirectly → in deleteSteps */ }
@Test func adminCancelKeepsOtherResults() async { /* trash ok + admin cancelled → report enthält removed und cancelled */ }
@Test func zapAppendsFlag() { }
```
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: RemovalPlan und RemovalRunner`

---

### Task 16: App-Rahmen und AppModel

**Files:** Create `App/Model/AppModel.swift`, `App/Views/Chrome/BackgroundView.swift`, `HeaderView.swift`, `TabBarView.swift`, `CapacityCard.swift`, `PlaceholderTab.swift`; Modify `App/KlarschiffApp.swift`; Test `AppTests/AppModelTests.swift` (App-Test-Target in `project.yml`)

**Interfaces:**
- Consumes: `ScanEngine`, `Catalog.allScanners()`, `BigChunksScanner`, `KeepList`, `RemovalRunner`, `DiskInfo`, `FullDiskAccess`.
- Produces: `@MainActor @Observable final class AppModel { var selectedTab: AppTab; var disk: DiskSpace?; var isScanning: Bool; var scanProgress: Double; var report: ScanReport?; var bigChunks: [BigChunk]; var photos: PhotosInfo?; var trashBytes: Int64?; var hasFullDiskAccess: Bool; var selection: [FindingID: Set<String>] /* gewählte Item-IDs */; var kept: Set<FindingID>; var lastRemoval: RemovalReport?; func scan(includeSlowChecks: Bool) async; func findings(in tab: AppTab) -> [(Category, [Finding])]; func selectedSize(in tab: AppTab) -> Int64; func foundSize(in tab: AppTab) -> Int64; func toggle(_ id: FindingID); func toggleItem(_ id: FindingID, item: String); func keep(_ id: FindingID) async; func unkeep(_ id: FindingID) async; func makePlan(tab: AppTab, options: RemovalOptions) -> RemovalPlan; func execute(_ plan: RemovalPlan) async; func emptyTrash() async; func terminate(_ app: AppRef) async }`. Nach `scan` wird die Auswahl über `Finding.isPreselected` gesetzt. Startargument `--dry-run` setzt `RemovalOptions.dryRun` global.
- Optik: Spec 4.1 – Hintergrund aus 3–4 großen, weichgezeichneten Farbkreisen (Türkis `#7FE3D8`, Violett `#B9A6FF`, Rosa `#F7B8E0`, Hellblau `#A9C8FF`) auf `#F4F5FB`; Karten `.glassEffect(.regular, in: .rect(cornerRadius: 22))`; Wortmarke `Text("Klarschiff").font(.system(size: 44, weight: .heavy, design: .rounded))` mit `LinearGradient` Türkis `#2EC4B6` → Violett `#7B61FF`; Tab-Pillen mit `GlassEffectContainer`, aktiver Tab Verlaufsfüllung; Fenster-Mindestgröße 1000×720, Inhalt max. 1250 pt breit.

- [ ] **Step 1: Failing tests** (`AppModel` mit injizierten Fakes über `init(dependencies: AppDependencies)`; `AppDependencies` bündelt Engine, KeepList, RemovalRunner, Disk-Closure)
```swift
@Test @MainActor func scanPreselectsOnlySafe() async { /* Fake-Engine liefert safe+review → selection enthält nur safe */ }
@Test @MainActor func keptFindingDeselectedAndPersisted() async { }
@Test @MainActor func sizesPerTab() async { /* storage vs developer getrennt summiert */ }
```
- [ ] **Step 2–4:** Run `xcodebuild test -scheme Klarschiff -destination 'platform=macOS'` → FAIL, implement, → PASS.
- [ ] **Step 5: Manuell prüfen:** App starten → Header, 5 Tabs, Kapazitätskarte mit echten Werten, Platzhalter in Systemdaten/Hintergrunddienste/Leistung („Kommt bald: Hier erklärt Klarschiff, woraus ‚Systemdaten‘ besteht.“ usw.).
- [ ] **Step 6: Commit** `feat: App-Rahmen, Tabs und AppModel`

---

### Task 17: Tabs „Speicher“ und „Entwickler“

**Files:** Create `App/Views/Cleanup/CleanupTabView.swift`, `SummaryCard.swift`, `CategorySection.swift`, `FindingCard.swift`, `FindingItemsList.swift`, `CommandSheet.swift`, `KeepSection.swift`, `ConfirmSheet.swift`, `ResultBanner.swift`, `FullDiskAccessCard.swift`, `BigChunksCard.swift`, `PhotosCard.swift`

**Interfaces:**
- Consumes: `AppModel` (Task 16).
- Produces: `struct CleanupTabView: View { let tab: AppTab }` – für `.storage` und `.developer` (Speicher zusätzlich Fotos, Große Brocken, Papierkorb-Knopf).
- Texte (exakt):
  - Summary-Unterzeile: „ausgewählt von \(found) gefunden“
  - Regeltext: „Vorausgewählt ist nur, was sich von selbst wieder aufbaut. Großes wird direkt gelöscht, alles andere landet im Papierkorb.“
  - Knöpfe: „Neu scannen“, „Aufräumen“, „Papierkorb leeren (\(size))“, „Befehl anzeigen“, „Kopieren“, „Immer behalten“, „Nicht mehr behalten“, „Beenden“, „Im Finder zeigen“
  - Warnung: „App läuft – vorher beenden“; Pille: „Neueste – behalten empfohlen“
  - Behalten-Bereich: „Behalten (\(n))“
  - Bestätigung Titel: „\(size) aufräumen?“; Zeilen je Methode: „In den Papierkorb“, „Wird direkt gelöscht – nicht im Papierkorb“, „Über \(tool) entfernt“, „Braucht dein Admin-Passwort (eine Abfrage)“; Option bei Kandidaten > 10 GB: „Direkt löschen statt Papierkorb (schafft sofort Platz)“; Cask-Option: „Auch Einstellungen entfernen (zap)“; Knöpfe „Abbrechen“ / „Aufräumen“
  - Ergebnis: „\(freed) frei geworden.“ bzw. bei Fehlern zusätzlich „\(n) Einträge konnten nicht entfernt werden.“ (aufklappbar mit Grund je Eintrag)
  - Vollzugriff: Titel „Klarschiff braucht Vollzugriff auf die Festplatte“, Text „Sonst bleiben Backups, Mail-Anhänge, Container-Caches und der Papierkorb unsichtbar. Klarschiff liest nur, gelöscht wird nur, was du auswählst.“, Knopf „Systemeinstellungen öffnen“
  - Große Brocken: Titel „Große Brocken“, Text „Ordner über 1 GB. Klarschiff löscht hier nur, was oben gelistet ist – den Rest räumst du am besten in der jeweiligen App auf oder deinstallierst die App.“, Zusatz grün „davon \(size) oben aufräumbar“
  - Fotos: Titel „Fotos-Mediathek“, Text „Klarschiff löscht keine Fotos. Mit ‚Mac-Speicher optimieren‘ lagert Fotos Originale in iCloud aus – aber erst, wenn der Speicher knapp wird. Ob alles hochgeladen ist, steht unten in der Mediathek.“
  - Scan-Fehler-Karte: „Konnte nicht geprüft werden: \(message)“
  - Größe `nil`: „Größe nicht messbar“
- Verhalten: Hinweis-Karten ohne Auswahlkreis, mit Aktionsknopf (`HintAction`); Größen-Spalte rechts; Chevron klappt `FindingItemsList` auf (Einzelauswahl, Lupe = `NSWorkspace.shared.activateFileViewerSelecting`); `CommandSheet` zeigt `finding.commandPreview` bzw. für die Bestätigung `plan.commandPreview`, monospaced, `textSelection(.enabled)`, Kopieren über `NSPasteboard`. Während des Scans: Fortschrittsbalken in der Summary-Karte, Knöpfe deaktiviert.

- [ ] **Step 1:** Views gemäß Interfaces bauen; SwiftUI-Previews mit `AppModel.preview` (Fake-Daten aus dem Briefing: Instruments 102 GB, iOS-Runtimes, TeX Live 2022 …).
- [ ] **Step 2: Build** `xcodebuild … build` → `BUILD SUCCEEDED`; App-Tests → PASS.
- [ ] **Step 3: Manuell (Trockenlauf)** App mit `--dry-run` starten → Neu scannen → Funde erscheinen in beiden Tabs, Vorauswahl nur „Sicher“, Aufräumen zeigt Bestätigung mit Befehlen, Ergebnis „Trockenlauf“, nichts gelöscht (Größen nach Neu-Scan gleich).
- [ ] **Step 4: Commit** `feat: Tabs Speicher und Entwickler`

---

### Task 18: Pfade am echten Mac verifizieren, Release-Skript, Abnahme

**Files:** Modify `Scanners/Catalog.swift` (Claude-Cowork-VM, Telegram-Pfad); Create `scripts/release.sh`, `README.md`; Test `CatalogTests.swift` (neue Fälle)

- [ ] **Step 1: Ermitteln** auf dem Mac (read-only):
  `du -sh ~/Library/Application\ Support/Claude/* | sort -h | tail` → VM-Bundle-Ordner (~12 GB) für Regel `ai.coworkVM` eintragen (Methode `.delete`, Risk `.review`, Summary aus Klarschiff 1: „Virtuelle Maschine für Cowork. Wird bei der nächsten Nutzung erneut heruntergeladen (~12 GB). Lohnt sich, wenn du Cowork selten nutzt.“).
  `ls ~/Library/Group\ Containers | grep -i telegram` → Telegram-Muster bestätigen/korrigieren.
- [ ] **Step 2: Test** für `ai.coworkVM` gegen Fixture mit dem ermittelten Ordnernamen → PASS.
- [ ] **Step 3: `scripts/release.sh`** (bash, `set -euo pipefail`): `xcodegen generate` → `xcodebuild archive -scheme Klarschiff -archivePath build/Klarschiff.xcarchive` → `xcodebuild -exportArchive` mit `ExportOptions.plist` (`method = developer-id`) → `ditto -c -k` → `xcrun notarytool submit … --keychain-profile klarschiff-notary --wait` → `xcrun stapler staple` → `hdiutil create` DMG `build/Klarschiff-<version>.dmg`. README beschreibt einmalig `xcrun notarytool store-credentials klarschiff-notary` und `Config/Local.xcconfig` mit `DEVELOPMENT_TEAM = <TeamID>`.
- [ ] **Step 4: Abnahme (Trockenlauf, echter Mac):** App mit `--dry-run`, Neu scannen. Checkliste gegen Spec Abschnitt 1: Instruments-Caches (falls vorhanden), Simulator-Runtimes mit „Neueste – behalten empfohlen“, Update-Snapshots als Hinweis (falls vorhanden), Homebrew-Aufräumen, Casks > 200 MB, TeX Live alte Jahrgänge (falls vorhanden), Gradle/Android, Arduino, Anaconda, Xcode-Aufschlüsselung, Große Brocken mit „davon … oben aufräumbar“. Ergebnis als Liste in `docs/superpowers/plans/2026-10-29-abnahme.md` festhalten.
- [ ] **Step 5: Echter Lauf, klein:** einen „Sicher“-Fund (z. B. Homebrew-Aufräumen) und einen Papierkorb-Fund wirklich entfernen; einen Admin-Fund nur, wenn vorhanden und gewollt → Passwortabfrage erscheint **einmal**.
- [ ] **Step 6: Commit** `feat: verifizierte Pfade, Release-Skript, Abnahmeprotokoll`
