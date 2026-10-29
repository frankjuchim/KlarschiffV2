# Klarschiff 2 – Teilprojekt 3: Automatischer Check, Wachstumswächter, Migration

**Stand:** 29.10.2026 · **Grundlage:** `docs/Briefing.md` §2 („Automatischer Check“), §4.2 („Wachstumswächter“), §2 (alte Agents); Specs TP1/TP2
**Status:** Design im Brainstorming mit Frank abgestimmt und freigegeben (29.10.2026).

## 1. Ziel und Erfolgskriterium

Klarschiff 2 prüft auf Wunsch wöchentlich oder monatlich im Hintergrund, **meldet nur** (löscht nie), schreibt einen Verlauf und warnt, wenn etwas stark wächst. Die beiden alten Automatiken (`com.frankjuchim.cleanup`, `de.bodendiek.klarschiff.check`) werden erkannt, erklärt und nach Bestätigung sauber entfernt.

**Abnahme:** Auf Franks Mac (a) lässt sich der Check auf Wöchentlich stellen, erscheint als „Klarschiff 2“ unter Anmeldeobjekte und läuft per „Jetzt prüfen“ durch (Verlaufseintrag + ggf. Mitteilung, Klick öffnet die App); (b) die Migrationskarte zeigt beide alten Agents, „Alte Automatik entfernen“ stoppt sie und legt die Dateien in den Papierkorb; danach listet `launchctl list` beide nicht mehr.

## 2. Entscheidungen (Brainstorming 29.10.2026)

| Frage | Entscheidung |
|---|---|
| Hintergrundausführung | **LaunchAgent über `SMAppService`**, Ergebnis per **Mitteilung** (`UserNotifications`); Klick öffnet die App im passenden Tab. |
| Menüleisten-Icon | **Nein.** |
| Schwellen | Wachstum je ID seit letztem Check **≥ 5 GB** oder (**≥ 2 GB und > Verdopplung**); Aufräumbares gesamt **≥ 1 GB**; knapper Speicher **< 10 % oder < 20 GB frei**; neue verwaiste Dienste erst mit TP4. **Höchstens eine Mitteilung pro Check.** |
| Migration | Karte „Alte Aufräum-Automatik gefunden“; „Alte Automatik entfernen“ → `launchctl bootout`, plists in den Papierkorb; optional (Häkchen, standardmäßig an) `~/cleanup.sh`, `~/cleanup.log`, `~/cleanup_error.log`, leeres `/Applications/Klarschiff.app` in den Papierkorb. |
| Rhythmus | Aus / Wöchentlich (sonntags 10:00) / Monatlich (Monatserster 10:00), „Jetzt prüfen“. |

## 3. Check-Kern (KlarschiffCore, Ordner `AutoCheck/`)

- **`CheckSnapshot`** (Codable): `date`, `cleanableTotal: Int64` (Summe der Funde in Speicher+Entwickler, ohne Hinweise, ohne Behaltene), `freeBytes`, `totalBytes`, `sizes: [String: Int64]` (Fund-IDs `scannerID/key` aus dem Scan **plus** Wurzel-Systembereiche `systemdata.<areaID>` aus einer schnellen Messung ohne Home und ohne Aufräum-Scanner), `alerts: [CheckAlert]`.
- **`CheckAlert`** (Codable, Equatable): `.growth(id: String, title: String, from: Int64, to: Int64)`, `.cleanable(total: Int64)`, `.lowSpace(free: Int64, total: Int64)`.
- **`GrowthWatcher`** (rein, testbar): `alerts(previous: CheckSnapshot?, current: …) -> [CheckAlert]` mit den Schwellen aus §2 (Wachstum nur, wenn die ID im vorherigen Snapshot existiert; Titel aus dem aktuellen Fund bzw. Bereich).
- **`CheckHistory`** (actor): JSON in `~/Library/Application Support/Klarschiff2/history.json`, neueste zuerst, maximal 52 Einträge, atomar geschrieben, defekte/fehlende Datei → leer (Muster `KeepList`).
- **`CheckRunner`**: `run(context:engine:keepList:systemData:) async -> CheckSnapshot` – führt den normalen Scan (`includeSlowChecks: false`) aus, misst die Wurzel-Systembereiche, liest `DiskInfo`, berechnet Alerts gegen den letzten Verlaufseintrag, hängt den Snapshot an den Verlauf. **Baut keinen Remover.**
- **`CheckNotificationText`** (rein): erzeugt Titel/Text der einen Mitteilung, z. B. Titel „Klarschiff 2“, Text „Instruments-Caches +38 GB seit dem letzten Check · 52 GB aufräumbar“; Priorität: Wachstum > knapper Speicher > Aufräumbares; ohne Alerts → keine Mitteilung. Ziel-Tab: Tab des gewachsenen Funds (Systembereiche → `.systemData`), sonst `.storage`.

## 4. Hintergrundausführung (App)

