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

## Startnachricht für die Sitzung auf dem Mac
> Lies CLAUDE.md und docs/UEBERGABE.md. Setze den Plan docs/superpowers/plans/2026-10-29-klarschiff2-teilprojekt1.md mit superpowers:subagent-driven-development um, beginnend bei Task 1. Branch: claude/intelligent-galileo-8ok14a. Nach jedem Task committen und pushen.

## Danach
Teilprojekte 2–5 (Systemdaten, Automatischer Check + Migration alter Agents, Hintergrunddienste, Leistung) jeweils mit eigenem Brainstorming → Spec → Plan. Offene Fragen dafür: Menüleisten-Icon ja/nein, Schwellen des Wachstumswächters.
