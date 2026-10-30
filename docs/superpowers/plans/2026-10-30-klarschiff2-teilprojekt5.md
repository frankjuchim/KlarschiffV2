# Klarschiff 2 – Teilprojekt 5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Tab „Leistung“: Live-Kacheln, „Was bremst gerade?“, aktivste Apps & Dienste (freundliches Beenden), Spotlight entlasten, bewusster Verzicht.

**Architecture:** Core `Performance/` (SystemSampler, ProcessSampler, ActivityAggregator, SlowdownDetector, SpotlightProjectScanner) mit reinen, testbaren Rechenfunktionen; App: `PerformanceModel` (@Observable, Timer nur bei sichtbarem Tab) + Views.

**Tech Stack:** Swift 6, SwiftUI (macOS 26), Darwin (host_statistics, sysctl, libproc), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-30-klarschiff2-teilprojekt5-design.md` (verbindlich).

## Global Constraints

- Alle TP1–TP4-Constraints gelten (Swift 6 strict, Du-Form, `ByteFormat`, Anzeigename „Klarschiff 2“, Trockenlauf).
- Nur lesende Systemabfragen; einzige Aktion `NSRunningApplication.terminate()` nach Bestätigung, nur reguläre Benutzer-Apps, nie Klarschiff 2/Finder/Systemprozesse, nie `forceTerminate`/`kill`.
- Messung nur bei sichtbarem Tab, Intervall 2 s, Verlauf 60 Werte; Schwellen/Wörter exakt Spec §2.
- Spotlight-Scanner verändert nichts, überspringt `~/Library`, Schwelle 100_000_000 Bytes, Zeitlimit 60 s.
- Static helpers on SwiftUI views called from tests must be `nonisolated`.

## Review Focus

1. **Prozess endet zwischen zwei Proben / PID wird wiederverwendet** → kein Absturz, keine negativen/riesigen CPU-Werte (Deltas nur bei gleicher PID + Startzeit). Test in Task 2.
2. **Sehr viele Prozesse / Zugriff verweigert** → nur Lesbares zählen, kein Absturz, Zeit pro Probe < 200 ms auf Franks Mac. Test in Task 2 (Fake) + Task 5 (live).
3. **Tab wechselt während einer Probe / App im Hintergrund** → Timer stoppt sicher, keine Updates nach onDisappear. Test in Task 4.
4. **Spotlight-Scan über riesiges Home / Symlinks / iCloud-Ordner** → Zeitlimit, keine Symlinks folgen, keine Datenschutz-Abfragen ohne Vollzugriff (Desktop/Dokumente/Downloads ohne Vollzugriff überspringen, wie TP2). Test in Task 3.
5. **Beenden einer App mit ungesicherten Daten** → nur `terminate()` (App fragt selbst), Bestätigung vorher, Trockenlauf meldet nur. Test in Task 4.

---

### Task 1: SystemSampler und Kachel-Rechnung
**Files:** Create `Performance/SystemSample.swift`, `Performance/SystemSampler.swift`, `Performance/PerformanceWords.swift`; Test `SystemSamplerTests.swift`
**Interfaces:** `struct CPUTicks: Sendable, Equatable { user, system, idle, nice: UInt64 }`; `struct SystemSample: Sendable { date: Date; cpu: CPUTicks; memoryUsed: UInt64; memoryTotal: UInt64; pressureLevel: Int; swapUsed: UInt64; bootTime: Date }`; `protocol SystemSampling: Sendable { func sample() -> SystemSample? }`; `struct LiveSystemSampler: SystemSampling`; `enum PerformanceMath { static func cpuLoad(_ a: CPUTicks, _ b: CPUTicks) -> Double /* 0…1, 0 bei keinem Fortschritt */ }`; `enum PerformanceWords { static func cpu(_ load: Double) -> String; static func memory(pressure: Int) -> String; static func swap(_ bytes: UInt64) -> String; static func uptime(since: Date, now: Date) -> (value: String, word: String) /* „3 Tage“, „5 Stunden“ */ }`.
- [ ] Tests: Grenzwerte aller Wörter exakt Spec §2 (29,9 % kühl, 30 % beschäftigt, 69,9 %, 70 %), Delta mit Überlauf/keinem Fortschritt, Uptime-Texte deutsch (1 Tag/2 Tage, Stunden < 1 Tag), Live-Plausibilität (total == ProcessInfo.physicalMemory, used ≤ total, bootTime < now). Commit `feat: Systemwerte messen`

### Task 2: Prozesse und Aggregation
**Files:** Create `Performance/ProcessSampler.swift`, `Performance/ActivityAggregator.swift`; Test `ActivityAggregatorTests.swift`
**Interfaces:** `struct ProcessSample: Sendable { pid: Int32; startTime: UInt64; name: String; path: String?; uid: uid_t; cpuTimeNs: UInt64; residentBytes: UInt64 }`; `protocol ProcessSampling: Sendable { func sample() -> [ProcessSample] }`; `struct LiveProcessSampler` (libproc, Zugriffsfehler → Prozess überspringen bzw. ohne CPU); `struct ActivityEntry: Sendable, Identifiable, Equatable { id: String; name: String; appPath: String?; bundleID: String?; processCount: Int; residentBytes: UInt64; cpuPercent: Double; isSystem: Bool; canQuit: Bool; history: [Double] }`; `struct ActivityAggregator: Sendable { mutating func update(previous: [ProcessSample], current: [ProcessSample], interval: TimeInterval, apps: [RunningAppInfo]) -> [ActivityEntry] /* top 12 */ }`, `struct RunningAppInfo: Sendable { pid: Int32; bundleID: String?; name: String; bundlePath: String?; isRegular: Bool }` (App liefert sie aus NSWorkspace).
- [ ] Tests: Gruppierung nach umgebendem `.app` / Bundle, CPU-% aus Deltas (mehrere Kerne → kann > 100 % je App, wie Aktivitätsanzeige), PID-Wiederverwendung (andere startTime → kein Delta), beendeter Prozess, System-Erkennung (uid 0, Pfade), canQuit nur regular + nicht Klarschiff 2 (`de.frankjuchim.klarschiff2`) + nicht Finder (`com.apple.finder`) + nicht System, Verlauf max 60, Top-12-Sortierung (CPU, dann RAM, dann Name). Live-Plausibilität (≥ 50 Prozesse, eigene PID enthalten, Dauer < 200 ms). Commit `feat: aktivste Apps und Dienste ermitteln`

### Task 3: Bremser-Erkennung und Spotlight-Kandidaten
**Files:** Create `Performance/SlowdownDetector.swift`, `Performance/SpotlightProjectScanner.swift`; Tests `SlowdownDetectorTests.swift`, `SpotlightProjectScannerTests.swift`
**Interfaces:** `struct SlowdownHint: Sendable, Equatable, Identifiable { id: String; title: String; text: String }`; `struct SlowdownDetector: Sendable { mutating func update(sample: SystemSample, top: [ActivityEntry], now: Date) -> [SlowdownHint] }` (Regeln Spec §2, Dauer ≥ 180 s ununterbrochen, Unterbrechung setzt zurück); `struct SpotlightCandidate: Sendable, Identifiable { id: String; url: URL; kind: String /* „node_modules“ … */; size: Int64 }`; `struct SpotlightProjectScanner: Sendable { init(sizeOf: (@Sendable (URL) async throws -> Int64)? = nil); func scan(_ ctx: ScanContext) async -> [SpotlightCandidate] }` (Regeln Spec §2; ohne Vollzugriff Desktop/Documents/Downloads überspringen; keine Symlinks; Tiefe ≤ 6; Zeitlimit 60 s).
- [ ] Tests: 3-Minuten-Regel inkl. Unterbrechung und Grenze (179 s nein, 180 s ja), jede Regel einzeln, Texte deutsch; Scanner: jede Art inkl. Nachbardatei-Regeln (`target` nur mit Cargo.toml, `build` nur mit build.gradle/CMakeLists.txt), `.noindex`/`.metadata_never_index` ausgeschlossen, < 100 MB ausgeschlossen, `~/Library` übersprungen, verschachtelte `node_modules` nur äußerster, Symlink nicht gefolgt, ohne FDA Desktop übersprungen. Commit `feat: Bremser erkennen, Spotlight-Kandidaten finden`

### Task 4: PerformanceModel (App)
**Files:** Create `App/Model/PerformanceModel.swift`; Modify `App/Model/AppModel.swift` (Besitz/Verdrahtung, Trockenlauf-Zustand teilen); Test `AppTests/PerformanceModelTests.swift`
**Interfaces:** `@MainActor @Observable final class PerformanceModel { init(dependencies: PerformanceDependencies); var cpuLoad, cpuHistory: [Double], memoryUsed, memoryTotal, pressureLevel, swapUsed, bootTime, top: [ActivityEntry], hints: [SlowdownHint], spotlight: [SpotlightCandidate], isScanningSpotlight; func start(); func stop(); func scanSpotlightIfNeeded() async; func rescanSpotlight() async; func requestQuit(_ e: ActivityEntry) -> Bool /* nur canQuit */; func quit(_ e: ActivityEntry, dryRun: Bool) async -> String? /* Ergebnistext */ }`; `PerformanceDependencies` mit Samplern, Uhr/Timer-Abstraktion (für Tests: manuelles Ticken), `runningApps: @Sendable () -> [RunningAppInfo]`, `terminate: @Sendable (Int32) async -> Bool`, Spotlight-Scan-Closure.
- [ ] Tests: start/stop (nach stop keine Updates), Ticks füllen Verlauf (max 60), quit nur bei canQuit, Trockenlauf ruft terminate nicht, Spotlight einmal pro App-Start. Commit `feat: Leistungsmodell`

### Task 5: Tab „Leistung“
**Files:** Create `App/Views/Performance/PerformanceTabView.swift`, `MetricTile.swift`, `Sparkline.swift`, `ActivityList.swift`, `SpotlightCard.swift`, `RestraintCard.swift`; Modify `App/KlarschiffApp.swift` (Platzhalter für `.performance` ersetzen; Platzhalter-View entfernen, wenn kein Tab ihn mehr nutzt), Previews.
- [ ] Texte exakt Spec §4/§2; Screenshots `04/05-leistung-*.webp` als Vorbild; Messung onAppear/onDisappear; Bestätigung „<App> beenden?“ / „Abbrechen“ / „Beenden“; Spotlight-Knopf öffnet die Spotlight-Einstellungen. Build/Test grün, keine Warnungen, Start nur `--dry-run` ~60 s. Commit `feat: Tab Leistung`

### Task 6: Abnahme und Doku
- [ ] Opt-in-Livetest: Systemwerte, Top-Liste, Spotlight-Kandidaten lesend → Markdown; Abgleich-Hinweis für Frank (Aktivitätsanzeige). Abnahme-Abschnitt „Teilprojekt 5“, UEBERGABE (alle Teilprojekte fertig, offene Punkte gesammelt), README. Commit `docs: Abnahme TP5`
