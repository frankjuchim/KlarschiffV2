# Übergabe – Stand 29.10.2026

## Erledigt (Cloud-Sitzung)
- Briefing + Screenshots abgelegt.
- Brainstorming abgeschlossen; Entscheidungen in Spec Abschnitt 2:
  Direkt-Download ohne Sandbox · Bundle-ID `de.frankjuchim.klarschiff2` · Admin erst per Passwortabfrage pro Lauf, später Helper · macOS 26 · fünf Tabs · fünf Teilprojekte.
- Spec Teilprojekt 1 und Umsetzungsplan (18 Tasks) geschrieben.

## Freigaben (29.10.2026)
- Spec und Plan von Frank abgenommen, inkl. „Großes wird direkt gelöscht“.
- Ausführung: **Subagent-driven** (superpowers:subagent-driven-development).
- Ziel später: Download auf frankjuchim.de (Developer ID + Notarisierung, Task 18); Auto-Updates (Sparkle) als eigenes Teilprojekt danach.

## Voraussetzungen auf dem Mac
- Xcode (passend zu macOS 26/27) und `brew install xcodegen`
- `Config/Local.xcconfig` mit `DEVELOPMENT_TEAM = <Team-ID>` (erst für Signatur/Release nötig, Task 18)

## Stand Teilprojekt 1 (29.10.2026, Mac-Sitzung)
- **Alle 18 Tasks umgesetzt** (subagent-driven, je Task Review + Fix-Runden), plus Abschlussreview mit einer Fix-Welle. Branch gepusht.
- Tests: Core 219 grün (`swift test --package-path Packages/KlarschiffCore`), App-Tests grün (`xcodebuild … CODE_SIGNING_ALLOWED=NO test`).
- Lese-Scan auf Franks Mac: 85 Funde, 0 Scan-Fehler → `docs/superpowers/plans/2026-10-29-abnahme.md`.
- Wichtige Abweichungen vom Plan (Begründung in den Commits): Admin-Schritte nur per Allow-List (`/bin/rm` mit geprüften Operanden, `tmutil deletelocalsnapshots <Datum>`), Admin-Skript über `osascript` statt `NSAppleScript`, Werkzeug-Funde sind „ganz oder gar nicht“, neue Scanner-Phase `lateCollector`, `Finding.watchedApps`/`FindingItem.watchedApp` für die App-läuft-Prüfung direkt vor dem Entfernen.
- Follow-up: Anzeigename jetzt **„Klarschiff 2“** (Modul/Target/Schema heißen weiter `Klarschiff`). Start aus Xcode ist **immer Trockenlauf** (`--dry-run` im Schema); zusätzlich Schalter im Menü „Entwickler → Trockenlauf“, Kopfzeile zeigt „Trockenlauf aktiv“. Echter Lauf = gebaute App aus dem Finder starten.
- Follow-up: Xcode-Archive sind jetzt **ein** Fund (`xcode.archives/all`, je Archiv ein Eintrag). Frühere „Immer behalten“-Einträge für einzelne Archive greifen nicht mehr (verwaist, harmlos) – einzelne Archive behältst du durch Abwählen.

### Offen für Frank (nicht automatisierbar)
- [ ] UI in `--dry-run` ansehen (Screenshots/Klicks waren der Sitzung nicht erlaubt).
- [ ] Schritt 5: echter kleiner Lauf (Homebrew-Aufräumen + ein Papierkorb-Fund, aus dem Finder gestartet; optional ein Admin-Fund → genau eine Passwortabfrage).
- [ ] TCC-Abfragen bei Docker/UTM/Telegram/OrbStack; Telegram-Muster mit Vollzugriff verifizieren.
- [ ] `scripts/release.sh` + Notarisierung mit echtem Team einmal durchlaufen lassen.
- [x] CI auf GitHub (`macos-26`) grün (29.10.2026).

## Stand Teilprojekt 2 – Systemdaten (29.10.2026)
- Tab „Systemdaten“ (Messung des Data-Volumes, Bereichsbaum, „Deine Daten“, nicht zugeordnet, Systemfunde mit Warnung/Bestätigung) umgesetzt; Opt-in-Livetest `liveSystemData` (`KLARSCHIFF_LIVE_SCAN=1`).
- Live-Messung auf Franks Mac: **75,0 % zugeordnet** (Ziel ≥ 90 %; Verlauf 37,6 % → 52,7 % → 75,0 %). Home wird je Unterordner (max. 8 parallel) gemessen, bei Zeitüberschreitung eine Ebene tiefer (inkl. direkter Dateien); Home ≈ 93,4 GB. Nur `~/Library/Mobile Documents` (iCloud) lief noch in die Frist und zählt mit 0. Kein fehlender Katalogbereich. Details: `docs/superpowers/plans/2026-10-29-abnahme.md` (Abschnitt „Teilprojekt 2“).

