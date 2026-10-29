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

## Startnachricht für die Sitzung auf dem Mac
> Lies CLAUDE.md und docs/UEBERGABE.md. Setze den Plan docs/superpowers/plans/2026-10-29-klarschiff2-teilprojekt1.md mit superpowers:subagent-driven-development um, beginnend bei Task 1. Branch: claude/intelligent-galileo-8ok14a. Nach jedem Task committen und pushen.

## Danach
Teilprojekte 2–5 (Systemdaten, Automatischer Check + Migration alter Agents, Hintergrunddienste, Leistung) jeweils mit eigenem Brainstorming → Spec → Plan. Offene Fragen dafür: Menüleisten-Icon ja/nein, Schwellen des Wachstumswächters.
