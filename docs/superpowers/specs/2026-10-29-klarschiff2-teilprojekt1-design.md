# Klarschiff 2 – Teilprojekt 1: Fundament, Speicher und Entwickler

**Stand:** 29.10.2026 · **Grundlage:** `docs/Briefing.md`, Screenshots in `docs/screenshots/`
**Status:** Architektur (Abschnitt 3) vom Auftraggeber abgenommen; Oberfläche und Katalog (Abschnitte 4–6) auf Basis des Briefings ausgearbeitet, Abnahme mit der Spec.

---

## 1. Ziel und Erfolgskriterium

Klarschiff 2 ersetzt Klarschiff 1 vollständig. Es findet alles, was bei der manuellen Aufräumaktion am 28./29.10.2026 gefunden wurde, erklärt es in Alltagssprache und entfernt es **sicher** und mit dem jeweils richtigen Werkzeug. Ziel ist, dass man den Mac damit **wirklich komplett** aufräumen kann.

**Abnahme Teilprojekt 1:** Auf einem Mac im Zustand vom 28.10.2026 findet Klarschiff 2:
Instruments-Caches (102 GB), Simulator-Runtimes (iOS/visionOS/watchOS/tvOS), Update-Snapshots (als Hinweis), Flutter-SDK, TeX Live 2022, Gradle/Android-Reste, Homebrew-Altlasten, aufgeschlüsselte Xcode-Daten, Arduino, Anaconda – jeweils mit korrekter Risikostufe und korrekter Entfernungsmethode. Zusätzlich die Ergänzungen aus Abschnitt 6.

## 2. Entscheidungen (Brainstorming 29.10.2026)

| Frage | Entscheidung |
|---|---|
| Vertrieb | **Direkt-Download, privater Gebrauch (Frank + Kollege), kein App Store.** Keine Sandbox. Developer-ID-Signatur + Notarisierung (Developer Account vorhanden). |
| Bundle-ID | `de.frankjuchim.klarschiff2` |
| Admin-Aktionen | **Erst eine Passwortabfrage pro Aufräumlauf**, später privilegiertes Hilfsprogramm (`SMAppService`). Dafür Admin-Ausführung hinter Protokoll `PrivilegedExecutor`. |
| macOS-Mindestversion | **macOS 26** (alle Nutzer haben ≥ 27). Liquid Glass (`glassEffect`) wird direkt genutzt. |
| Tabs | **Fünf Tabs: Speicher · Entwickler · Systemdaten · Hintergrunddienste · Leistung** |
| Aufteilung | 5 Teilprojekte, siehe Abschnitt 10. Dieses Dokument = Teilprojekt 1. |

## 3. Architektur (abgenommen)

### 3.1 Projektaufbau
```
KlarschiffV2/
  project.yml                 XcodeGen-Definition (App-Target, Test-Target)
  App/                        SwiftUI-App „Klarschiff“ (nur UI + Verdrahtung)
  Packages/KlarschiffCore/    Swift Package, gesamte Logik ohne UI
    Sources/KlarschiffCore/
      Model/                  Finding, Risk, RemovalMethod, Category, …
      Scanning/               Scanner-Protokoll, ScanEngine, PathClaims
      Scanners/               ein File je Scanner-Gruppe
      Removal/                Remover je Methode, RemovalPlan, PrivilegedExecutor
      System/                 CommandRunner, SizeMeter, RunningApps, DiskInfo, FullDiskAccess
      Safety/                 SafetyGuard, KeepList
    Tests/KlarschiffCoreTests/  Fixtures + Tests
  .github/workflows/ci.yml    macOS-Runner: swift test + xcodebuild
```
- Xcode-Projekt wird mit **XcodeGen** erzeugt (`xcodegen generate`); `.xcodeproj` ist in `.gitignore`.
- `KlarschiffCore` ist plattformneutral formuliert, wo es geht, aber Ziel ist nur macOS 26.
- Swift 6, Strict Concurrency.

