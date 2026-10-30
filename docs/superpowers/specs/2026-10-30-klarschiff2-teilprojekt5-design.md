# Klarschiff 2 – Teilprojekt 5: Leistung

**Stand:** 30.10.2026 · **Grundlage:** `docs/Briefing.md` §2 „Tab Leistung“, Screenshots `docs/screenshots/04-leistung-oben.webp`, `05-leistung-unten.webp`, Specs TP1–TP4
**Status:** Von Claude in der Nacht autonom entschieden (Frank: „Entwicklung über Nacht komplett fortführen, Ziel ist klar“). Entscheidungen in §2, änderbar.

## 1. Ziel und Erfolgskriterium

Der Tab **„Leistung“** zeigt ruhig und verständlich, wie es dem Mac gerade geht (Prozessor, Arbeitsspeicher, Auslagerung, Zeit seit Neustart), nennt erst dann einen Bremser, wenn etwas über Minuten auffällt, listet die aktivsten Apps & Dienste (mit freundlichem Beenden für eigene Apps) und hilft, Spotlight von Projektordnern wie `node_modules` zu entlasten. Er erklärt bewusst, was Klarschiff 2 **nicht** tut (kein „RAM freigeben“, kein Dauer-Cache-Leeren).

**Abnahme:** Auf Franks Mac zeigt der Tab plausible Live-Werte (Abgleich mit Aktivitätsanzeige ± 10 %), eine sortierte Liste aktiver Apps mit CPU/RAM, und die Spotlight-Karte findet vorhandene Projektordner.

## 2. Entscheidungen (autonom, 30.10.2026)

| Frage | Entscheidung | Begründung |
|---|---|---|
| Messung | Nur **solange der Tab sichtbar ist**, alle **2 s**, Verlauf der letzten **60** Werte (2 min) für Sparklines | Kein Dauerverbrauch im Hintergrund. |
| Prozessor | Gesamtlast aus `host_statistics(HOST_CPU_LOAD_INFO)`-Deltas; Wort: < 30 % „kühl“, < 70 % „beschäftigt“, sonst „unter Last“ | Briefing-Wortwahl „kühl“. |
| Arbeitsspeicher | „benutzt“ wie die Aktivitätsanzeige: App-Speicher (internal − purgeable) + fest belegt (wired) + komprimiert aus `host_statistics64(HOST_VM_INFO64)`, gesamt aus `ProcessInfo.physicalMemory`, Anzeige in Binäreinheiten (`ByteFormat.memoryString`); Wort nach Speicherdruck (`sysctl kern.memorystatus_vm_pressure_level`: 1 „entspannt“, 2 „angespannt“, 4 „knapp“) | Entspricht Aktivitätsanzeige; Druck ist aussagekräftiger als Prozent. |
| Ausgelagert | `sysctl vm.swapusage` (benutzt); Wort: 0 „nichts“, < 2 GiB (2_147_483_648) „wenig“, sonst „viel“ | |
| Seit Neustart | `sysctl kern.boottime`; < 7 Tage „frisch genug“, < 21 Tage „läuft schon eine Weile“, sonst „Neustart würde guttun“ | Briefing „frisch genug“. |
| „Was bremst gerade?“ | Hinweise erst, wenn eine Bedingung **≥ 3 Minuten** ununterbrochen gilt (während der Tab offen ist): eine App > 80 % CPU; Speicherdruck ≥ 2; Auslagerung wächst um > 1 GB in 3 min. Sonst Text „Gerade bremst nichts.“ | Briefing „erst, wenn etwas über Minuten auffällt“. |
| Aktivste Apps & Dienste | Prozesse über `proc_listallpids` + `proc_pidinfo(PROC_PIDTASKINFO)` (CPU-Zeit-Deltas, resident), gruppiert nach App (Bundle über `NSRunningApplication(processIdentifier:)` bzw. `proc_pidpath` → umgebendes `*.app`; sonst Prozessname). Top 12 nach CPU, Gleichstand RAM. Spalten: Name (+ App-Symbol), Prozessanzahl, RAM, Sparkline, CPU-%. | Briefing. Nur lesend. Root-Prozesse ohne Rechte: nur Name/RAM soweit lesbar. |
| Beenden | **x** nur bei normalen Benutzer-Apps (`NSRunningApplication`, `activationPolicy == .regular`, nicht Klarschiff 2 selbst, nicht Finder) → `terminate()` (freundlich, ungesicherte Daten fragt die App selbst); Bestätigung „<App> beenden?“. Kein Kill, kein Erzwingen. | Sicherheit. |
| Schloss | Systemprozesse (Benutzer-ID 0/`_`-Konten, Pfad in `/System`, `/usr/libexec`, `/usr/sbin`, `/sbin`) zeigen ein Schloss, nie Beenden | Briefing. |
| Spotlight entlasten | Durchsucht Home (ohne `~/Library`, Tiefe ≤ 6, ohne versteckte Ordner außer den Zielnamen) nach Projektordnern `node_modules`, `.build`, `Pods`, `target` (nur mit `Cargo.toml` daneben), `.venv`/`venv`, `__pycache__`, `DerivedData`, `.gradle`, `build` (nur mit `build.gradle`/`CMakeLists.txt` daneben) ≥ 100 MB, die **nicht** ausgeschlossen sind (Name endet nicht auf `.noindex`, kein `.metadata_never_index`, Spotlight-Prüfung `mdutil -s` nicht nötig). Aktion: „Im Finder zeigen“ + Erklärung, wie man den Ordner in Systemeinstellungen → Spotlight → Datenschutz ausschließt (Knopf öffnet die Spotlight-Einstellungen). **Klarschiff 2 ändert keine Projektordner.** | Automatisches Umbenennen/Markerdateien ist unzuverlässig bzw. verändert Projekte. |
| Bewusster Verzicht | Karte „Was Klarschiff 2 bewusst nicht tut“: kein „RAM freigeben“ (macOS nutzt freien Speicher als Cache, Freigeben macht den Mac langsamer), kein Dauer-Cache-Leeren (Caches beschleunigen; Aufräumen nur gezielt im Tab Speicher). | Briefing. |

