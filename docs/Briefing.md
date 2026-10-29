# Klarschiff 2 – Übergabe-Briefing für Claude Code

> **Zweck dieses Dokuments:** Ausgangslage für den Neubau der macOS-App *Klarschiff* (privates Projekt von Frank Juchim). Es fasst zusammen, was Klarschiff 1 kann, was eine manuelle Aufräumaktion am 28./29.10.2026 zusätzlich gefunden hat, und welche Stolperfallen dabei aufgetreten sind.
> **Status:** Anforderungsgrundlage, noch **kein** abgesegneter Entwurf. In Claude Code zuerst mit `superpowers:brainstorming` einen Entwurf/Spec daraus machen, dann Plan, dann Umsetzung.
> **Quellcode von Klarschiff 1 existiert nicht mehr** – nur die gebaute App unter `/Applications`. Klarschiff 2 ist ein Neubau, der Klarschiff 1 vollständig ersetzt.

---

## 1. Ausgangslage und Ziel

Am 28.10.2026 war die SSD (494 GB) fast voll: **nur ~12 GB frei**, davon **~294 GB „Systemdaten“**. Klarschiff 1 hatte an diesem Tag nur **12,33 GB** Aufräumbares gefunden (davon 11,99 GB Cowork-VM). Manuell mit Terminal-Befehlen wurden anschließend **rund 145 GB** freigegeben (157 GB frei am Ende), weitere ~30–40 GB sind identifiziert.

**Ziel von Klarschiff 2:** Alles, was in dieser Aktion von Hand gefunden wurde, soll die App selbst finden, verständlich erklären und **sicher** entfernen können – und dabei alle Funktionen von Klarschiff 1 behalten.

**Erfolgskriterium:** Auf einem Mac im Zustand vom 28.10.2026 hätte Klarschiff 2 die Instruments-Caches, Simulator-Runtimes, Update-Snapshots, das Flutter-SDK, TeX Live und die Gradle/Android-Reste gefunden, korrekt bewertet und mit dem jeweils richtigen Werkzeug entfernt.

---

## 2. Bestand Klarschiff 1 (aus Screenshots, muss erhalten bleiben)

Screenshots: siehe `docs/screenshots/`.

### Aufbau und Optik
- Header: Wortmarke „Klarschiff“ (Verlauf Türkis → Violett), Untertitel „Speicher aufräumen – KI-Reste, Caches und Liegengebliebenes.“
- Rechts oben Kapazitätskarte: „226,32 GB frei“, Balken, „von 494,38 GB“.
- Drei Tabs: **Speicher**, **Hintergrunddienste**, **Leistung**.
- Glas-/Blur-Optik, weiche Pastell-Verläufe im Hintergrund, große Kennzahl in einer Zusammenfassungskarte, Listenkarten mit Auswahlkreis links und Größe rechts.

### Tab „Speicher“
- Zusammenfassung: ausgewählte Größe groß, „ausgewählt von X GB gefunden“, Buttons **Neu scannen** und **Aufräumen**, separat **Papierkorb leeren (Größe)**.
- Regel im UI-Text: „Vorausgewählt ist nur, was sich von selbst wieder aufbaut. Alles landet zuerst im Papierkorb.“
- Kategorien mit Summe je Kategorie:
  - **KI-Reste:** Claude Desktop – Cache (Sicher), Claude Cowork – VM-Abbild (~12 GB, Prüfen).
  - **Entwickler:** Homebrew-Downloads (Sicher).
  - **App-Caches:** Telegram-Medien-Cache (Prüfen), Caches von App-Store-Apps (Sicher), Sonstige App-Caches (Sicher).