### 3.2 Kernmodelle
```swift
enum Risk { case safe /* Sicher */, review /* Prüfen */, hintOnly /* Nur Hinweis */ }

enum RemovalMethod {
  case trash                                  // in den Papierkorb
  case delete                                 // direkt löschen (mit Bestätigung)
  case tool(ToolCommand)                      // offizielles Werkzeug: simctl, brew, conda, npm, ollama, tmutil
  case admin([AdminStep])                     // braucht Admin-Rechte, wird gebündelt
  case hint(HintAction?)                      // nur Erklärung, ggf. Link (z. B. Softwareupdate öffnen)
}

struct Finding: Identifiable {
  let id: FindingID            // stabil: scannerID + Schlüssel (z. B. Pfad oder Runtime-ID)
  let scannerID: String
  let tab: AppTab              // .storage oder .developer
  let category: Category       // z. B. .aiLeftovers, .xcode, .simulators, .homebrew …
  let title: String
  let summary: String          // Alltagssprache
  let risk: Risk
  let method: RemovalMethod
  let items: [FindingItem]     // Einträge (Pfad, Größe, optional Name/Datum)
  let size: Int64?             // nil = nicht messbar (z. B. Snapshots)
  let blockingApps: [AppRef]   // laufende Apps, die vorher beendet werden müssen
  let keepSuggested: Bool      // z. B. neueste Runtime / neuester TeX-Jahrgang
  let commandPreview: [String] // exakte, kopierbare Befehle (ohne # Kommentare)
}
```
**Vorauswahl-Regel:** vorausgewählt ist ein Fund genau dann, wenn `risk == .safe`, `keepSuggested == false`, nicht auf der Behalten-Liste und `blockingApps` leer.

### 3.3 Bausteine
- **`Scanner`** (Protokoll): `var id: String`, `func scan(_ ctx: ScanContext) async throws -> [Finding]`. `ScanContext` enthält Home-Verzeichnis, Benutzer-Cache-Ordner (`DARWIN_USER_CACHE_DIR`), `CommandRunner`, `SizeMeter`, `RunningApps`, `PathClaims`, Datum „jetzt“. **Alle Pfade kommen aus dem Kontext** → Tests laufen gegen Fixture-Bäume.
- **`PathScanner`**: generischer Scanner aus einer deklarativen Definition (`PathRule`: Titel, Text, Kategorie, Pfadmuster relativ zu Home/Cache-Dir/absolut, Risiko, Methode, Bundle-IDs für „App läuft“). Der Großteil des Katalogs sind `PathRule`s in `Scanners/Catalog.swift`.
- **Spezial-Scanner** nur, wo Logik nötig ist: Simulator-Runtimes, Snapshots, Softwareupdate, TeX Live, Homebrew (Cleanup + Casks), Conda, Ollama, Hugging Face, Backups, alte Installer, lange nicht genutzte Apps, Reste gelöschter Apps, Sonstige App-Caches, Große Brocken, Fotos, Papierkorb.
- **`PathClaims`**: Spezifische Scanner beanspruchen ihre Pfade; generische Sammel-Scanner („Sonstige App-Caches“, „Große Brocken“-Abgleich) überspringen beanspruchte Pfade → **keine Doppelzählung**. Ablauf: ScanEngine lässt erst spezifische, dann Sammel-Scanner laufen.
- **`ScanEngine`**: führt Scanner parallel (TaskGroup) aus, abbrechbar, liefert Fortschritt; Fehler eines Scanners werden als „konnte nicht geprüft werden“ gemeldet, stoppen aber nichts.
- **`CommandRunner`** (Protokoll): `run(_ exe: String, _ args: [String], timeout: Duration, env: [String:String]) async throws -> CommandResult` (exit code, stdout, stderr). Echte Implementierung über `Process` mit Timeout, Logging (os.Logger). Test-Attrappe `FakeCommandRunner` liefert aufgezeichnete Ausgaben.
- **`ToolLocator`**: findet `brew` (`/opt/homebrew/bin`, `/usr/local/bin`), `xcrun` (nur wenn `xcode-select -p` erfolgreich), `conda`, `npm`, `ollama`, `tmutil`. GUI-Apps erben kein Shell-PATH → feste Suchpfade + `PATH` aus `/usr/libexec/path_helper`. Brew-Aufrufe immer mit `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_ENV_HINTS=1`.
- **`SizeMeter`**: belegte Blöcke via `URLResourceKey.totalFileAllocatedSizeKey`, rekursiv mit `FileManager.enumerator`, parallel je Wurzel, abbrechbar, harte Links nur einmal gezählt (Inode-Set bei `linkCount > 1`). Symlinks werden nicht verfolgt.
- **`RunningApps`**: `NSWorkspace.runningApplications` nach Bundle-ID + Prozessnamen für Werkzeuge ohne App (z. B. `instruments`, `xctrace`, `simctl`). Liefert auch „Beenden“ (freundlich via `terminate()`).
- **`KeepList`**: dauerhaft „Behalten“-markierte `FindingID`s, JSON in `~/Library/Application Support/Klarschiff2/keep.json`. Behaltenes wird nicht vorgeschlagen, ist aber in einem eingeklappten Bereich „Behalten (n)“ sichtbar und dort wieder freigebbar.
- **`SafetyGuard`**: letzte Prüfung **jedes** Pfads vor `trash`/`delete`/`admin`-rm. Verweigert u. a.:
  - `/`, `/System`, `/usr` (außer `/usr/local/texlive`), `/bin`, `/sbin`, `/private/var/folders` und alles darin **außer** freigegebenen Unterordnern im eigenen `C/`-Cache-Ordner (`DARWIN_USER_CACHE_DIR`) aus der Positivliste,
  - alles unter `/System/Volumes/Data/System/Library/AssetsV2` (nur über `simctl`),
  - alles unter `*/Caskroom/*` (nur über `brew`), `*/Cellar/*`,
  - Home selbst, `~/Library` selbst, `~/Documents`, `~/Desktop`, `~/Pictures/*.photoslibrary`,
  - Zugangsdaten: Dateinamen/Ordner wie `auth*.json`, `credentials*`, `config*`, `*.toml`, `.env`, `oauth*`, `token*`, `keychain*` innerhalb von `~/.codex`, `~/.gemini`, `~/.copilot`, `~/.config`,
  - Pfade, die Symlinks außerhalb ihrer Wurzel auflösen.
  Verstöße → Aktion bricht für diesen Eintrag ab und wird als Fehler gemeldet (nie stillschweigend).