- Startargument **`--check`**: Die App startet ohne Fenster (`NSApplication.ActivationPolicy.prohibited` bzw. kein `WindowGroup`-Fenster), führt `CheckRunner` aus, sendet ggf. die Mitteilung, beendet sich. Läuft die App bereits normal, nutzt „Jetzt prüfen“ denselben Kern im Prozess.
- **LaunchAgent-plists im Bundle:** `Contents/Library/LaunchAgents/de.frankjuchim.klarschiff2.check.weekly.plist` (`StartCalendarInterval {Weekday 0, Hour 10, Minute 0}`) und `…check.monthly.plist` (`{Day 1, Hour 10, Minute 0}`), beide `BundleProgram` = `Contents/MacOS/Klarschiff 2`, `ProgramArguments` = `["Klarschiff 2", "--check"]`, `ProcessType` Background, `LowPriorityIO` true, `Nice` 10.
- **`CheckScheduler`** (App, hinter Protokoll für Tests): `setSchedule(.off | .weekly | .monthly)` meldet die jeweils andere plist über `SMAppService.agent(plistName:)` ab und die gewählte an; Status (`.enabled`, `.requiresApproval`, `.notRegistered`, `.notFound`) wird angezeigt; bei `.requiresApproval` Hinweis + Knopf `SMAppService.openSystemSettingsLoginItems()`. Einstellung in UserDefaults `checkSchedule`.
- **Mitteilungen:** Erlaubnis beim ersten Einschalten des Checks (`UNUserNotificationCenter.requestAuthorization`); Klick (`userInfo["tab"]`) öffnet/aktiviert die App und setzt `selectedTab`. Abgelehnt → Hinweis mit Knopf zu den Mitteilungs-Einstellungen.

## 5. Oberfläche

- **Einstellungen (⌘,)**, Abschnitt „Automatischer Check“: Picker Aus / Wöchentlich (sonntags 10 Uhr) / Monatlich (Monatserster 10 Uhr); Status der Anmeldung (bei Bedarf Hinweis „In den Systemeinstellungen erlauben“); Knopf **„Jetzt prüfen“**; Statuszeile **„Letzter Check vor X Minuten: <Kurzfassung>“** (relative Zeit deutsch, z. B. „vor 3 Tagen“); Verlauf als Liste (Datum, aufräumbar, frei, Auffälligkeiten als kurze Texte). Erklärsatz: „Der Check meldet sich nur, wenn es sich lohnt – und löscht nie etwas.“
- **Zusammenfassungskarte im Tab „Speicher“**: zusätzliche Zeile mit derselben Statuszeile (nur wenn ein Check existiert).

## 6. Migration der alten Automatik

- **`LegacyAutomation`** (Core, testbar über `ScanContext`-Pfade): erkennt `~/Library/LaunchAgents/com.frankjuchim.cleanup.plist`, `~/Library/LaunchAgents/de.bodendiek.klarschiff.check.plist`, `~/cleanup.sh`, `~/cleanup.log`, `~/cleanup_error.log`, `/Applications/Klarschiff.app` (nur wenn leer bzw. ohne ausführbares `Contents/MacOS/Klarschiff`), und ob die Labels geladen sind (`launchctl print gui/<uid>/<label>` Exit 0).
- **Karte** oben im Tab „Speicher“, solange etwas davon existiert: Titel „Alte Aufräum-Automatik gefunden“; Erklärung je Teil, ausdrücklich: „Das Skript `cleanup.sh` leert jeden Monatsersten automatisch deine Caches – das macht Klarschiff 2 bewusst nie ohne dich.“ und „Der alte Klarschiff-Check zeigt auf eine App, die es nicht mehr gibt.“; Häkchen „Skript, Protokolle und die leere alte App ebenfalls in den Papierkorb legen“ (an); Knopf **„Alte Automatik entfernen“** mit Bestätigung.
- **Ablauf:** `launchctl bootout gui/<uid>/<label>` je geladenem Label über `CommandRunner` (Fehler „nicht geladen“ ist kein Fehler), dann Dateien über `TrashRemover` (SafetyGuard prüft wie immer). Trockenlauf: nur melden. Ergebnis im bekannten Ergebnis-Banner.
- **SafetyGuard:** keine Erweiterung nötig – die Pfade liegen unter Home (nicht Home/Library selbst) bzw. sind `/Applications/<name>.app`. Die Migration bietet ausschließlich diese sechs festen Pfade an.

## 7. Sicherheit (verbindlich)

- Der Check löscht nie; `CheckRunner` und der `--check`-Pfad konstruieren keine Remover (Test).
- `launchctl` nur mit `bootout`/`print` und nur für die zwei festen Labels in `gui/<uid>`.
- Migration nur nach Bestätigung, Dateien nur in den Papierkorb, Trockenlauf respektiert.
- Kein Admin-Recht in TP3.

## 8. Tests

`GrowthWatcher` (alle Schwellen inkl. Grenzwerte, neue IDs ohne Vorgänger), `CheckHistory` (Persistenz, 52er-Grenze, defekte Datei), `CheckRunner` mit Fake-Engine (Snapshot-Felder, keine Remover, Verlauf angehängt), `CheckNotificationText` (Priorität, Ziel-Tab, kein Alert → nil), `LegacyAutomation` (Erkennung in Fixture-Home, bootout-Befehle exakt, Trockenlauf), App: Scheduler-Logik mit Fake-Service, Statuszeilen-Text, Klick-Ziel-Tab.

## 9. Nicht Teil von TP3

Verwaiste Hintergrunddienste (TP4), Menüleisten-Icon, automatische Löschung jeglicher Art.
