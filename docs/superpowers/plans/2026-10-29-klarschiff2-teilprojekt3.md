# Klarschiff 2 – Teilprojekt 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatischer Hintergrund-Check (wöchentlich/monatlich, nur melden) mit Verlauf, Wachstumswächter und Mitteilung, plus Migration der zwei alten Agents.

**Architecture:** Reiner, testbarer Kern in `Packages/KlarschiffCore/Sources/KlarschiffCore/AutoCheck/` (Snapshot, GrowthWatcher, CheckHistory, CheckRunner, CheckNotificationText, LegacyAutomation). Die App startet mit `--check` fensterlos, wird über `SMAppService.agent` per LaunchAgent-plist im Bundle geplant und meldet über `UserNotifications`. UI: Einstellungen (⌘,), Statuszeile, Migrationskarte.

**Tech Stack:** Swift 6, SwiftUI (macOS 26), ServiceManagement, UserNotifications, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-29-klarschiff2-teilprojekt3-design.md` (verbindlich; Schwellen, Texte, Pfade, Zeitpläne stehen dort).

## Global Constraints

- Alle TP1/TP2-Constraints gelten (Swift 6 strict, Du-Form, `ByteFormat`, kein Löschen ohne SafetyGuard, Werkzeuge nur über `CommandRunner`, Pfade aus `ScanContext`, Anzeigename „Klarschiff 2“).
- **Der Check löscht nie** – kein Remover im Check-Pfad.
- Schwellen exakt: Wachstum ≥ 5_000_000_000 oder (≥ 2_000_000_000 und neu > 2 × alt); aufräumbar ≥ 1_000_000_000; frei < 10 % oder < 20_000_000_000. Höchstens eine Mitteilung pro Check.
- Zeitpläne exakt: wöchentlich sonntags 10:00, monatlich Monatserster 10:00.
- Verlauf: `~/Library/Application Support/Klarschiff2/history.json`, max. 52 Einträge.
- `launchctl` nur `bootout`/`print` für exakt `com.frankjuchim.cleanup` und `de.bodendiek.klarschiff.check` in `gui/<uid>`.
- Kein Admin in TP3. App nie ohne `--dry-run` starten (Ausnahme: `--check`-Lauf ist löschfrei und darf getestet werden).

## Review Focus

1. **Erster Check ohne Verlauf** → keine Wachstums-Meldung, nur ggf. Aufräumbar/knapper Speicher. Test in Task 1.
2. **Verlaufsdatei defekt oder von älterer Version** → leer starten, nicht abstürzen, nicht überschreiben, bevor neu geschrieben wird. Test in Task 1.
3. **`--check` während die App offen ist** (zwei Prozesse schreiben den Verlauf) → atomares Schreiben, letzter gewinnt, keine kaputte Datei. Test in Task 1 (paralleles Schreiben).
4. **Alte Agents nur teilweise vorhanden / nicht geladen** → Karte zeigt nur Vorhandenes; `bootout` eines nicht geladenen Labels gilt nicht als Fehler. Test in Task 3.
5. **Mitteilungen abgelehnt / Anmeldeobjekt nicht erlaubt** → Check läuft trotzdem, Verlauf wird geschrieben; UI zeigt Hinweis. Test in Task 4.

---

### Task 1: Snapshot, Wachstumswächter, Verlauf

**Files:** Create `AutoCheck/CheckSnapshot.swift`, `AutoCheck/GrowthWatcher.swift`, `AutoCheck/CheckHistory.swift`; Test `GrowthWatcherTests.swift`, `CheckHistoryTests.swift`

**Interfaces:**
- Produces:
  - `struct CheckSnapshot: Codable, Sendable, Equatable { var date: Date; var cleanableTotal: Int64; var freeBytes: Int64; var totalBytes: Int64; var sizes: [String: Int64]; var titles: [String: String]; var alerts: [CheckAlert] }`
  - `enum CheckAlert: Codable, Sendable, Equatable { case growth(id: String, title: String, from: Int64, to: Int64), cleanable(total: Int64), lowSpace(free: Int64, total: Int64) }`
  - `enum GrowthWatcher { static func alerts(previous: CheckSnapshot?, current: CheckSnapshot) -> [CheckAlert] }` – Reihenfolge: growth (absteigend nach Zuwachs), lowSpace, cleanable.
  - `actor CheckHistory { init(fileURL: URL); static func defaultFileURL(home: URL) -> URL; func all() -> [CheckSnapshot] /* neueste zuerst */; func latest() -> CheckSnapshot?; func append(_ s: CheckSnapshot) throws /* max 52, atomar; liest vor dem Schreiben die Datei neu */ }`

- [ ] **Step 1: Failing tests** – `firstCheckNoGrowth`, `growthAbove5GB`, `growthAbove2GBAndDoubled` (2,1 GB → 4,3 GB meldet; 3 GB → 5,5 GB meldet nicht), `exactThresholds` (5_000_000_000 meldet, 4_999_999_999 nicht), `newIDNoGrowth`, `cleanableAtLeast1GB`, `lowSpaceByPercentOrAbsolute` (9 % frei, 19 GB frei), `historyPersistsAndCaps52`, `corruptHistoryStartsEmpty`, `concurrentAppendsKeepValidFile` (zwei CheckHistory-Instanzen auf derselben Datei, je 20 Appends parallel → Datei dekodierbar, ≤ 52).
- [ ] **Step 2–4:** Run `swift test --package-path Packages/KlarschiffCore` → FAIL, implement, → PASS.
- [ ] **Step 5: Commit** `feat: Check-Verlauf und Wachstumswächter`

---

### Task 2: CheckRunner und Mitteilungstext

**Files:** Create `AutoCheck/CheckRunner.swift`, `AutoCheck/CheckNotificationText.swift`; Test `CheckRunnerTests.swift`

**Interfaces:**
- Consumes: `ScanEngine`, `ScanContext`, `KeepList`, `SystemDataScanner`, `DiskInfo`/`DiskSpace`, Task 1.
- Produces:
  - `struct CheckRunner: Sendable { init(engine: ScanEngine, keepList: KeepList, history: CheckHistory, measureSystemRoots: @Sendable (ScanContext) async -> [String: (title: String, size: Int64)], diskSpace: @Sendable () throws -> DiskSpace); func run(_ ctx: ScanContext) async -> CheckSnapshot }` – `cleanableTotal` = Summe `size ?? 0` der Funde (Tabs Speicher/Entwickler, ohne `.hintOnly`, ohne Behaltene); `sizes`/`titles` = Fund-IDs `"\(scannerID)/\(key)"` mit Größe + `systemdata.<rootID>`; Alerts via `GrowthWatcher` gegen `history.latest()`; Snapshot an Verlauf anhängen (Fehler beim Schreiben → Snapshot trotzdem zurück). Standard für `measureSystemRoots` in der App: `SystemDataScanner(cleanupScanners: [])` mit einem Kontext, der Home nicht misst – füge dafür `SystemDataScanner.init(..., measureUserData: Bool = true)` hinzu (false → userData 0, kein Hinweis).
  - `struct CheckNotification: Sendable, Equatable { var title: String; var body: String; var tab: AppTab }`; `enum CheckNotificationText { static func make(_ s: CheckSnapshot) -> CheckNotification? }` – Texte exakt Spec §3 (Beispiel „Instruments-Caches +38 GB seit dem letzten Check · 52 GB aufräumbar“; knapp: „Nur noch 18 GB frei“; nur aufräumbar: „52 GB aufräumbar“); Ziel-Tab: Kategorie-Tab des gewachsenen Funds (`Catalog`-/Kategorie-Zuordnung über scannerID-Präfix wie `AppModel.category(forScannerID:)` → in Core verschieben oder dort duplizieren als `Category.forScannerID(_:)`), `systemdata.*` → `.systemData`, sonst `.storage`.

- [ ] **Step 1: Failing tests** – `runBuildsSnapshotWithoutRemovers` (Fake-Scanner in echter `ScanEngine`; prüft Felder; der Test-Typ kennt keine Remover – zusätzlich `CheckRunner` hat keine Remover-Abhängigkeit), `keptAndHintsExcluded`, `alertsAgainstPreviousHistory`, `historyWriteFailureStillReturnsSnapshot`, `notificationPriorityAndTab`, `noAlertsNoNotification`, `measureUserDataFalseSkipsHome`.
- [ ] **Step 2–4:** Run → FAIL, implement, → PASS.
- [ ] **Step 5: Commit** `feat: Hintergrund-Check-Kern und Mitteilungstext`

---

### Task 3: Erkennung und Entfernung der alten Automatik

**Files:** Create `AutoCheck/LegacyAutomation.swift`; Test `LegacyAutomationTests.swift`

**Interfaces:**
- Produces:
  - `struct LegacyItem: Sendable, Equatable, Identifiable { enum Kind: Sendable { case agent(label: String), script, log, emptyApp }; var id: String; var kind: Kind; var url: URL; var title: String; var explanation: String; var isLoaded: Bool }`
  - `enum LegacyAutomation { static let labels = ["com.frankjuchim.cleanup", "de.bodendiek.klarschiff.check"]; static func detect(_ ctx: ScanContext, uid: uid_t = getuid()) async -> [LegacyItem]; static func removalFinding(_ items: [LegacyItem], includeExtras: Bool) -> Finding /* Kategorie .system, Methode .trash, Items = plists (+ Skript/Logs/App wenn includeExtras) */; static func bootout(_ items: [LegacyItem], runner: CommandRunner, uid: uid_t = getuid(), dryRun: Bool) async -> [ItemResult] }`
  - Erkennung exakt Spec §6 (Pfade über `ctx.homePath` / `ctx.absolute`; „leere App“ = `/Applications/Klarschiff.app` ohne `Contents/MacOS/Klarschiff`); `isLoaded` über `/bin/launchctl print gui/<uid>/<label>` Exit 0; `bootout` = `/bin/launchctl bootout gui/<uid>/<label>` nur für geladene Agents; Exit ≠ 0 mit „Could not find service“/„No such process“ im stderr → `.removed(freed: nil)` (gilt als erledigt), sonst `.failed(gekürzt)`; `dryRun` → `.skipped("Trockenlauf")` ohne Aufruf. Texte deutsch gemäß Spec §6.
- [ ] **Step 1: Failing tests** – `detectsAllSixInFixture`, `detectsPartial` (nur Skript-Agent + Skript), `appWithExecutableIsNotLegacy`, `loadedStateFromLaunchctlPrint`, `bootoutOnlyLoadedLabelsExactArgs`, `bootoutNotLoadedCountsAsDone`, `bootoutDryRunNoCalls`, `removalFindingExtrasToggle`.
- [ ] **Step 2–4:** Run → FAIL, implement, → PASS.
- [ ] **Step 5: Commit** `feat: alte Aufräum-Automatik erkennen und entfernen`

---

### Task 4: Hintergrundausführung, Planung und Mitteilungen (App)

**Files:** Create `App/AutoCheck/CheckScheduler.swift`, `App/AutoCheck/BackgroundCheck.swift`, `App/AutoCheck/CheckNotifier.swift`, `App/LaunchAgents/de.frankjuchim.klarschiff2.check.weekly.plist`, `…check.monthly.plist`; Modify `project.yml` (Copy-Files-Phase nach `Contents/Library/LaunchAgents`), `App/KlarschiffApp.swift` (`--check`-Pfad), `App/Model/AppModel.swift`; Test `AppTests/AutoCheckTests.swift`

**Interfaces:**
- Consumes: Task 1–2.
- Produces:
  - `enum CheckSchedule: String, CaseIterable, Sendable { case off, weekly, monthly }` (UserDefaults `checkSchedule`)
  - `protocol AgentService: Sendable { func register(_ plist: String) throws; func unregister(_ plist: String) async throws; func status(_ plist: String) -> AgentStatus }`, `enum AgentStatus: Sendable { case enabled, requiresApproval, notRegistered, notFound }`; Produktion über `SMAppService.agent(plistName:)`.
  - `struct CheckScheduler { init(service: AgentService); func apply(_ schedule: CheckSchedule) async throws /* andere plist abmelden, gewählte anmelden; off → beide ab */; func status(for: CheckSchedule) -> AgentStatus }` – plist-Namen exakt Spec §4.
  - `protocol Notifier: Sendable { func requestAuthorization() async -> Bool; func send(_ n: CheckNotification) async }`; Produktion `UNUserNotificationCenter` (userInfo `"tab"`), Delegate setzt beim Klick `AppModel.selectedTab`.
  - `BackgroundCheck.run(dependencies:) async` – baut Kontext + `CheckRunner`, führt aus, sendet `CheckNotificationText.make` falls nicht nil; im `--check`-Modus keine Fenster (prüfe `CommandLine.arguments.contains("--check")` in `KlarschiffApp`: kein `WindowGroup`-Inhalt/`ActivationPolicy.prohibited`, Lauf, dann `exit(0)`).
  - AppModel: `var checkSchedule: CheckSchedule`, `var lastCheck: CheckSnapshot?`, `var checkHistory: [CheckSnapshot]`, `var notificationsDenied: Bool`, `var agentStatus: AgentStatus`, `func setCheckSchedule(_:) async`, `func runCheckNow() async` (nicht während Scan/Entfernen/Messen), `func loadCheckHistory() async`.
- [ ] **Step 1: Failing tests** (Fakes für AgentService/Notifier/Runner) – `weeklyRegistersWeeklyUnregistersMonthly`, `offUnregistersBoth`, `requiresApprovalSurfaced`, `runCheckNowAppendsHistoryAndNotifies`, `deniedNotificationsStillWritesHistory`, `notificationClickSetsTab`.
- [ ] **Step 2–4:** `xcodegen generate && xcodebuild … CODE_SIGNING_ALLOWED=NO test` → FAIL, implement, → PASS. Prüfe, dass beide plists im gebauten Bundle unter `Contents/Library/LaunchAgents/` liegen (`ls` im Build-Ordner).
- [ ] **Step 5: Manuell** Einmal `"Klarschiff 2.app/Contents/MacOS/Klarschiff 2" --check` starten (löscht nichts) → beendet sich, Verlauf enthält einen Eintrag.
- [ ] **Step 6: Commit** `feat: Hintergrund-Check per LaunchAgent und Mitteilung`

---

### Task 5: Oberfläche – Einstellungen, Statuszeile, Migrationskarte

**Files:** Create `App/Views/Settings/SettingsView.swift`, `App/Views/Settings/CheckHistoryList.swift`, `App/Views/Cleanup/LegacyAutomationCard.swift`; Modify `App/KlarschiffApp.swift` (`Settings { SettingsView() }`), `App/Views/Cleanup/SummaryCard.swift`, `App/Views/Cleanup/CleanupTabView.swift`, `App/Model/AppModel.swift` (Legacy-Erkennung + Entfernen), Previews.

**Interfaces:**
- Consumes: Task 3–4.
- Produces: Texte exakt Spec §5/§6 („Automatischer Check“, Picker-Labels „Aus“ / „Wöchentlich (sonntags 10 Uhr)“ / „Monatlich (Monatserster 10 Uhr)“, „Jetzt prüfen“, „Letzter Check vor X: …“ mit `RelativeDateTimeFormatter` de_DE, Erklärsatz, Hinweis „In den Systemeinstellungen erlauben“ + Knopf, Mitteilungs-Hinweis + Knopf; Migrationskarte mit Titel, Erklärungen, Häkchen, Knopf „Alte Automatik entfernen“ + Bestätigungsdialog). AppModel: `var legacyItems: [LegacyItem]`, `func detectLegacy() async` (beim Start und nach Scan), `func removeLegacy(includeExtras: Bool) async` (bootout, dann Papierkorb über den vorhandenen Removal-Weg mit `removalFinding`; Trockenlauf respektiert; Ergebnis-Banner; danach neu erkennen). Statuszeilen-Helfer `nonisolated static func statusLine(_ s: CheckSnapshot?, now: Date) -> String?` getestet.
- [ ] **Step 1: Failing tests** (AppTests) – `statusLineTexts`, `removeLegacyBootoutThenTrashInOrder`, `removeLegacyDryRunNoCalls`, `legacyCardHiddenWhenNothingFound`.
- [ ] **Step 2–4:** Build/Test → FAIL, implement, → PASS. App nur mit `--dry-run` ~60 s starten.
- [ ] **Step 5: Commit** `feat: Einstellungen für den Check, Statuszeile und Migrationskarte`

---

### Task 6: Abnahme und Doku

**Files:** Modify `docs/superpowers/plans/2026-10-29-abnahme.md` (Abschnitt „Teilprojekt 3“), `docs/UEBERGABE.md`, `README.md`.

- [ ] **Step 1:** Lese-Prüfung auf Franks Mac: `LegacyAutomation.detect` über einen opt-in Livetest (`KLARSCHIFF_LIVE_SCAN=1`) → beide Agents + Dateien erkannt (Ergebnis in die Abnahme). Einmal `--check` laufen lassen (löscht nichts) → Verlaufseintrag, Werte in die Abnahme.
- [ ] **Step 2:** Offene Punkte für Frank: Check auf Wöchentlich stellen und in Anmeldeobjekten erlauben; Mitteilung zulassen; „Jetzt prüfen“; „Alte Automatik entfernen“ echt ausführen und mit `launchctl list | grep -E "frankjuchim|klarschiff"` prüfen.
- [ ] **Step 3:** UEBERGABE/README aktualisieren. Core + App-Tests grün. **Commit** `docs: Abnahme TP3`