- **Remover** (je Methode, gemeinsames Protokoll `Remover`):
  - `TrashRemover`: `FileManager.trashItem`.
  - `DeleteRemover`: `FileManager.removeItem`, nur nach eindeutiger Bestätigung im UI.
  - `ToolRemover`: führt `ToolCommand` über `CommandRunner` aus, wertet Exit-Code + bekannte Fehlermeldungen aus (z. B. Homebrew „untrusted tap“ → Hinweis mit `brew trust`/`brew untap`-Erklärung).
  - `AdminRemover`: sammelt alle `AdminStep`s eines Laufs und übergibt sie gebündelt an `PrivilegedExecutor`.
  - `PrivilegedExecutor` (Protokoll). Implementierung 1: `AppleScriptPrivilegedExecutor` – baut **ein** Shell-Skript aus korrekt gequoteten Einzelbefehlen (jeder Befehl mit Marker-Ausgabe `KS_STEP <n> <exit>`), führt es via `NSAppleScript` `do shell script … with administrator privileges` aus → **eine** Passwortabfrage. Ergebnisse je Schritt werden aus den Markern gelesen. Implementierung 2 (später): XPC-Helper via `SMAppService.daemon`.
- **`RemovalPlan`**: aus der Auswahl erzeugt; gruppiert nach Methode; Reihenfolge: blockierende Apps prüfen → `tool` → `trash`/`delete` → `admin` (eine Abfrage) → Ergebnisbericht mit freigegebenem Platz (`DiskInfo` vorher/nachher) und Fehlern je Eintrag.
- **`DiskInfo`**: freier/gesamter Speicher über `volumeAvailableCapacityForImportantUsageKey` / `volumeTotalCapacityKey` auf `/System/Volumes/Data`.
- **`FullDiskAccess`**: Prüfung durch Lesen eines geschützten Pfads (`~/Library/Containers/com.apple.stocks` bzw. `~/Library/Safari`); fehlt der Zugriff → Onboarding-Karte mit Knopf, der `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` öffnet. Scanner, die Vollzugriff brauchen (Backups, Mail, Papierkorb, Container), zeigen „braucht Vollzugriff“, statt fälschlich 0 zu melden.
- **Trockenlauf**: Umgebungsvariable/Startargument `--dry-run` und Einstellungs-Schalter (Entwicklermenü): Remover protokollieren nur.

### 3.4 Ablauf
Neu scannen → ScanEngine (spezifisch, dann Sammel-Scanner) → Funde je Tab/Kategorie → Auswahl (Vorauswahl-Regel) → „Aufräumen“ → **Bestätigungsdialog** (Liste: was, wie viel, Methode; Hinweis „direkt gelöscht, nicht im Papierkorb“ bei `delete`; Hinweis „eine Passwortabfrage“ bei `admin`; „Befehle anzeigen“) → Ausführung mit Fortschritt → Ergebnis („X GB frei geworden“, Fehler je Eintrag) → automatischer Neu-Scan der betroffenen Scanner.

