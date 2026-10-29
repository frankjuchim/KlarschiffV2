# Klarschiff 2 – Teilprojekt 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Tab „Hintergrunddienste“: alle LaunchAgents/-Daemons (ohne Apple) und Anmeldeobjekte erklären, verwaiste erkennen und nach Bestätigung sauber entfernen; neue verwaiste Dienste im automatischen Check melden.

**Architecture:** Core `Services/` (LaunchItem, LaunchItemScanner, LoginItemReader, ServiceRemovalBuilder, ServiceBootout) + enge Erweiterung von SafetyGuard/AdminRemover; App: AppModel-State + Tab-View; Entfernen über die bestehende RemovalPlan/Runner-Kette.

**Tech Stack:** Swift 6, SwiftUI (macOS 26), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-30-klarschiff2-teilprojekt4-design.md` (verbindlich).

## Global Constraints

- Alle TP1–TP3-Constraints gelten (Swift 6 strict, Du-Form, kein Löschen ohne SafetyGuard, Werkzeuge nur über `CommandRunner`, Pfade aus `ScanContext`, Anzeigename „Klarschiff 2“, Trockenlauf überall).
- Nur **verwaiste**, nicht-Apple (`com.apple.*`), nicht-eigene (`de.frankjuchim.klarschiff2.*`) LaunchAgents/-Daemons sind entfernbar; Anmeldeobjekte nie.
- Lesende Werkzeuge: `/bin/launchctl print gui/<uid>/<label>` bzw. `system/<label>`, `/usr/bin/sfltool dumpbtm`. Schreibend nur `bootout`.
- Admin-Allow-Liste neu: `/bin/launchctl` exakt `["bootout", "system/<label>"]` (label `^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$`, nicht `com.apple.`); `/bin/rm -f` nur auf direkte `*.plist`-Kinder von `/Library/LaunchAgents` bzw. `/Library/LaunchDaemons`.
- Nie Franks echte Dienste verändern (nur lesen; Tests mit Fixtures).

## Review Focus

1. **Label mit Sonderzeichen/Unicode/Leerzeichen oder `com.apple.`-Varianten** (Groß-/Kleinschreibung) → nie in einem bootout/rm-Schritt. Test in Task 3.
2. **plist, deren Programm in einer App liegt, die nur auf einem anderen Volume/umbenannt ist** → konservativ nicht verwaist, wenn die Bundle-ID installiert ist. Test in Task 1.
3. **Defekte oder binäre plists, Symlinks im LaunchAgents-Ordner** → nicht abstürzen, Symlinks nie entfernen. Test in Task 1/3.
4. **`sfltool` hängt oder liefert unerwartetes Format** → Anmeldeobjekte leer + Hinweis, Rest läuft. Test in Task 2.
5. **Entfernen, während der Dienst neu startet (KeepAlive)** → bootout vor dem Löschen; scheitert bootout → plist bleibt, Fehler im Ergebnis. Test in Task 4.

---

### Task 1: LaunchItem und LaunchItemScanner

**Files:** Create `Services/LaunchItem.swift`, `Services/LaunchItemScanner.swift`; Fixtures in Tests; Test `LaunchItemScannerTests.swift`
**Interfaces (Produces):** `enum LaunchScope: String, Codable, Sendable { case user, allUsers, system, loginItem }` (Titel „Benutzer“/„Alle Benutzer“/„System“/„Anmeldeobjekt“); `enum StartKind { case atLogin, scheduled, onDemand }` (Texte „startet bei der Anmeldung“/„startet zeitgesteuert“/„startet bei Bedarf“); `struct LaunchItem: Sendable, Identifiable, Equatable` (Felder Spec §3); `struct LaunchItemScanner: Sendable { init(isInstalled: (@Sendable (String) -> URL?)? = nil /* nil → NSWorkspace.urlForApplication */); func scan(_ ctx: ScanContext, uid: uid_t = getuid()) async -> [LaunchItem] }`.
- [ ] Tests zuerst: Programm vorhanden/fehlt; App via Pfad in `*.app` installiert/fehlt; `BundleProgram` + `AssociatedBundleIdentifiers` (installiert → nicht verwaist); defekte plist → Eintrag mit Hinweis, nicht verwaist; `com.apple.*` übersprungen (case-insensitive); Symlink-plist übersprungen; eigener Agent `de.frankjuchim.klarschiff2.check.weekly` → `isOwnAgent`, nie verwaist; Startart-Ableitung; `isRunning` aus FakeCommandRunner (`launchctl print` Exit 0 mit `state = running` → true; „Could not find service“ → false); Daemons nutzen `system/<label>`.
- [ ] Implement, Run → PASS. Commit `feat: Hintergrunddienste erkennen`

### Task 2: LoginItemReader

**Files:** Create `Services/LoginItemReader.swift`; Fixture `sfltool-dumpbtm.txt` (aus `.superpowers/probes/btm.txt` auf Franks Mac ableiten, Namen/Pfade auf Beispielwerte anonymisieren, Struktur exakt behalten); Test `LoginItemReaderTests.swift`
**Interfaces:** `enum LoginItemReader { static func read(runner: CommandRunner, uid: uid_t = getuid()) async -> (items: [LaunchItem], failed: Bool); static func parse(_ text: String, uid: uid_t) -> [LaunchItem] }` – nur Abschnitt der UID, nur `Type: login item`/`Type: app`, Felder Name/Identifier/URL/Disposition (enabled → `isRunning` nein, aber `startKind .atLogin`), Scope `.loginItem`, nie verwaist.
- [ ] Tests: parst Fixture (Anzahl, Namen), ignoriert andere UIDs/Typen, kaputtes Format → leer, Timeout/Fehler → `failed`. Commit `feat: Anmeldeobjekte lesen`

### Task 3: Sicheres Entfernen (Core)

**Files:** Modify `Model/Category.swift` (`services`, Tab `.services`, Titel „Hintergrunddienste“, Symbol `gearshape.2`; `Category.forScannerID` „services“), `Safety/SafetyGuard.swift`, `Removal/AdminRemover.swift`; Create `Services/ServiceRemoval.swift`; Tests `ServiceRemovalTests.swift`, Erweiterungen in `SafetyGuardTests`/`RemoverTests`.
**Interfaces:** `enum ServiceRemoval { static func finding(_ items: [LaunchItem], uid: uid_t = getuid()) -> Finding? /* nur entfernbare; Benutzer → .trash-Items; Alle Benutzer/System → .admin mit Schritten [bootout system/<label> nur für .system] + rm -f <plist> */; static func bootout(_ items: [LaunchItem], runner: CommandRunner, uid: uid_t, dryRun: Bool) async -> [ItemResult] /* gui/<uid>/<label> für .user und .allUsers, nur wenn isRunning */ }`. Admin-Finding und Trash-Finding getrennt (zwei Findings, da eine Methode pro Finding) – Rückgabe `[Finding]`.
- [ ] Tests: nur verwaiste/nicht-Apple/nicht-eigene; Label-Regex (Leerzeichen, `;`, Unicode, `COM.APPLE.x` → ausgeschlossen); Admin-Allow-Liste erlaubt exakt die neuen Formen und verweigert `bootout gui/…`, `bootout system/com.apple.x`, `rm -rf`, Unterordner, Nicht-plist; SafetyGuard erlaubt `/Library/LaunchDaemons/x.plist`, verweigert den Ordner selbst, Unterordner, Symlink nach außen. Commit `feat: verwaiste Dienste sicher entfernen`

### Task 4: AppModel und automatischer Check

**Files:** Modify `AutoCheck/CheckSnapshot.swift` (`orphanedServiceLabels: [String]`, decodeIfPresent), `AutoCheck/GrowthWatcher.swift` (`.orphanedServices(labels:)` nur neue Labels; Reihenfolge growth → orphanedServices → lowSpace → cleanable), `AutoCheck/CheckRunner.swift` (injizierbarer `orphanedServices: @Sendable (ScanContext) async -> [String]`, Standard leer), `AutoCheck/CheckNotificationText.swift` (Text „2 neue verwaiste Hintergrunddienste“, Tab `.services`), App `AppModel.swift` + `BackgroundCheck.swift` (Produktion: `LaunchItemScanner` → verwaiste Labels).
**AppModel:** `var services: [LaunchItem]`, `var loginItemsFailed: Bool`, `var isLoadingServices`, `func loadServicesIfNeeded()`, `func reloadServices()`, Auswahl/Plan für `.services` über bestehende Mechanik (Findings aus `ServiceRemoval.finding` für ausgewählte), `func removeServices(_ ids: Set<String>)` → bootout → Plan ausführen (Trockenlauf!) → neu laden. Bootout-Fehler → plist dieses Dienstes nicht entfernen.
- [ ] Tests (Core + App): Alert nur bei neuen Labels; altes Verlauf-JSON dekodiert; Entfernen-Reihenfolge; Trockenlauf ohne Aufrufe; fehlgeschlagener bootout behält plist. Commit `feat: Hintergrunddienste im Modell und im Check`

### Task 5: Tab „Hintergrunddienste“

**Files:** Create `App/Views/Services/ServicesTabView.swift`, `ServiceRow.swift`, `OrphanedServicesSection.swift`; Modify `App/KlarschiffApp.swift` (Platzhalter ersetzen), `App/Views/Cleanup/ConfirmSheet.swift` (Kategorie `services` mit Admin → rote Warnkarte + Häkchen wie `systemData`), Previews.
- [ ] Texte exakt Spec §4; Laden beim ersten Öffnen (unstrukturierter Task), gesperrt bei busy; Lupe; Hinweiskarte Anmeldeobjekte (`SMAppService.openSystemSettingsLoginItems()`). AppTests für Bestätigungsregel und Gruppierung. Build/Test grün, Start nur mit `--dry-run`. Commit `feat: Tab Hintergrunddienste`

### Task 6: Abnahme und Doku

- [ ] Opt-in-Livetest: Scanner + LoginItemReader lesend auf Franks Mac → Markdown (Anzahl je Bereich, verwaiste Labels, laufende). Abnahme-Abschnitt „Teilprojekt 4“, UEBERGABE, README. Offene Punkte für Frank: verwaiste Dienste prüfen und echt entfernen (Admin → eine Passwortabfrage). Commit `docs: Abnahme TP4`