- Je Eintrag: Titel, Risiko-Label **Sicher** (grün) / **Prüfen** (rot), Warnung „App läuft – vorher beenden“, Kurzbeschreibung, Größe, Anzahl Einträge, aufklappbar.
- **Große Brocken:** Ordner über 1 GB als Balkenliste mit Lupe (im Finder zeigen). Hinweis: Klarschiff löscht dort nichts, Aufräumen in der jeweiligen App. Markiert, wie viel davon oben aufräumbar ist („davon 12,04 GB oben aufräumbar“).

### Tab „Hintergrunddienste“
- Kennzahl: Anzahl **verwaister** Hintergrunddienste (deren App gelöscht ist), Buttons **Neu prüfen** / **Entfernen**.
- Liste „Aktiv“ aller LaunchAgents/-Daemons und Anmeldeobjekte: Name, Bereich (**Benutzer** / **Alle Benutzer** / **System** / **Anmeldeobjekt**), „App ist installiert.“, Label, Startart („startet bei Bedarf“ / „startet bei der Anmeldung“), Status „läuft gerade“, Lupe.
- Auffällig in der Liste: `com.frankjuchim.cleanup` und `de.bodendiek.klarschiff.check` – Agents von Klarschiff 1 bzw. einem Vorgänger. **Klarschiff 2 muss diese beim ersten Start migrieren bzw. sauber entfernen.**

### Tab „Leistung“
- Kacheln: Prozessor (% + Sparkline, „kühl“), Arbeitsspeicher (GB von 16 GB, „entspannt“), Ausgelagert (Swap), Seit Neustart („frisch genug“).
- „Was bremst gerade?“ – Hinweise erst, wenn etwas über Minuten auffällt.
- „Aktivste Apps & Dienste“: Name, Prozessanzahl, RAM, Sparkline, CPU-%, Schloss bei Systemprozessen, Beenden-Button (x) bei Benutzer-Apps.
- „Spotlight entlasten“: findet Projektordner (z. B. `node_modules`), die Spotlight unnötig indiziert.
- Bewusster Verzicht, im UI erklärt: kein „RAM freigeben“, kein Dauer-Cache-Leeren.

### Automatischer Check
- Aus / Wöchentlich (sonntags 10 Uhr) / Monatlich (Monatserster 10 Uhr), „Jetzt prüfen“.
- Meldet sich nur, wenn es sich lohnt: ab 1 GB, neue verwaiste Dienste oder knapper Speicher. **Löscht nie automatisch.**
- Verlauf mit Datum und gefundener Größe; Statuszeile „Letzter Check vor X Minuten: …“.

---

## 3. Was Klarschiff 1 übersehen hat (Messwerte 28./29.10.2026)

| Fund | Größe | Wo | Richtige Entfernung |
|---|---|---|---|
| Xcode-Instruments-Caches | **65 GB + 37 GB** | `$(getconf DARWIN_USER_CACHE_DIR)/com.apple.dt.Instruments` und `…/com.apple.dt.InstrumentsCLI` | Ordner löschen, wenn Xcode/Instruments nicht läuft. Baut sich bei Bedarf neu auf. |
| Snapshots von macOS-Updates | Großteil von ~145 GB, die `du` nicht sah | `tmutil listlocalsnapshots /` → `com.apple.os.update-*`, `…MSUPrepareUpdate` | Nicht direkt löschbar. Hinweis: ausstehendes Update installieren und neu starten. Danach waren sie weg. |
| iOS-Simulator-Runtimes (4 Versionen) | 32 GB | `/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime` | `xcrun simctl runtime list` / `xcrun simctl runtime delete <ID>`. **Nie** AssetsV2 direkt anfassen. |
| visionOS-, watchOS-, tvOS-Runtimes | 6,8 + 3,7 + 3,5 GB | wie oben (`xrOS…`, `watchOS…`, `appleTVOS…`) | wie oben |
| Flutter-SDK | 3,7 GB | `/opt/homebrew/Caskroom/flutter` | `brew uninstall --cask flutter`, danach `~/.pub-cache`, `~/.dart-tool`, `~/.flutter` |
| TeX Live 2022 (veraltet) | 7,5 GB | `/usr/local/texlive/2022` | Alte Jahrgänge löschen; ganz: `/usr/local/texlive`, `/Library/TeX`, `/Applications/TeX` (Admin). Alternative BasicTeX. |
| Gradle / Android | 1,9 GB + 0,5 GB | `~/.gradle`, `~/.android` | Ordner löschen, wenn keine Android-Entwicklung mehr |
| Homebrew-Altlasten | 211 MB | alte `portable-ruby`-Versionen u. a. | `brew cleanup --prune=all`, `brew autoremove` |
| Xcode-Daten allgemein | 22 GB + 20 GB | `~/Library/Developer`, `/Library/Developer` | aufschlüsseln: DerivedData, Archives, DeviceSupport, Previews, CoreSimulator |
| Arduino-Toolchains | 7,2 GB | `~/Library/Arduino15` | Prüfen (nur Hinweis bzw. Board-Pakete einzeln) |
| Anaconda | 6,8 GB | `/opt/anaconda3` | Prüfen; `conda clean --all` für Paket-Caches |