### 3.5 Tests
- Jeder Scanner gegen **Fixture-Bäume** (temporäres Verzeichnis, Dummy-Dateien definierter Größe) und **aufgezeichnete Werkzeug-Ausgaben** (`Tests/Fixtures/simctl-runtime-list.json`, `brew-cleanup-n.txt`, `tmutil-listlocalsnapshots.txt`, …).
- `SafetyGuard`: eigene Negativtests für jede Verbotsregel.
- `AdminRemover`/Quoting: Tests auf das erzeugte Skript (Pfade mit Leerzeichen, Anführungszeichen, `$`).
- Vorauswahl-Regel, KeepList-Persistenz, PathClaims-Doppelzählung.
- CI: GitHub Actions `macos-26` (bzw. neuestes verfügbares Image) – `swift test` im Paket, `xcodegen generate && xcodebuild build`.

## 4. Oberfläche

### 4.1 Rahmen (alle Tabs)
- Fenster mit Pastell-Verlaufs-Hintergrund (Türkis/Violett/Rosa, weich, wie Klarschiff 1), Inhalte in **Liquid-Glass**-Karten (`glassEffect`), max. Inhaltsbreite ~1250 pt, zentriert, scrollbar.
- Header: Wortmarke „Klarschiff“ (Verlauf Türkis → Violett), Untertitel „Speicher aufräumen – KI-Reste, Caches und Liegengebliebenes.“
- Tab-Leiste als Pillen: **Speicher · Entwickler · Systemdaten · Hintergrunddienste · Leistung** (SF Symbols: `internaldrive`, `hammer`, `chart.pie`, `gearshape.2`, `gauge.with.dots.needle.50percent`).
- Kapazitätskarte rechts oben: „226,32 GB frei“, Verlaufsbalken, „von 494,38 GB“ (Live aus `DiskInfo`, aktualisiert nach jedem Lauf).
- Tabs Systemdaten, Hintergrunddienste, Leistung zeigen in Teilprojekt 1 eine freundliche Platzhalter-Karte („Kommt bald: …“) – die Navigation steht aber schon.
- Zahlen deutsch formatiert (`ByteCountFormatter`, `.file`, Locale `de_DE`): „11,99 GB“, „250,4 MB“.

### 4.2 Tab „Speicher“ und Tab „Entwickler“ (gleiches Muster)
- **Zusammenfassungskarte:** große Zahl „ausgewählte Größe“, „ausgewählt von X gefunden“, Knöpfe **Neu scannen** und **Aufräumen** (Verlauf), darunter Regeltext „Vorausgewählt ist nur, was sich von selbst wieder aufbaut. Großes wird direkt gelöscht, alles andere landet im Papierkorb.“, Knopf **Papierkorb leeren (Größe)** (nur Speicher-Tab).
- **Kategorien** mit Symbol, Titel, Summe rechts.
- **Fund-Karte:** Auswahlkreis links; Titel; Risiko-Pille **Sicher** (grün) / **Prüfen** (rot) / **Nur Hinweis** (grau-blau); Warnung „App läuft – vorher beenden“ (orange, mit Knopf „Beenden“); Pille „Neueste – behalten empfohlen“ bei `keepSuggested`; Kurzbeschreibung; rechts Größe + „n Einträge“; Chevron zum Aufklappen.
- **Aufgeklappt:** Einträge mit Pfad/Name, Größe, ggf. Datum, Lupe (im Finder zeigen), Einzelauswahl; Knopf „Befehl anzeigen“ (Sheet mit monospaced, kopierbarem Text, Knopf „Kopieren“); Menü „Immer behalten“.
- **Nur Hinweis**-Karten haben keinen Auswahlkreis, sondern einen Aktionsknopf (z. B. „Softwareupdate öffnen“) und erklären, was zu tun ist.
- **Bereich „Behalten (n)“** eingeklappt am Ende jedes Tabs.
- **Speicher-Tab zusätzlich:** Fotos-Karte (nur Erklärung) und **Große Brocken** (Ordner > 1 GB, Balkenliste, App-Icon bzw. Ordner-Icon, Lupe, grüner Zusatz „davon X oben aufräumbar“, Hinweistext wie Klarschiff 1).
- **Bestätigungsdialog** vor dem Aufräumen (siehe 3.4). Ergebnis-Banner danach.
- **Onboarding-Karte Vollzugriff**, oben, solange Vollzugriff fehlt.
- Tonalität: freundlich, erklärend, Du-Form, wie Klarschiff 1.

## 5. Scanner-Katalog

