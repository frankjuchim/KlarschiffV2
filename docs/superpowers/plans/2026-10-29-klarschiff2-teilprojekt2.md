# Klarschiff 2 – Teilprojekt 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tab „Systemdaten“, der den Datenträger in Volumes und Systembereiche aufschlüsselt, erklärt und vier Systemfunde mit deutlichen Warnungen aufräumbar macht.

**Architecture:** Neue Core-Bausteine in `Packages/KlarschiffCore/Sources/KlarschiffCore/SystemData/` (VolumeInventory, SystemAreaCatalog + AssetNameMap, SystemDataScanner, SystemCleanupScanners) liefern einen `SystemDataReport`. Die Aufräum-Funde sind normale `Finding`s der neuen Kategorie `systemData` und laufen über die vorhandene Kette `RemovalPlan`/`RemovalRunner`/SafetyGuard. Die App bekommt einen eigenen Tab-View und misst beim ersten Öffnen.

**Tech Stack:** Swift 6 (Strict Concurrency), SwiftUI (macOS 26, Liquid Glass), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-29-klarschiff2-teilprojekt2-design.md` (verbindlich; Katalogtabellen, Texte und Warnzeilen stehen dort und werden hier nicht wiederholt). TP1-Spec und -Code gelten weiter.

## Global Constraints

- Alle Global Constraints aus dem TP1-Plan gelten weiter (Swift 6 strict, Du-Form, `ByteFormat`, kein Löschen ohne `SafetyGuard`, kein `#` in `commandPreview`, Werkzeuge nur über `CommandRunner`, alle Pfade aus `ScanContext`).
- Anzeigename „Klarschiff 2“ in neuen Texten.
- Systemfunde: Kategorie `systemData`, Risiko `.review`, **nie vorausgewählt**.
- Neue Admin-Allow-Liste-Einträge: **nur** `/usr/bin/log` mit exakt `["erase", "--all"]`.
- SafetyGuard-Erweiterung **nur**: Kinder von `/Library/Caches` und `/Library/Logs` (nicht die Ordner selbst) und Inhalt des eigenen `DARWIN_USER_TEMP_DIR` (nie der Ordner selbst, nie fremde `T/`).
- Messung nur lesend, kein Admin; Timeouts: `diskutil` 30 s, Bereich 120 s.
- Opt-in-Livetests nur mit `KLARSCHIFF_LIVE_SCAN=1`.

## Review Focus

1. **Symlink im eigenen `T/` nach `~/Documents` oder `/System`** → SafetyGuard verweigert, der Temp-Fund bietet ihn nicht an. Test in Task 1 und Task 5.
2. **`/Library/Caches` selbst bzw. `/Library/Logs` selbst als Ziel** (z. B. leerer Name, `.`/`..`) → verweigert; nur echte Kinder. Test in Task 1.
3. **Gesperrte Unterordner beim Messen** (`/private/var/db`, AssetsV2 ohne Rechte) → Bereich „mindestens …“, keine 0 und kein Absturz; `unaccounted` nie negativ. Test in Task 4.
4. **`diskutil` fehlt/hängt/liefert Unerwartetes** → Bericht ohne Volumen-Aufteilung, Bereiche trotzdem gemessen. Test in Task 2 und Task 4.
5. **Systemfund in einem Plan ohne Häkchen „Ich habe verstanden …“** → „Aufräumen“ gesperrt, kein Return-Shortcut, auch wenn die Admin-Schritte schon gesperrt sind. Test in Task 6.

---

### Task 1: Sicherheit und Kategorie für Systemfunde

**Files:**
- Modify: `Model/Category.swift`, `Safety/SafetyGuard.swift`, `Removal/AdminRemover.swift`, `App/Model/AppModel.swift` (live wiring: `userTempDir`)
- Test: `SafetyGuardTests.swift`, `RemoverTests.swift`, Kategorie-Test in `FindingTests.swift`