**Verlauf „Systemdaten“ (Systemeinstellungen):** 293,7 → 292,3 → 259,9 (nach Update) → **149,3 GB** (nach Instruments). Bereich „macOS“: 46,9 → 28,7 GB nach dem Update.
**Freier Speicher (`df -h /System/Volumes/Data`):** ~12 GB → 54 GB (Update) → **157 GB** (Instruments).

---

## 4. Scanner-Katalog für Klarschiff 2

Jeder Scanner liefert: Titel, Kategorie, Beschreibung in Alltagssprache, Größe, Einträge, **Risikostufe**, Vorbedingungen (z. B. „App läuft“), **Entfernungsmethode** und den **exakten Befehl/Pfad zum Anzeigen**.

**Risikostufen:**
- **Sicher:** baut sich von selbst wieder auf, darf vorausgewählt sein.
- **Prüfen:** kostet Neu-Download oder Neu-Einrichtung, nie vorausgewählt.
- **Nur Hinweis:** Klarschiff erklärt und verweist auf das richtige Werkzeug, löscht selbst nicht.

**Entfernungsmethoden:**
- `trash`: in den Papierkorb.
- `delete`: direkt löschen, nur für große Caches mit Bestätigung, weil der Papierkorb bei 100 GB keinen Platz schafft.
- `tool`: offizielles Werkzeug (`simctl`, `brew`, `conda`, `npm` …).
- `admin`: Admin-Rechte nötig.
- `hint`: nur Hinweis.

### 4.1 System und macOS (neu)
| Scanner | Erkennung | Stufe | Methode |
|---|---|---|---|
| Update-Snapshots | `tmutil listlocalsnapshots /` enthält `com.apple.os.update` | Nur Hinweis | Hinweis „Update installieren + Neustart“, Link zu Softwareupdate |
| Time-Machine-Snapshots | `com.apple.TimeMachine.*` in obiger Liste | Prüfen | `tmutil deletelocalsnapshots <Datum>` (ggf. admin) |
| Ausstehendes Softwareupdate | `softwareupdate -l` bzw. Update-Hinweis | Nur Hinweis | Hinweis |
| Benutzer-Cache-Ordner gesamt | `getconf DARWIN_USER_CACHE_DIR`, Unterordner nach Größe | je Unterordner | siehe 4.2 |
| Papierkorb | `~/.Trash` | Prüfen | Papierkorb leeren (nur nach Bestätigung) |