Spalten: **Stufe** S = Sicher, P = Prüfen, H = Nur Hinweis. **Methode** wie Abschnitt 3.2. Bei **P-Funden über 10 GB** mit Methode `trash` bietet der Dialog zusätzlich „direkt löschen“ an (Papierkorb schafft sonst keinen Platz). „App“ = Bundle-IDs für „App läuft“.
Pfade mit `~` = Home, `$C` = `DARWIN_USER_CACHE_DIR`.

### 5.1 Tab „Speicher“

**System**
| Fund | Erkennung | Stufe | Methode |
|---|---|---|---|
| Snapshots von macOS-Updates | `tmutil listlocalsnapshots /` → `com.apple.os.update-*`, `*MSUPrepareUpdate*`; Größe nicht messbar (`size = nil`, „vermutlich sehr groß“) | H | Hinweis „Ausstehendes Update installieren und neu starten – danach verschwinden sie.“ + Knopf „Softwareupdate öffnen“ (`x-apple.systempreferences:com.apple.Software-Update-Settings.extension`) |
| Time-Machine-Snapshots | `com.apple.TimeMachine.*` in derselben Liste | P | `admin`: `tmutil deletelocalsnapshots <Datum>` je Snapshot |
| Ausstehendes Softwareupdate | `softwareupdate -l` (Timeout 60 s, nur bei manuellem Scan) | H | Hinweis + Knopf |
| Papierkorb | `~/.Trash` (Vollzugriff) | P | Knopf „Papierkorb leeren“ (Bestätigung), nicht Teil von „Aufräumen“ |
| Alte Protokolle | `~/Library/Logs/**` Dateien älter als 30 Tage, `~/Library/Logs/DiagnosticReports` | S | `trash` |
| iPhone-/iPad-Softwareupdates | `~/Library/iTunes/iPhone Software Updates`, `~/Library/iTunes/iPad Software Updates` (*.ipsw) | S | `trash` |

**KI-Reste**
| Fund | Pfad | Stufe | Methode | App |
|---|---|---|---|---|
| Claude Desktop – Cache | `~/Library/Application Support/Claude/{Cache,Code Cache,GPUCache,DawnGraphiteCache,DawnWebGPUCache}`, `~/Library/Caches/com.anthropic.claudefordesktop*` | S | `trash` | `com.anthropic.claudefordesktop` |
| Claude Cowork – VM-Abbild | VM-Bundle unter `~/Library/Application Support/Claude/` (**exakten Ordnernamen bei der Umsetzung auf dem Mac ermitteln**, ~12 GB) | P | `delete` (>10 GB) | wie oben |
| Ollama-Modelle | `ollama list` (falls installiert), je Modell; sonst `~/.ollama/models` als Ganzes | P | `tool`: `ollama rm <name>`; Fallback `delete` | `com.electron.ollama`, Prozess `ollama` |
| Hugging Face | `~/.cache/huggingface/hub/models--*`, `datasets--*` je Eintrag | P | `delete` | – |
| LM Studio | `~/.lmstudio/models/*/*`, `~/.cache/lm-studio` | P | `delete` | `ai.elementlabs.lmstudio` |
| Codex/Gemini/Copilot-Caches | **nur** Unterordner mit Namen `log`, `logs`, `tmp`, `cache`, `.cache` direkt in `~/.codex`, `~/.gemini`, `~/.copilot` | S | `trash` | – |

**App-Caches**
| Fund | Pfad | Stufe | Methode |
|---|---|---|---|
| Telegram – Medien-Cache | `~/Library/Group Containers/*.ru.keepcoder.Telegram/**/postbox/media` (Pfad auf dem Mac verifizieren) | P | `trash` |
| Caches von App-Store-Apps | `~/Library/Containers/*/Data/Library/Caches/*` (nicht beansprucht) | S | `trash` |
| Spotify-Offline-Cache | `~/Library/Application Support/Spotify/PersistentCache` | S | `trash` |
| Adobe-Mediencache | `~/Library/Application Support/Adobe/Common/Media Cache Files`, `…/Media Cache` | S | `trash` |
| Sonstige App-Caches | `~/Library/Caches/*` (nicht beansprucht, ohne `com.apple.*`-Systemcaches mit Sonderrolle: `com.apple.bird`, `CloudKit`, `com.apple.Safari.SafeBrowsing`) | S | `trash` |