**Interfaces:**
- Produces:
  - `Category.systemData` (`tab: .systemData`, `title: "Systemdaten"`, `symbol: "chart.pie"`), angehängt nach den bestehenden Fällen.
  - `SafetyGuard.init(home: URL, userCacheDir: URL, allowedCacheSubdirs: Set<String>, userTempDir: URL? = nil)` – bestehende Aufrufe kompilieren weiter; `userTempDir` wird wie `userCacheDir` kanonisiert/validiert (muss unter `/private/var/folders/<a>/<b>/T` liegen, sonst ignoriert).
  - `SafetyGuard.userTempDirectory() -> URL?` (`confstr(_CS_DARWIN_USER_TEMP_DIR)`), `production(home:)` setzt ihn.
  - AdminRemover erlaubt `AdminStep(executable: "/usr/bin/log", arguments: ["erase", "--all"])`, sonst unverändert.

- [ ] **Step 1: Failing tests**
```swift
// SafetyGuardTests (home /Users/test, cache /private/var/folders/ab/xyz/C, temp /private/var/folders/ab/xyz/T)
@Test(arguments: ["/Library/Caches/com.example.app", "/Library/Logs/DiagnosticReports/x.ips",
                  "/private/var/folders/ab/xyz/T/old.tmp"])
func allowsSystemDataTargets(_ p: String) { #expect(guardWithTemp.check(URL(filePath: p)) == .allowed) }
@Test(arguments: ["/Library/Caches", "/Library/Logs", "/Library/Caches/..", "/private/var/folders/ab/xyz/T",
                  "/private/var/folders/cd/other/T/x", "/private/var/db/diagnostics", "/Library/Preferences/x"])
func deniesOtherSystemPaths(_ p: String) { #expect(guardWithTemp.check(URL(filePath: p)) != .allowed) }
@Test func deniesSymlinkFromTempToDocuments() throws { /* FixtureTree: T/evil → home/Documents → denied */ }
// RemoverTests
@Test func adminAllowsLogEraseAll() async { /* step log erase --all → executor receives it */ }
@Test(arguments: [["erase"], ["show"], ["erase", "--all", "x"]])
func adminDeniesOtherLogCommands(_ args: [String]) async { /* failed("Gesperrt: Unbekanntes Admin-Werkzeug") */ }
@Test func systemDataCategory() { #expect(Category.systemData.tab == .systemData && Category.systemData.title == "Systemdaten") }
```
- [ ] **Step 2: Run** `swift test --package-path Packages/KlarschiffCore` → FAIL.
- [ ] **Step 3: Implement** per Interfaces; die Allow-Regeln greifen nach den globalen Sperren (Caskroom etc.) wie bestehende Regeln. Live-Wiring in `AppDependencies.live()` übergibt `userTempDirectory()`. Wo `switch` über `Category` exhaustiv ist (App), `systemData` ergänzen.
- [ ] **Step 4: Run** Core-Tests + `xcodegen generate && xcodebuild -scheme Klarschiff -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` → PASS.
- [ ] **Step 5: Commit** `feat: SafetyGuard und Admin-Liste für Systemdaten-Funde`

---

### Task 2: VolumeInventory

**Files:**
- Create: `SystemData/VolumeInventory.swift`; Fixture `Fixtures/diskutil-apfs-list.plist` (auf Franks Mac aufnehmen: `diskutil apfs list -plist`); Test `VolumeInventoryTests.swift`

**Interfaces:**
- Produces:
  - `enum VolumeRole: String, Sendable { case system, preboot, recovery, vm, data, simulator, other }`
  - `struct APFSVolume: Sendable, Equatable { var name: String; var role: VolumeRole; var consumed: Int64 }`
  - `struct VolumeInventoryResult: Sendable { var containerSize: Int64; var containerFree: Int64; var volumes: [APFSVolume] /* Startcontainer */; var simulatorVolumes: [APFSVolume] /* aus anderen Containern, Name endet auf „Simulator“ */ }`
  - `enum VolumeInventory { static func read(runner: CommandRunner) async throws -> VolumeInventoryResult; static func parse(_ plist: Data, dataVolumeHint: String = "Data") throws -> VolumeInventoryResult }` – Startcontainer = der Container mit einem Volume der Rolle `Data`; `diskutil` über `/usr/sbin/diskutil` mit `["apfs", "list", "-plist"]`, Timeout 30 s; Exit ≠ 0 / ungültige Plist → throw.

