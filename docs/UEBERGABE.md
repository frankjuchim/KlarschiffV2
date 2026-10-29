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

## Startnachricht für die Sitzung auf dem Mac
> Lies CLAUDE.md und docs/UEBERGABE.md. Setze den Plan docs/superpowers/plans/2026-10-29-klarschiff2-teilprojekt1.md mit superpowers:subagent-driven-development um, beginnend bei Task 1. Branch: claude/intelligent-galileo-8ok14a. Nach jedem Task committen und pushen.

## Danach
Teilprojekte 3–5 (Automatischer Check + Migration alter Agents, Hintergrunddienste, Leistung) jeweils mit eigenem Brainstorming → Spec → Plan. Offene Fragen dafür: Menüleisten-Icon ja/nein, Schwellen des Wachstumswächters.

## Bekannte Abweichungen Teilprojekt 2
- `log erase`: Bei Exit ≠ 0 zeigt die Entfernung nur „Exit N“ statt gekürzter stderr (Spec §7), weil der `PrivilegedExecutor` nur Exit-Codes liefert; nachrüstbar, wenn er Ausgaben durchreicht.
- Keine eigene „Simulator-Volumes“-Bar im Systemdaten-Tab (Spec-Abweichung); Simulator-Volumes werden nicht doppelt gezählt.
- Ohne Vollzugriff werden `Desktop`, `Documents`, `Downloads` nicht gemessen (vermeidet Datenschutzabfragen); „Deine Daten“ ist dann eine Untergrenze.