**Persönliche Daten**
| Fund | Pfad | Stufe | Methode |
|---|---|---|---|
| iPhone-/iPad-Backups | `~/Library/Application Support/MobileSync/Backup/*` – Gerät + Datum aus `Info.plist` | P | `trash` / `delete` (>10 GB) |
| Mail-Anhänge-Kopien | `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` | S | `trash` |
| Alte Installer in Downloads | `~/Downloads/*.{dmg,pkg,zip,xip,ipsw}` älter als 30 Tage (Änderungsdatum) | P | `trash` |
| Nachrichten-Anhänge | `~/Library/Messages/Attachments` (Größe) | H | Hinweis: „In Nachrichten → Einstellungen → Nachrichten behalten: 1 Jahr“ bzw. Systemeinstellungen → Allgemein → Speicher |

**Apps**
| Fund | Erkennung | Stufe | Methode |
|---|---|---|---|
| Lange nicht genutzte Apps | `/Applications/*.app` (ohne Apple-Apps, ohne Klarschiff), `kMDItemLastUsedDate` älter als 180 Tage, Größe des Bundles | P | `trash` (mit Hinweis: per Homebrew installierte Casks → Entwickler-Tab nutzen) |
| Reste gelöschter Apps | Ordner mit Reverse-DNS-Namen in `~/Library/Containers`, `~/Library/Application Support`, `~/Library/Caches`, `~/Library/HTTPStorages`, `~/Library/WebKit`, für deren Bundle-ID **keine** App installiert ist (`NSWorkspace.urlForApplication(withBundleIdentifier:)`); ohne `com.apple.*`; mind. 10 MB | P | `trash` |

**Fotos** (Karte, nur Erklärung): Größe von `~/Pictures/*.photoslibrary`, Erklärung zu „Mac-Speicher optimieren“ (greift erst bei knappem Speicher) und Hinweis, dass der iCloud-Status unten in der Mediathek steht. Keine Löschfunktion.

**Große Brocken:** Kinder dieser Wurzeln über 1 GB: `~` (ohne `Library`), `~/Library/Application Support`, `~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Developer`, `/Applications`, `/Library/Developer`, `/opt`, `/usr/local`. Anzeigename über `FileManager.displayName` (z. B. „Bilder“), Icon über `NSWorkspace.icon(forFile:)`. Pro Zeile „davon X oben aufräumbar“ = Summe der Fund-Einträge darunter. Nur Anzeige + Lupe, kein Löschen.

### 5.2 Tab „Entwickler“

**Xcode**
| Fund | Pfad / Befehl | Stufe | Methode | App |
|---|---|---|---|---|
| Instruments-Caches | `$C/com.apple.dt.Instruments`, `$C/com.apple.dt.InstrumentsCLI` | S | `delete` | `com.apple.dt.Xcode`, `com.apple.dt.Instruments`, Prozesse `xctrace`, `instruments` |
| Clang-Modul-Cache | `$C/clang/ModuleCache`, `$C/org.llvm.clang*` | S | `delete` | Xcode |
| DerivedData | `~/Library/Developer/Xcode/DerivedData/*` | S | `delete` | Xcode |
| SwiftUI-Previews | `~/Library/Developer/Xcode/UserData/Previews` | S | `delete` | Xcode |
| Device-Support-Dateien | `~/Library/Developer/Xcode/*DeviceSupport/*` je Version; neueste je Plattform = `keepSuggested` | S | `trash` | Xcode |
| Archives | `~/Library/Developer/Xcode/Archives/*/*` je Archiv mit Datum | P | `trash` | – |
| Geräte-Protokolle | `~/Library/Developer/Xcode/iOS Device Logs`, `~/Library/Developer/Xcode/Products` | S | `trash` | Xcode |
| Dokumentations-Cache | `~/Library/Developer/Xcode/DocumentationCache`, `~/Library/Developer/Xcode/DocumentationIndex` | S | `delete` | Xcode |
| Alte/zusätzliche Xcode-Versionen | `/Applications/Xcode*.app` außer der von `xcode-select -p` | P | `trash` | jeweilige Instanz |
| /Library/Developer aufgeschlüsselt | `/Library/Developer/CommandLineTools`, `/Library/Developer/CoreSimulator/Volumes` (nur Anzeige → Runtimes) | H | Hinweis | – |