### 4.2 Xcode und Apple-Entwicklerwerkzeuge (stark erweitert)
| Scanner | Pfad / Befehl | Stufe | Methode |
|---|---|---|---|
| Instruments-Caches | `$DARWIN_USER_CACHE_DIR/com.apple.dt.Instruments*` | Sicher | `delete` (Xcode/Instruments beendet) |
| Clang-Modul-Cache | `$DARWIN_USER_CACHE_DIR/clang` | Sicher | `delete` |
| DerivedData | `~/Library/Developer/Xcode/DerivedData` | Sicher | `delete` |
| Simulator-Runtimes | `xcrun simctl runtime list -j` | Prüfen (neueste iOS-Version: Behalten-Vorschlag) | `xcrun simctl runtime delete <ID>` |
| Nicht verfügbare Simulatoren | `xcrun simctl list devices unavailable` | Sicher | `xcrun simctl delete unavailable` |
| Device-Support-Dateien | `~/Library/Developer/Xcode/*DeviceSupport` | Sicher (alte iOS-Versionen) | `trash` |
| Archives | `~/Library/Developer/Xcode/Archives` | Prüfen (für App-Store-Builds evtl. wichtig) | `trash` |
| SwiftUI-Previews | `~/Library/Developer/Xcode/UserData/Previews` | Sicher | `delete` |
| CoreSimulator-Caches | `~/Library/Developer/CoreSimulator/Caches` | Sicher | `delete` |
| SwiftPM-Caches | `~/Library/Caches/org.swift.swiftpm`, `~/.swiftpm` | Sicher | `delete` |
| CocoaPods-Cache | `~/Library/Caches/CocoaPods` | Sicher | `delete` |

**Wachstumswächter:** Die Instruments-Caches sind über Monate unbemerkt auf 102 GB gewachsen. Klarschiff 2 soll die Größe beim automatischen Check mitschreiben und melden, wenn sie zwischen zwei Checks stark wächst.

### 4.3 Paketmanager und Toolchains (neu)
| Scanner | Erkennung | Stufe | Methode |
|---|---|---|---|
| Homebrew-Aufräumen | `brew cleanup --prune=all -n`, `brew autoremove -n` | Sicher | `brew cleanup --prune=all`, `brew autoremove` |
| Homebrew-Casks nach Größe | `du -sh /opt/homebrew/Caskroom/*` + `brew list --cask` | Prüfen | `brew uninstall [--zap] --cask <name>`, **nie `rm`** |
| Untrusted Taps | Fehlermeldung „untrusted tap“ beim Deinstallieren | Hinweis | `brew trust <tap>` erklären, dann deinstallieren, dann `brew untap` |
| Flutter/Dart | `~/.pub-cache`, `~/.dart-tool`, `~/.dartServer`, `~/.flutter` | Prüfen | `trash` |
| Gradle | `~/.gradle` (v. a. `caches`, `wrapper/dists`) | Prüfen | `trash` |
| Android | `~/.android` (AVDs), `~/Library/Android/sdk` | Prüfen | `trash` bzw. Cask |
| TeX Live | `ls /usr/local/texlive` → Jahresordner; mehrere = alte löschen | Prüfen | `admin`; ganz entfernen inkl. `/Library/TeX`, `/Applications/TeX` |
| Conda/Anaconda | `/opt/anaconda3`, `~/.conda/pkgs` | Prüfen | `conda clean --all` (`tool`) |
| npm | `~/.npm/_cacache` | Sicher | `npm cache clean --force` |
| pip | `~/Library/Caches/pip` | Sicher | `delete` |
| Maven | `~/.m2/repository` | Prüfen | `trash` |
| Arduino | `~/Library/Arduino15` (staging, packages) | Prüfen | `staging` Sicher, Board-Pakete Hinweis |
| Docker/VMs | `~/Library/Containers/com.docker.docker/Data/vms`, UTM/Parallels-Bundles | Nur Hinweis | Hinweis |