- [ ] **Step 1: Failing tests** – `parsesRecordedMac`: aus der Fixture Rollen System/Preboot/Recovery/VM/Data vorhanden, `data.consumed > 0`, `containerSize > containerFree`, `simulatorVolumes.first?.name.hasSuffix("Simulator") == true` (falls in der Fixture); `failsOnGarbage`: `parse(Data("x".utf8))` wirft; `readThrowsOnNonZeroExit` mit `FakeCommandRunner`.
- [ ] **Step 2–4:** Run → FAIL, implement (PropertyListSerialization; Schlüssel aus der echten Fixture übernehmen), Run → PASS.
- [ ] **Step 5: Commit** `feat: APFS-Volumes lesen`

---

### Task 3: Bereichs-Katalog und Asset-Namen

**Files:**
- Create: `SystemData/SystemArea.swift`, `SystemData/SystemAreaCatalog.swift`, `SystemData/AssetNameMap.swift`; Test `SystemAreaCatalogTests.swift`

**Interfaces:**
- Produces:
  - `enum AreaVerdict: Sendable, Equatable { case keep, cleanable, seeFinding(scannerID: String, tab: AppTab) }`
  - `struct SystemAreaDefinition: Sendable { var id: String; var path: String /* absolut, über ctx.absolute */; var title: String; var summary: String; var verdict: AreaVerdict; var children: [SystemAreaDefinition] = []; var restTitle: String? /* Titel des „Rest von“-Kinds, nil = kein Rest */ }`
  - `struct SystemArea: Sendable, Identifiable { var id: String; var url: URL; var title: String; var summary: String; var verdict: AreaVerdict; var size: Int64?; var isLowerBound: Bool; var children: [SystemArea] }`
  - `enum SystemAreaCatalog { static func definitions() -> [SystemAreaDefinition] }` – exakt die Tabelle Spec §3.2 (ids, Klarnamen, Einstufungen). `/private/var/folders/*/*/C|T` wird beim Messen aufgelöst (Task 4), hier als Muster-Pfad mit `*`.
  - `enum AssetNameMap { static func entry(forAssetDirectory name: String) -> (title: String, verdict: AreaVerdict) }` – Spec §3.3; Präfix `com_apple_MobileAsset_` wird entfernt; unbekannt → Rohname, „Systemkomponente“, `.keep`.