**Simulatoren**
| Fund | Pfad / Befehl | Stufe | Methode | App |
|---|---|---|---|---|
| Simulator-Runtimes | `xcrun simctl runtime list -j` → je Runtime Plattform, Version, Build, `sizeBytes`; neueste je Plattform = `keepSuggested` | P | `tool`: `xcrun simctl runtime delete <identifier>` | `com.apple.iphonesimulator` |
| Nicht verfügbare Simulatoren | `xcrun simctl list devices unavailable -j` | S | `tool`: `xcrun simctl delete unavailable` | Simulator |
| CoreSimulator-Caches | `~/Library/Developer/CoreSimulator/Caches` | S | `delete` | Simulator |
| Simulator-Protokolle | `~/Library/Logs/CoreSimulator` | S | `trash` | – |

**Homebrew**
| Fund | Erkennung | Stufe | Methode |
|---|---|---|---|
| Homebrew-Aufräumen | `brew cleanup --prune=all -n` (Pfade parsen, Größe messen) + `brew autoremove -n` | S | `tool`: `brew cleanup --prune=all`, `brew autoremove` |
| Homebrew-Downloads | `brew --cache` Ordner | S | über obiges `cleanup` beansprucht |
| Casks nach Größe | `brew list --cask` + Größe von `<prefix>/Caskroom/<name>` (über 200 MB) | P | `tool`: `brew uninstall --cask <name>` (Option „inkl. Einstellungen (zap)“) – **nie `rm`** |
| Untrusted Taps | Fehlertext beim Deinstallieren | H | Hinweis mit Befehlsfolge `brew trust <tap>` → deinstallieren → `brew untap <tap>` |

**Sprachen & Paketmanager**
| Fund | Pfad | Stufe | Methode |
|---|---|---|---|
| npm-Cache | `~/.npm/_cacache` | S | `tool`: `npm cache clean --force`; Fallback `delete` |
| Yarn-Cache | `~/Library/Caches/Yarn` | S | `delete` |
| pnpm-Store | `~/Library/pnpm/store` | S | `tool`: `pnpm store prune`; Fallback Hinweis |
| Bun-Cache | `~/.bun/install/cache` | S | `delete` |
| nvm-Node-Versionen | `~/.nvm/versions/node/*`; neueste = `keepSuggested` | P | `trash` |
| pip-Cache | `~/Library/Caches/pip` | S | `delete` |
| uv-Cache | `~/.cache/uv` | S | `delete` |
| Poetry-Cache | `~/Library/Caches/pypoetry` | S | `delete` |
| pyenv-Versionen | `~/.pyenv/versions/*`; neueste = `keepSuggested` | P | `trash` |
| Conda/Anaconda | `/opt/anaconda3`, `/opt/miniconda3`, `~/anaconda3`, `~/miniconda3`; Paket-Cache `pkgs` | P | `tool`: `conda clean --all -y` (Paket-Cache); ganze Installation: Hinweis |
| Gradle | `~/.gradle/caches`, `~/.gradle/wrapper/dists`, `~/.gradle/daemon` | P | `trash` |
| Android | `~/.android/avd/*` (je AVD), `~/Library/Android/sdk` | P | `trash` (SDK als Cask → `brew`) |
| Maven | `~/.m2/repository` | P | `trash` |
| Flutter/Dart | `~/.pub-cache`, `~/.dart-tool`, `~/.dartServer`, `~/.flutter`; Flutter-SDK als Cask → Cask-Fund | P | `trash` |
| SwiftPM | `~/Library/Caches/org.swift.swiftpm`, `~/.swiftpm` | S | `delete` |
| CocoaPods | `~/Library/Caches/CocoaPods` | S | `delete` |
| Carthage | `~/Library/Caches/org.carthage.CarthageKit` | S | `delete` |
| Rust | `~/.cargo/registry/cache`, `~/.cargo/git/db`; Toolchains `~/.rustup/toolchains/*` (neueste stable = `keepSuggested`) | S / P | `delete` / `tool`: `rustup toolchain uninstall <name>` |
| Go | `~/go/pkg/mod`, `~/Library/Caches/go-build` | S | `tool`: `go clean -modcache` / `go clean -cache`; Fallback `delete` |
| Ruby-Gems-Cache | `~/.gem`, `~/.rbenv/versions/*` | P | `trash` |
| Browser für Tests | `~/Library/Caches/ms-playwright`, `~/.cache/puppeteer`, `~/Library/Caches/Cypress`, `~/Library/Caches/electron` | S | `delete` |