### 4.4 KI-Reste (aus Klarschiff 1, erweitert)
| Scanner | Pfad | Stufe |
|---|---|---|
| Claude Desktop – Cache | wie in Klarschiff 1 | Sicher (App läuft → beenden) |
| Claude Cowork – VM-Abbild | wie in Klarschiff 1 (~12 GB) | Prüfen |
| Ollama-Modelle | `~/.ollama/models` | Prüfen |
| Hugging Face | `~/.cache/huggingface` | Prüfen |
| LM Studio | `~/.lmstudio`, `~/.cache/lm-studio` | Prüfen |
| Codex/Gemini/Copilot | **nur** Cache-/Log-Unterordner in `~/.codex`, `~/.gemini`, `~/.copilot` – nie Konfiguration oder Zugangsdaten | Sicher/Prüfen |

### 4.5 App-Caches und persönliche Daten (aus Klarschiff 1, erweitert)
- App-Store-App-Caches, sonstige App-Caches, Telegram-Medien-Cache wie gehabt.
- **Neu:** iPhone-/iPad-Backups `~/Library/Application Support/MobileSync/Backup` (Prüfen, Datum + Gerät anzeigen, braucht Vollzugriff auf die Festplatte).
- **Neu:** Mail-Anhänge-Kopien `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` (Sicher).
- **Neu:** Alte Installer in Downloads (`.dmg`, `.pkg`, `.zip` älter als 30 Tage) (Prüfen).

### 4.6 Fotos (nur Erklärung)
Kein Löschen. Karte mit Größe der Mediathek, Anzahl Objekte und Erklärung: „Mac-Speicher optimieren“ greift erst, wenn der Speicher knapp wird. Bei 40.710 Fotos + 3.503 Videos und 31,9 GB arbeitet die Optimierung bereits. Ob iCloud fertig synchronisiert ist, steht unten in der Mediathek.

---

## 5. Neue Ansicht: „Systemdaten erklären“

In der Aktion war die wichtigste Erkenntnis, **woraus** „Systemdaten“ besteht. Klarschiff 2 soll das selbst aufschlüsseln, ohne `sudo` wo möglich:

1. Belegt laut `df` gegen Summe der bekannten Bereiche. Die Differenz ist meist Snapshots.
2. `tmutil listlocalsnapshots /`
3. `/private/var` → `folders` (Benutzer-Caches `C/`, Temp `T/`), `vm` (Swap/Sleepimage), `db`
4. `/System/Volumes/Data/System/Library/AssetsV2` → Asset-Typen mit Klarnamen zuordnen (`…iOSSimulatorRuntime` → „iOS-Simulator“, `…UAF_Siri_Understanding` → „Siri-Sprachdaten (behalten)“ usw.).
5. `/Library/Developer`, `/opt`, `/usr/local`

Darstellung als gestapelter Balken bzw. Baum mit Klarnamen. Jeder Block verlinkt auf den passenden Scanner aus Abschnitt 4 oder ist als „gehört zu macOS, behalten“ markiert.

---

## 6. Sicherheitsregeln und Stolperfallen (verbindlich)

1. **Nie automatisch löschen.** Der automatische Check meldet nur.
2. **Offizielle Werkzeuge vor `rm`:** Simulator-Runtimes nur über `simctl`, Homebrew nur über `brew`, Conda über `conda`. Direktes Löschen in `AssetsV2` oder im Caskroom bringt die Verwaltung durcheinander.
3. **Nie `/private/var/folders` pauschal löschen.** Nur bekannte Unterordner im eigenen `C/` und nur, wenn die zugehörige App nicht läuft.
4. **Papierkorb gegen direktes Löschen:** Der Papierkorb schafft erst nach dem Leeren Platz. Bei sehr großen Caches (über 10 GB) direkt löschen anbieten, mit eindeutiger Bestätigung.
5. **Laufende Apps erkennen** (Xcode, Instruments, Claude, Telegram …) und „vorher beenden“ anzeigen, wie in Klarschiff 1.
6. **Behalten-Liste:** Der Nutzer kann Einträge dauerhaft als „behalten“ markieren (Beispiel: mitmproxy bleibt immer). Sie tauchen dann nicht mehr als Vorschlag auf.
7. **Transparenz:** Für jede Aktion den exakten Befehl bzw. Pfad anzeigen und kopierbar machen („Befehl anzeigen“).
8. **Admin-Aktionen klar kennzeichnen** und gebündelt ausführen, damit nur eine Passwortabfrage nötig ist.
9. **Shell-Fallen:** Keine Kommentare (`#`) in Befehlen, die der Nutzer kopiert. zsh wertet sie standardmäßig nicht als Kommentar.
10. **Neueste Versionen behalten:** Bei Runtimes und TeX Live die neueste Version standardmäßig als „behalten“ vorschlagen.
11. **Zugangsdaten nie anfassen:** In `~/.codex`, `~/.gemini`, `~/.config` usw. nur explizit bekannte Cache-Unterordner.