### Offen für Frank (TP2)
- [ ] Mit vollem Festplattenzugriff erneut messen; `~/Library/Mobile Documents` evtl. längere Frist (Ziel ≥ 90 %).
- [ ] Tab Systemdaten in `--dry-run` ansehen.
- [ ] Einen Admin-Aufräumfund echt ausführen → genau eine Passwortabfrage; „Ich habe verstanden“ muss den Button freischalten.

## Stand Teilprojekt 3 – Automatischer Check & Migration (29.10.2026)
- Hintergrund-Check per LaunchAgent (`SMAppService.agent`, Aufruf `--check`), Verlauf in `~/Library/Application Support/Klarschiff2/history.json`, Mitteilung bei Auffälligkeiten, Einstellungen (⌘,) mit Statuszeile, Migrationskarte zum Entfernen der alten Aufräum-Automatik (`LegacyAutomation`). Der Check **löscht nie** und fragt nie im Hintergrund.
- Lese-Prüfung auf Franks Mac: beide alten Agents (`com.frankjuchim.cleanup`, `de.bodendiek.klarschiff.check`, beide geladen) sowie `cleanup.sh`, `cleanup.log`, `cleanup_error.log` erkannt. `--check` lief mit Exit 0 in ≈ 29 s (aufräumbar 45,79 GB, frei 219,80 GB). Details: Abnahme-Abschnitt „Teilprojekt 3“. Opt-in-Livetest `liveLegacyDetectWritesSummary` (`KLARSCHIFF_LIVE_SCAN=1`).

### Offen für Frank (TP3)
- [ ] Signierte App: Check auf „Wöchentlich“, unter Anmeldeobjekte erlauben, Mitteilungen zulassen.
- [ ] „Jetzt prüfen“ ausführen; Einstellungen in `--dry-run` ansehen.
- [ ] „Alte Automatik entfernen“ echt ausführen und mit `launchctl list | grep -E "frankjuchim|klarschiff"` prüfen.
- [ ] Beim ersten echten Hintergrund-Check auf Datenschutz-Abfragen achten.
- [ ] Die alte App Klarschiff 1 (`/Applications/Klarschiff.app`) existiert noch; sie lässt sich über den Fund unter „Apps“ oder von Hand entfernen.

### Bekannte Abweichungen Teilprojekt 3
- Der LaunchAgent des Checks lässt sich ohne Signatur/Team nicht registrieren; die Registrierung und die Hintergrundausführung sind daher nur mit der signierten App prüfbar (hier nur `--check` direkt aufgerufen).
- Die leere alte `Klarschiff.app` wurde auf Franks Mac nicht gefunden (Erkennung nur für wirklich leere Bundles).

## Stand Teilprojekt 4 – Hintergrunddienste (30.10.2026)
- Tab „Hintergrunddienste“: listet LaunchAgents/-Daemons (ohne `com.apple.*`) und Anmeldeobjekte, erklärt sie, erkennt verwaiste Dienste und entfernt sie nach Bestätigung (Benutzer: `bootout` + Papierkorb; /Library: Admin, eine Passwortabfrage). Nicht verwaiste Dienste und Anmeldeobjekte werden nie entfernt. Der automatische Check meldet neu verwaiste Dienste.
- Lese-Prüfung auf Franks Mac: 17 Einträge (Benutzer 5, Alle Benutzer 6, System 6), 0 verwaist, 1 läuft (Logi Options). Anmeldeobjekte konnten in der Agent-Sitzung nicht gelesen werden (`sfltool dumpbtm` ohne Ausgabe). Details: Abnahme-Abschnitt „Teilprojekt 4“. Opt-in-Livetest `liveServicesWritesSummary` (`KLARSCHIFF_LIVE_SCAN=1`).

### Offen für Frank (TP4)
- [ ] Tab in `--dry-run` ansehen; Anmeldeobjekte prüfen (`sfltool dumpbtm` im Terminal).
- [ ] Verwaisten Benutzer-Agent (ggf. Dummy) echt entfernen; optional einen /Library-Eintrag (eine Passwortabfrage); mit `launchctl list` prüfen.

### Bekannte Abweichungen Teilprojekt 4
- Anmeldeobjekte: nur BTM-Typ „login item“; „app“-Einträge dienen nur der Namensauflösung. Andere BTM-Typen (z. B. Agent/Daemon über `SMAppService`) erscheinen nicht als Anmeldeobjekt.
- Apple-Dienste ohne `com.apple.`-Präfix gelten nicht als Apple-Dienste durch das Präfix, sind aber geschützt (nie als entfernbar angeboten).