**Toolchains & SDKs**
| Fund | Erkennung | Stufe | Methode |
|---|---|---|---|
| TeX Live – alte Jahrgänge | `/usr/local/texlive/<JJJJ>` (vierstellig); neuester = `keepSuggested`, ältere = Fund | P | `admin`: `rm -rf /usr/local/texlive/<JJJJ>` |
| TeX Live – komplett | `/usr/local/texlive`, `/Library/TeX`, `/Applications/TeX` | P | `admin`: alle drei entfernen; Hinweis „Alternative: BasicTeX (`brew install --cask basictex`)“ |
| Arduino | `~/Library/Arduino15/staging` (S, `trash`); `~/Library/Arduino15/packages/*` (H, „im Board-Verwalter der Arduino IDE entfernen“) | S / H | `trash` / Hinweis |
| Docker / VMs | `~/Library/Containers/com.docker.docker/Data/vms`, `~/Library/Containers/com.utmapp.UTM/Data/Documents/*.utm`, `~/Parallels/*.pvm`, OrbStack-Daten | H | Hinweis: `docker system prune -a` bzw. in der jeweiligen App aufräumen |

### 5.3 Spätere Teilprojekte
Update-Snapshot-Größen (über `df`-Differenz), AssetsV2-Aufschlüsselung, `/private/var` → Teilprojekt 2 „Systemdaten“.

## 6. Ergänzungen gegenüber dem Briefing
Auf Wunsch „alles, was zusätzlich auffällt“: Alte Protokolle, iPhone-Softwareupdates (.ipsw), Spotify/Adobe-Caches, Nachrichten-Anhänge (Hinweis), lange nicht genutzte Apps, Reste gelöschter Apps, Geräte-Protokolle und Dokumentations-Cache von Xcode, alte Xcode-Versionen, Simulator-Protokolle, Yarn/pnpm/Bun/nvm/uv/Poetry/pyenv/Carthage/Rust/Go/Ruby, Test-Browser (Playwright, Puppeteer, Cypress, Electron), Ollama über `ollama rm`, `.xip`/`.ipsw` in Downloads.

## 7. Sicherheitsregeln (verbindlich, aus Briefing Abschnitt 6)
1. Nie automatisch löschen. 2. Offizielle Werkzeuge vor `rm` (simctl, brew, conda, …). 3. Nie `/private/var/folders` pauschal – nur Positivliste im eigenen `C/`. 4. Papierkorb vs. direkt löschen: `delete` und „P > 10 GB direkt löschen“ nur nach eindeutiger Bestätigung. 5. Laufende Apps erkennen, „vorher beenden“. 6. Behalten-Liste. 7. Jeder Befehl/Pfad sichtbar und kopierbar. 8. Admin-Aktionen klar gekennzeichnet und gebündelt (eine Passwortabfrage). 9. Kopierbare Befehle ohne `#`-Kommentare. 10. Neueste Versionen (Runtimes, TeX Live, Device Support, nvm/pyenv/rustup) als „behalten empfohlen“. 11. Zugangsdaten nie anfassen (SafetyGuard).

## 8. Fehlerbehandlung
- Scanner-Fehler → Karte „Konnte nicht geprüft werden: <Grund>“ in der Kategorie, Rest läuft weiter.
- Werkzeug fehlt (kein Xcode, kein brew) → Scanner liefert nichts (kein Fehler).
- Fehlender Vollzugriff → betroffene Funde zeigen „braucht Vollzugriff“ + Onboarding.
- Entfernen: Fehler je Eintrag im Ergebnis-Banner; abgebrochene Passwortabfrage → alle Admin-Schritte „abgebrochen“, Rest gilt.
- Timeouts: Werkzeuge 120 s (Runtime-Löschen 600 s), `softwareupdate -l` 60 s.

## 9. Signatur und Auslieferung
- Team-ID und Signatur über `project.yml` (`DEVELOPMENT_TEAM` als Build-Setting, lokal in `Config/Local.xcconfig`, nicht eingecheckt). Hardened Runtime an, keine Sandbox, Entitlement `com.apple.security.automation.apple-events` nicht nötig (AppleScript nur für `do shell script`).
- Skript `scripts/release.sh`: Archivieren, Developer-ID-Export, `notarytool submit --wait`, `stapler staple`, DMG erzeugen. Notarisierungs-Zugangsdaten via `notarytool store-credentials` im Schlüsselbund (nie im Repo).

## 10. Teilprojekte
1. **Fundament + Speicher + Entwickler** (dieses Dokument)
2. Systemdaten erklären (Briefing Abschnitt 5)
3. Automatischer Check + Wachstumswächter + Migration der alten Agents (`com.frankjuchim.cleanup`, `de.bodendiek.klarschiff.check`) + Menüleisten-Frage + Schwellen
4. Hintergrunddienste-Tab
5. Leistungs-Tab (inkl. Spotlight entlasten)