---

## 7. Technischer Rahmen (Vorschlag, in Claude Code zu entscheiden)

- **SwiftUI, macOS-App, ohne Sandbox**, verteilt per Developer ID oder lokal signiert. Ein App-Store-Vertrieb ist mit diesem Funktionsumfang nicht realistisch.
- **Architektur:** Protokoll `Scanner` (`scan() async -> [Finding]`), Protokoll `Remover` je Methode (`trash`, `delete`, `tool`, `admin`), zentrale `CommandRunner`-Schicht für Shell-Befehle mit Timeout und Logging. Scanner sind unabhängig und einzeln testbar.
- **Größenmessung:** schnelle Ermittlung der belegten Blöcke (wie `du`), parallel, abbrechbar. APFS-Clones und Snapshots beachten (`du` ≠ `df`).
- **Vollzugriff auf die Festplatte** erkennen und Onboarding zeigen, falls er fehlt.
- **Admin-Aktionen:** Entscheidung offen zwischen einem privilegierten Hilfsprogramm (`SMAppService`) und einem einmaligen Autorisierungsdialog pro Aufräumlauf.
- **Hintergrundcheck:** LaunchAgent über `SMAppService` statt eigener plist. Beim ersten Start alte Agents von Klarschiff 1 (`com.frankjuchim.cleanup`, `de.bodendiek.klarschiff.check`) erkennen und entfernen.
- **Tests:** Scanner gegen Fixture-Verzeichnisse (temporäre Ordnerbäume mit Dummy-Dateien). Shell-Werkzeuge über ein Protokoll mocken. Ein Trockenlauf-Modus, der nur auflistet.
- **Sprache:** komplett Deutsch, Tonalität wie Klarschiff 1 (freundlich, erklärend, „frisch genug“, „entspannt“).

---

## 8. Offene Fragen für die Brainstorming-Runde

1. Admin-Aktionen: privilegiertes Hilfsprogramm oder Passwortdialog pro Lauf?
2. Mindestversion von macOS?
3. Neuer Tab „Entwickler“ oder Einordnung in „Speicher“ als Kategorie (wie in Klarschiff 1)?
4. Soll die Ansicht „Systemdaten erklären“ ein eigener Tab sein oder ein Bereich unter „Speicher“?
5. Menüleisten-Icon mit freiem Speicher und Schnellcheck: ja oder nein?
6. Schwellen für den Wachstumswächter (z. B. ein Cache wächst um mehr als 5 GB zwischen zwei Checks)?

---

## 9. Vorgehen in Claude Code

1. Wir arbeiten auf dem Repo KlarschiffV2.
2. Einstieg: „Lies docs/Briefing.md. Wir bauen Klarschiff 2 neu. Starte mit superpowers:brainstorming, kläre die offenen Fragen aus Abschnitt 8, dann Spec, dann Plan.“
3. Die Screenshots von Klarschiff 1 liegen unter `docs/screenshots/` als Design-Referenz.
4. Zum Abnehmen die Messwerte aus Abschnitt 3 als Referenz nutzen: Klarschiff 2 muss die dort genannten Kategorien auf einem vergleichbaren System finden.