## Stand Teilprojekt 5 – Leistung (30.10.2026)
- Tab „Leistung“: Kacheln für Prozessor, Arbeitsspeicher (mit Speicherdruck), Auslagerung und Laufzeit, Top-12-Liste der Apps (Prozesse gebündelt, RAM, CPU mit Verlauf), „Beenden“ für reguläre Apps (nie Finder, Klarschiff 2 oder Systemdienste), Hinweise auf Bremser und eine Spotlight-Karte mit großen Projektordnern (`node_modules`, `.build` …). Alles lesend, nichts wird automatisch beendet oder verändert.
- Lese-Messung auf Franks Mac: CPU 45 %, Speicher 11,66 GB von 16 GB (Druck entspannt), Auslagerung 1,5 GB, 823 Prozesse, 2 Spotlight-Kandidaten (je über 200 MB). Details: Abnahme-Abschnitt „Teilprojekt 5“. Opt-in-Livetest `livePerformanceWritesSummary` (`KLARSCHIFF_LIVE_SCAN=1`).

### Offen für Frank (TP5)
- [ ] Kacheln mit der Aktivitätsanzeige vergleichen (±10 %).
- [ ] Tab in `--dry-run` ansehen; „Beenden“ im Trockenlauf, dann echt mit TextEdit testen.
- [ ] Spotlight-Karte und Finder-Lupe prüfen; Einstellungen-Button testen.

## Alles fertig – offene Punkte gesammelt
Alle fünf Teilprojekte sind umgesetzt. Was nur mit dir am Mac geht:
- [ ] **Oberfläche in `--dry-run`** durchsehen: alle Tabs (Aufräumen, Systemdaten, Hintergrunddienste, Leistung) und Einstellungen.
- [ ] **Echter kleiner Lauf** (TP1): Homebrew aufräumen plus ein Papierkorb-Fund, App aus dem Finder gestartet.
- [ ] **Admin-Schritte** echt ausführen (TP1/TP2): ein Systemfund, genau eine Passwortabfrage, „Ich habe verstanden“ schaltet den Button frei. Ebenso das echte Entfernen von Diensten unter `/Library` (TP4, Admin) und eines verwaisten Benutzer-Agents (ggf. Dummy).
- [ ] **Signierte App**: LaunchAgent des Checks registrieren (Wöchentlich, Anmeldeobjekte erlauben, Mitteilungen zulassen), „Jetzt prüfen“, alte Automatik entfernen (`launchctl list` prüfen), alte App Klarschiff 1 entfernen (TP3).
- [ ] **Datenschutzabfragen (TCC)** beobachten: Docker, UTM, Telegram, OrbStack und beim ersten Hintergrund-Check; Telegram-Muster mit vollem Festplattenzugriff verifizieren (TP1/TP3).
- [ ] **Voller Festplattenzugriff** (TP2): Systemdaten erneut messen, Ziel mindestens 90 % zugeordnet (zuletzt 75,0 %); iCloud-Ordner `~/Library/Mobile Documents` braucht evtl. längere Frist.
- [ ] **Anmeldeobjekte** (TP4): `sfltool dumpbtm` lieferte in der Agent-Sitzung auch nach über 2 Minuten nichts; der Reader bricht nach 20 s Zeitlimit ab und meldet „nicht lesbar“. In der echten App prüfen, ob die Liste erscheint.
- [ ] **Leistung** (TP5): Kacheln gegen Aktivitätsanzeige (±10 %), „Beenden“ mit TextEdit, Spotlight-Karte, Finder-Lupe, Einstellungen-Button.
- [ ] **Release**: `scripts/release.sh` samt Notarisierung einmal mit echtem Team und Profil durchlaufen lassen.
- [ ] Echte `softwareupdate -l`-Ausgabe festhalten, sobald ein Update ansteht (TP1).

## Startnachricht für die Sitzung auf dem Mac
> Alle Teilprojekte (1–5) sind umgesetzt. Lies CLAUDE.md und docs/UEBERGABE.md, Abschnitt „Alles fertig – offene Punkte gesammelt“, und arbeite die offenen Punkte gemeinsam mit Frank ab. Branch: claude/intelligent-galileo-8ok14a.

## Danach
Offene Ideen (jeweils mit eigenem Brainstorming → Spec → Plan): Menüleisten-Icon ja/nein, Schwellen des Wachstumswächters.

## Bekannte Abweichungen Teilprojekt 2
- `log erase`: Bei Exit ≠ 0 zeigt die Entfernung nur „Exit N“ statt gekürzter stderr (Spec §7), weil der `PrivilegedExecutor` nur Exit-Codes liefert; nachrüstbar, wenn er Ausgaben durchreicht.
- Keine eigene „Simulator-Volumes“-Bar im Systemdaten-Tab (Spec-Abweichung); Simulator-Volumes werden nicht doppelt gezählt.
- Ohne Vollzugriff werden `Desktop`, `Documents`, `Downloads` nicht gemessen (vermeidet Datenschutzabfragen); „Deine Daten“ ist dann eine Untergrenze.