- [ ] **Step 1: Failing tests**
```swift
@Test func catalogHasSpecIDs() {
  let ids = SystemAreaCatalog.definitions().flatMap { [$0.id] + $0.children.map(\.id) }
  for id in ["var.folders.caches","var.folders.temp","var.vm","var.db.diagnostics","library.caches","library.logs","assets","developer","opt","usrlocal"] { #expect(ids.contains(id)) }
}
@Test func assetNames() {
  #expect(AssetNameMap.entry(forAssetDirectory: "com_apple_MobileAsset_iOSSimulatorRuntime").verdict == .seeFinding(scannerID: "sim.runtimes", tab: .developer))
  #expect(AssetNameMap.entry(forAssetDirectory: "com_apple_MobileAsset_MacSoftwareUpdate").title == "Heruntergeladenes macOS-Update")
  #expect(AssetNameMap.entry(forAssetDirectory: "com_apple_MobileAsset_FooBar").title == "FooBar")
}
@Test func everyDefinitionHasGermanText() { /* title/summary nicht leer, kein "#" */ }
```
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: Katalog der Systembereiche und Asset-Klarnamen`

---

### Task 4: SystemDataScanner und Bericht

**Files:**
- Create: `SystemData/SystemDataScanner.swift`, `SystemData/SystemDataReport.swift`; Test `SystemDataScannerTests.swift`

**Interfaces:**
- Consumes: `VolumeInventory` (Task 2), `SystemAreaCatalog`/`AssetNameMap` (Task 3), `SizeMeter`, `SnapshotScanner` (TP1, liefert Findings `update`/`timeMachine`).
- Produces:
  - `struct SystemDataReport: Sendable { var measuredAt: Date; var inventory: VolumeInventoryResult?; var areas: [SystemArea]; var userData: Int64; var systemAreasTotal: Int64; var unaccounted: Int64; var snapshotFindings: [Finding]; var cleanupFindings: [Finding]; var failures: [ScanFailure] }`
  - `struct SystemDataScanner: Sendable { init(areaTimeout: Duration = .seconds(120), sizeOf: (@Sendable (URL) async throws -> (size: Int64, complete: Bool))? = nil, cleanupScanners: [Scanner] = [] /* Task 5 setzt den Default auf SystemCleanup.scanners() */); func scan(_ ctx: ScanContext, progress: @Sendable (Int, Int) -> Void) async -> SystemDataReport }`
  - `SizeMeter` bekommt `func measure(_ url: URL) async throws -> (size: Int64, complete: Bool)` (complete = false, wenn ein Unterordner nicht lesbar war); `size(of:)` bleibt unverändert.
  - Regeln: `/private/var/folders/*/*/{C,T}` je Treffer summiert; Unterbereiche „Rest von X“ = X − Summe benannter Kinder (min 0); AssetsV2-Kinder je Verzeichnis über `AssetNameMap`; `userData` = Home + `/Applications`; `systemAreasTotal` = Summe der Wurzelbereiche; `unaccounted = max(0, dataVolume.consumed − userData − systemAreasTotal)` (ohne Inventory: 0 und Hinweis in `failures`); Bereich mit Timeout → `size nil`, Fehler in `failures`, Rest läuft; `isLowerBound` vererbt sich nach oben.

- [ ] **Step 1: Failing tests** (FixtureTree als `rootPrefix`, gestubbte `sizeOf`, FakeCommandRunner mit `diskutil`-Fixture und `tmutil`-Fixture aus TP1)
```swift
@Test func sumsAreasAndRest() async { /* /Library 10 GB mit Caches 3 GB + Logs 1 GB → library.other == 6 GB */ }
@Test func unaccountedNeverNegative() async { /* data.consumed kleiner als Summe → unaccounted == 0 */ }
@Test func lockedSubfolderMarksLowerBound() async { /* sizeOf liefert complete:false für var.db → isLowerBound true auf var.db und Wurzel */ }
@Test func assetsGroupedWithNames() async { /* AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime → Kind „iOS-Simulator“, seeFinding */ }
@Test func diskutilFailureStillMeasuresAreas() async { /* diskutil exit 1 → inventory nil, areas nicht leer, failures enthält Hinweis */ }
@Test func areaTimeoutIsolated() async { /* sizeOf hängt für opt → opt.size nil, andere gemessen */ }
```
- [ ] **Step 2–4:** Run → FAIL, implement (TaskGroup, Timeout-Muster wie `ScanEngine`), Run → PASS.
- [ ] **Step 5: Commit** `feat: Systemdaten messen`

---

### Task 5: Aufräum-Funde für Systemdaten

**Files:**
- Create: `SystemData/SystemCleanupScanners.swift`; Test `SystemCleanupScannerTests.swift`

**Interfaces:**
- Produces: `enum SystemCleanup { static func scanners() -> [Scanner] }` (und setzt den Default von `SystemDataScanner.init(cleanupScanners:)` darauf; der Scanner führt sie mit `ctx` aus und legt das Ergebnis in `cleanupFindings`) mit vier Scannern + einem Hinweis-Scanner, IDs exakt Spec §5: `sysdata.temp`, `sysdata.libraryCaches`, `sysdata.libraryLogs`, `sysdata.unifiedLog`, `sysdata.macUpdate`. Alle: Kategorie `.systemData`, Risiko `.review` (Hinweis: `.hintOnly`), Summary = Spec-Erklärung **plus** Warnzeile aus Spec §5 als eigener Satz am Anfang, beginnend mit „Achtung: “.
  - `ScanContext` bekommt `public var userTempDir: URL` (Test-Helfer: `root/T`; Produktion: `SafetyGuard.userTempDirectory()`).
  - temp: Kinder von `ctx.userTempDir` (keine Symlinks), Änderungsdatum < `ctx.now − 3 Tage` (Ordner nur, wenn kein Eintrag darin jünger ist), `.delete`, Items je Kind.
  - libraryCaches: Kinder von `ctx.absolute("/Library/Caches")` außer den drei Spec-Ausnahmen, Symlinks übersprungen; `.admin` je Kind `AdminStep("/bin/rm", ["-rf", <echter absoluter Pfad>])` (echter Pfad, nicht rootPrefix – Muster TeXLiveScanner).
  - libraryLogs: Dateien unter `/Library/Logs/**` älter als 30 Tage; `.admin` je Datei `["/bin/rm", ["-f", pfad]]`.
  - unifiedLog: Größe von `/private/var/db/diagnostics` + `/private/var/db/uuidtext` (über `ctx.absolute`, „mindestens“ ok); `.admin([AdminStep("/usr/bin/log", ["erase", "--all"])])`, ein Item.
  - macUpdate: wenn AssetsV2 `com_apple_MobileAsset_MacSoftwareUpdate*` > 0 → `.hint(.openURL(Softwareupdate-URL aus TP1))`.
  - Previews: TP1-Konventionen (`rm -rf <quoted>` für delete, `sudo …` für admin).

- [ ] **Step 1: Failing tests**
```swift
@Test func tempOnlyOlderThan3Days() async throws { /* T/old 4 Tage, T/new 1 Tag, T/dir mit junger Datei → nur old */ }
@Test func tempSkipsSymlinks() async throws { /* T/evil → home/Documents → nicht in items */ }
@Test func libraryCachesAdminStepsUseRealPaths() async throws { /* root/Library/Caches/com.example → step ["-rf", "/Library/Caches/com.example"]; com.apple.iconservices.store ausgenommen */ }
@Test func logsOlderThan30Days() async throws { }
@Test func unifiedLogUsesLogErase() async throws { #expect(f.method == .admin([AdminStep(executable: "/usr/bin/log", arguments: ["erase", "--all"])])) }
@Test func allSystemFindingsNeverPreselected() async throws { /* jeder Fund: !isPreselected(isKept: false), summary beginnt mit "Achtung: " (außer Hinweis) */ }
```
- [ ] **Step 2–4:** Run → FAIL, implement, Run → PASS.
- [ ] **Step 5: Commit** `feat: Aufräum-Funde für Systemdaten`

---

### Task 6: AppModel und Bestätigung für Systemdaten

**Files:**
- Modify: `App/Model/AppModel.swift`, `App/Views/Cleanup/ConfirmSheet.swift`; Test `AppTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `SystemDataScanner`, `SystemDataReport` (Task 4), Systemfunde (Task 5).
- Produces:
  - `AppDependencies.measureSystemData: @Sendable (ScanContext, @escaping @Sendable (Int, Int) -> Void) async -> SystemDataReport` (live: `SystemDataScanner().scan`).
  - AppModel: `var systemData: SystemDataReport?`, `var isMeasuringSystemData: Bool`, `var systemDataProgress: Double`, `func measureSystemData() async` (Sperre wie `scan`: nicht während Scan/Entfernen), `func measureSystemDataIfNeeded() async` (nur einmal pro App-Start).
  - Systemfunde fließen in die bestehende Auswahl-/Plan-Logik: `findings(in: .systemData)` liefert `systemData?.cleanupFindings` gruppiert; `selectedSize/foundSize/makePlan/execute` funktionieren für `.systemData`; nach `execute` mit Systemfunden → `measureSystemData()` statt normalem Scan (und der normale Scan wie bisher, wenn der Plan andere Tabs betrifft – hier nie gemischt, da Plan je Tab).
  - `ConfirmSheet.requiresSystemAcknowledgement(_ plan: RemovalPlan) -> Bool` (`nonisolated static`, true wenn ein geplanter Fund `category == .systemData`); `allowsDefaultAction` liefert dann immer false; „Aufräumen“ ist ohne Häkchen gesperrt. Rote Warnkarte mit Titel „Du entfernst Systemdateien“, Liste der Warnzeilen der geplanten Systemfunde, Toggle „Ich habe verstanden, dass Systemdateien entfernt werden.“

- [ ] **Step 1: Failing tests**
```swift
@Test @MainActor func systemDataMeasuredOnceOnFirstOpen() async { /* measureSystemDataIfNeeded zweimal → measure-Fake einmal aufgerufen */ }
@Test @MainActor func systemFindingsNotPreselectedAndPlannable() async { /* nach Messung selection leer; toggle → makePlan(tab: .systemData) enthält adminSteps */ }
@Test func systemPlanRequiresAcknowledgementAndNoDefault() { /* requiresSystemAcknowledgement == true, allowsDefaultAction == false */ }
@Test @MainActor func executeSystemPlanRemeasures() async { }
```
- [ ] **Step 2–4:** Run `xcodebuild … test` → FAIL, implement, → PASS.
- [ ] **Step 5: Commit** `feat: AppModel für Systemdaten, Bestätigung mit Warnung`

---

### Task 7: Tab „Systemdaten“

**Files:**
- Create: `App/Views/SystemData/SystemDataTabView.swift`, `VolumeBarCard.swift`, `SnapshotCard.swift`, `SystemAreaCard.swift`; Modify `App/KlarschiffApp.swift` (Platzhalter für `.systemData` ersetzen), `App/Model/AppModel+Preview.swift` (Fake-Bericht), PlaceholderTab-Text für `.systemData` entfernen.

**Interfaces:**
- Consumes: AppModel-API aus Task 6; vorhandene Views `FindingCard`, `ConfirmSheet`, `ResultBanner`, `FullDiskAccessCard`, `SummaryCard`-Stil, `Theme`.
- Produces: `struct SystemDataTabView: View` – Aufbau, Texte und Pillen exakt Spec §4 (Erklärsatz, „Neu messen“, „Gemessen um HH:MM“, Pillen „Gehört zu macOS – behalten“ grau / „Aufräumbar“ grün / „Siehe Fund“ blau, „Im Tab Entwickler zeigen“/„Im Tab Speicher zeigen“ setzt `selectedTab`, „mindestens …“ bei `isLowerBound`, Schnappschuss-Karte nur wenn Schnappschüsse vorhanden oder `unaccounted > 5_000_000_000`). Aufräum-Karten über `FindingCard` innerhalb der grünen Bereiche; rote Warnzeile = erster Satz der Summary („Achtung: …“) rot hervorgehoben. `.task { await model.measureSystemDataIfNeeded() }`.

- [ ] **Step 1:** Views bauen; Preview mit Fake-Bericht (Franks Größenordnungen: Daten 248 GB, AssetsV2 33 GB, `/private/var/db` 7 GB, Simulator-Volume 18 GB).
- [ ] **Step 2: Build/Test** `xcodegen generate && xcodebuild … CODE_SIGNING_ALLOWED=NO test` → TEST SUCCEEDED, keine neuen Warnungen.
- [ ] **Step 3: Manuell** App nur mit `--dry-run` starten, ~60 s, kein Absturz.
- [ ] **Step 4: Commit** `feat: Tab Systemdaten`

---

### Task 8: Live-Messung, Abnahme, Doku

**Files:**
- Modify: `Tests/KlarschiffCoreTests/LiveScanTests.swift` (zweiter opt-in Test für `SystemDataScanner`), `docs/superpowers/plans/2026-10-29-abnahme.md` (Abschnitt „Teilprojekt 2“), `docs/UEBERGABE.md`, `README.md`.

- [ ] **Step 1:** Opt-in-Test (`KLARSCHIFF_LIVE_SCAN=1`, Ausgabe nach `KLARSCHIFF_LIVE_SCAN_OUT`) mit Produktions-Kontext; schreibt Volumes, Bereiche (Größe, „mindestens“), Summen, Anteil zugeordnet = `(userData + systemAreasTotal) / data.consumed`, Systemfunde. Keine Remover.
- [ ] **Step 2: Run** einmal auf Franks Mac; Ergebnis in die Abnahme (Kriterium Spec §1: ≥ 90 % zugeordnet, sonst Lücke benennen und – falls klein und im Umfang – Katalog ergänzen, mit Test).
- [ ] **Step 3:** UEBERGABE/README aktualisieren (Tab Systemdaten, Warnhinweise, offene Punkte für Frank: Admin-Aktionen einmal echt testen – eine Passwortabfrage).
- [ ] **Step 4:** Core + App-Tests grün. **Commit** `feat: Live-Messung Systemdaten, Abnahme TP2`