## 3. Kern (KlarschiffCore, Ordner `Performance/`)

- **`SystemSampler`** (Protokoll + Produktion): liefert `SystemSample { date, cpuTicks (user/system/idle/nice), memory (active, wired, compressed, total), pressureLevel, swapUsed, bootTime }`. Reine Rechenfunktionen: `cpuLoad(previous:current:) -> Double`, Wort-Funktionen für alle vier Kacheln.
- **`ProcessSampler`**: liefert `[ProcessSample { pid, name, path?, uid, bundleID?, appURL?, cpuTimeNs, residentBytes }]`; **`ActivityAggregator`** (rein): bildet aus zwei Proben je App/Dienst `ActivityEntry { id, name, appURL?, processCount, residentBytes, cpuPercent, isSystem, canQuit }`, hält 60 Werte Verlauf je ID.
- **`SlowdownDetector`** (rein): bekommt Zeitreihe, gibt `[SlowdownHint]` (Titel + Text, deutsch) nach den Regeln in §2 (≥ 3 min ununterbrochen).
- **`SpotlightProjectScanner`**: wie §2, über `ScanContext` (Home), Größe über `SizeMeter`, Abbruch/Zeitlimit 60 s, Ergebnis `[SpotlightCandidate { url, kind, size }]` nach Größe.

## 4. Oberfläche (ersetzt den Platzhalter)

- **Kachelreihe** (4 Glas-Kacheln): „Prozessor“ (Prozent groß, Sparkline, Wort), „Arbeitsspeicher“ („X GB von Y GB“, Wort), „Ausgelagert“ (GB, Wort), „Seit Neustart“ („3 Tage“, Wort).
- **„Was bremst gerade?“**: Hinweise als Karten oder „Gerade bremst nichts.“ mit Untertitel „Klarschiff 2 meldet sich erst, wenn etwas über Minuten auffällt.“
- **„Aktivste Apps & Dienste“**: Liste wie §2; Schloss bzw. x; Bestätigung vor dem Beenden.
- **„Spotlight entlasten“**: Liste der Kandidaten mit Größe, Lupe, Erklärtext, Knopf „Spotlight-Einstellungen öffnen“ (`x-apple.systempreferences:com.apple.Spotlight-Settings.extension`); Suche startet beim ersten Öffnen des Tabs (einmal pro App-Start) und über „Neu suchen“.
- **„Was Klarschiff 2 bewusst nicht tut“**: Karte mit den zwei Punkten aus §2.
- Messung startet bei `onAppear` des Tabs, stoppt bei `onDisappear`.

## 5. Sicherheit

Nur lesende Systemabfragen. Einzige Aktion: freundliches `terminate()` bei normalen Benutzer-Apps nach Bestätigung. Keine Dateien werden verändert. Trockenlauf: Beenden im Trockenlauf wird nur gemeldet (konsistent mit „nichts verändern“).

## 6. Tests

Rechenfunktionen (CPU-Delta, Wörter mit Grenzwerten), Aggregator (Gruppierung, Prozent aus Deltas, Systemerkennung, canQuit-Regeln), SlowdownDetector (3-Minuten-Regel, Unterbrechung setzt zurück), SpotlightProjectScanner gegen FixtureTree (Typen, Nachbardatei-Regeln, ausgeschlossene, Schwelle, ~/Library übersprungen), Sampler-Produktion als Plausibilitätstest (Werte > 0, total = physicalMemory), App: Messung nur bei sichtbarem Tab, Beenden mit Bestätigung, Trockenlauf.
