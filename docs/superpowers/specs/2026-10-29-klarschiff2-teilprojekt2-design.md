# Klarschiff 2 – Teilprojekt 2: Systemdaten erklären und aufräumen

**Stand:** 29.10.2026 · **Grundlage:** `docs/Briefing.md` Abschnitt 5, Spec Teilprojekt 1 (§3, §7, §10)
**Status:** Design im Brainstorming mit Frank abgestimmt (29.10.2026); diese Spec wartet auf Abnahme.

---

## 1. Ziel und Erfolgskriterium

Der Tab **„Systemdaten“** erklärt, woraus der große Posten „Systemdaten“ der Systemeinstellungen besteht (am 28.10.2026: ~294 GB und eigentliche Ursache der vollen Platte), und bietet für die sicher wieder aufbaubaren Teile **Aufräum-Aktionen mit deutlichen Warnungen** an.

**Abnahme:** Auf Franks Mac zeigt der Tab nach dem Messen
- den ganzen Datenträger als gestapelten Balken (Volumes + Aufteilung des Daten-Volumes),
- mindestens 90 % des belegten Daten-Volumes einem benannten Bereich zugeordnet, den Rest ehrlich als „Schnappschüsse & nicht zuordenbar“,
- jeden Bereich mit Klarname, Erklärung und Einstufung,
- die vier Aufräum-Aktionen aus §5, die im Trockenlauf durchlaufen und im echten Lauf nur nach rotem Warnhinweis + Bestätigungshäkchen ausgeführt werden.

## 2. Entscheidungen (Brainstorming 29.10.2026)

| Frage | Entscheidung |
|---|---|
| Nur erklären oder auch aufräumen? | **Auch aufräumen**, mit deutlichen Hinweisen und Warnmeldungen. |
| Reichweite der Aktionen | **Auch mit Admin, aber nur Caches, Protokolle, Diagnosedaten** (keine tieferen Bereiche unter `/private/var/db`, kein manuelles Löschen in AssetsV2). |
| Wann wird gemessen? | **Beim ersten Öffnen des Tabs, danach auf Knopfdruck** („Neu messen“); der normale Scan bleibt unverändert schnell. |
| Rechenansatz | **Volumen-Sicht von oben nach unten** (APFS-Volumes → Daten-Volume → Bereiche; Rest = Belegt − Gemessenes). Kein Nachbau der macOS-Zahl. |

Nicht löschbar und daher **nur Hinweis**: Update-Schnappschüsse (von macOS geschützt), Swap/Ruhezustand (`/private/var/vm`), AssetsV2 (wird von macOS verwaltet; Simulatoren nur über `simctl`, siehe TP1), heruntergeladenes macOS-Update.

## 3. Messung (KlarschiffCore, Ordner `SystemData/`)

### 3.1 VolumeInventory
- `diskutil apfs list -plist` über den `CommandRunner` (Timeout 30 s), kein Admin.
- Liefert den Container des Startvolumes (Gesamtgröße, frei) und seine Volumes mit Rolle (`System`, `Preboot`, `Recovery`, `VM`, `Data`, sonstige z. B. Simulator-Volumes `iOS 27.0 Simulator`), Name und „Capacity Consumed“.
- Volumes anderer Container (z. B. gemountete Simulator-Disk-Images) werden als „Simulator-Volumes“ zusammengefasst, wenn ihr Name auf „Simulator“ endet; sonst ignoriert.
- Fehler/Timeout → Bericht ohne Volumen-Aufteilung, Hinweis „Datenträger konnte nicht gelesen werden“; die Bereichsmessung läuft trotzdem.

### 3.2 SystemAreaCatalog (deklarativ)
Jeder Eintrag: `id`, Pfad (über `ScanContext.absolute`), Klarname, Erklärung (Du-Form), Einstufung `.keep` („Gehört zu macOS – behalten“) / `.cleanable` („Aufräumbar“) / `.seeFinding(scannerID)` („Siehe Fund“), optionale Unterbereiche.

Erste Fassung:
| id | Pfad | Klarname | Einstufung |
|---|---|---|---|
| `var.folders.caches` | `/private/var/folders/*/*/C` | Benutzer-Caches (System) | `.keep`; Erklärung nennt, dass Instruments-/Clang-Caches daraus als Funde im Tab Entwickler erscheinen (Knopf „Im Tab Entwickler zeigen“) |
| `var.folders.temp` | `/private/var/folders/*/*/T` | Temporäre Dateien | `.cleanable` (eigener `T/`, §5) |
| `var.folders.other` | Rest von `/private/var/folders` | Sonstige Systemordner | `.keep` |
| `var.vm` | `/private/var/vm` | Auslagerung & Ruhezustand | `.keep` (Hinweis: wird beim Neustart kleiner) |
| `var.db.diagnostics` | `/private/var/db/diagnostics` + `/private/var/db/uuidtext` | Diagnosedaten (Systemprotokoll) | `.cleanable` (§5) |
| `var.db.other` | Rest von `/private/var/db` | System-Datenbanken | `.keep` |
| `library.caches` | `/Library/Caches` | Systemweite Caches | `.cleanable` (§5) |
| `library.logs` | `/Library/Logs` | System-Protokolle | `.cleanable` (§5) |
| `library.other` | Rest von `/Library` | Systemweite Einstellungen & Komponenten | `.keep` |
| `assets` | `/System/Volumes/Data/System/Library/AssetsV2` | macOS-Komponenten (Assets) | Unterbereiche je Asset-Typ (§3.3) |
| `developer` | `/Library/Developer` | Entwicklerwerkzeuge | `.seeFinding("developer.libraryBreakdown")` |
| `opt` | `/opt` | Zusatzsoftware (z. B. Homebrew, Anaconda) | `.seeFinding` (Homebrew/Conda) |
| `usrlocal` | `/usr/local` | Zusatzsoftware (`/usr/local`) | `.seeFinding("toolchains.texlive")` wenn TeX Live vorhanden, sonst `.keep` |

„Rest von X“ = Größe von X minus Summe seiner benannten Unterbereiche (mindestens 0).

### 3.3 AssetNameMap
Ordnet `com_apple_MobileAsset_<Typ>` Klarnamen + Einstufung zu, z. B.:
- `iOSSimulatorRuntime`, `appleTVOSSimulatorRuntime`, `watchOSSimulatorRuntime`, `xrOSSimulatorRuntime` → „iOS-/tvOS-/watchOS-/visionOS-Simulator“ → `.seeFinding("sim.runtimes")`
- `MacSoftwareUpdate`, `MacSplatSoftwareUpdate` → „Heruntergeladenes macOS-Update“ → `.keep` mit Hinweis (§5)
- `UAF_Siri_*`, `LinguisticData*`, `DictionaryServices_*`, `Font*`, `MacinTalkVoiceAssets`, `DesktopPicture` → passende Klarnamen („Siri-Sprachdaten“, „Wörterbücher“, „Schriften“, „Stimmen“, „Hintergrundbilder“) → `.keep`
- `AppleDeveloperDocumentation`, `MetalToolchain` → „Xcode-Dokumentation“, „Metal-Werkzeuge“ → `.keep` mit Hinweis „über Xcode verwalten“
- Unbekannt → Rohname ohne Präfix, „Systemkomponente“, `.keep`.

### 3.4 SystemDataScanner und Bericht
- Misst alle Katalogbereiche parallel mit dem vorhandenen `SizeMeter` (Timeout je Bereich 120 s, abbrechbar). Gesperrte Unterordner werden übersprungen; dann `isLowerBound = true` („mindestens“).
- Misst „Deine Daten“ = Home-Ordner + `/Applications` (eigene Messung, nicht abhängig vom Speicher-Scan).
- `SystemDataReport`: Volumes, Bereichsbaum (`SystemArea` mit Größe, `isLowerBound`, Unterbereichen), Summen `userData`, `systemAreas`, `unaccounted` = Daten-Volume belegt − `userData` − `systemAreas` (min. 0), Schnappschuss-Liste aus `tmutil listlocalsnapshots /` (Wiederverwendung des TP1-Parsers), Zeitpunkt, Fehlerliste, sowie die **Aufräum-Funde** aus §5.
- Alle Pfade aus `ScanContext` → Tests gegen Fixture-Bäume; `diskutil`-Ausgabe als aufgezeichnete Fixture von Franks Mac.

## 4. Darstellung (Tab „Systemdaten“, ersetzt den Platzhalter)

1. **Kopfkarte:** gestapelter Balken über den Datenträger mit Segmenten *macOS-System* (System+Preboot+Recovery), *Auslagerung (VM)*, *Deine Daten*, *Systembereiche*, *Schnappschüsse & nicht zuordenbar*, *Simulator-Volumes*, *Frei*; Legende mit Größen (`ByteFormat`). Erklärsatz: „Die Zahl ‚Systemdaten‘ in den Systemeinstellungen entspricht ungefähr Systembereiche + Schnappschüsse + Auslagerung. macOS rechnet etwas anders – kleine Abweichungen sind normal.“ Knopf **„Neu messen“** (Fortschritt während der Messung, „Gemessen um HH:MM“).
2. **Schnappschuss-Karte** (wenn Schnappschüsse existieren oder `unaccounted` > 5 GB): erklärt Update- und Time-Machine-Schnappschüsse; Update → Knopf „Softwareupdate öffnen“; Time Machine → „Im Tab Speicher zeigen“.
3. **Bereichsliste** (sortiert nach Größe): Karte je Bereich mit Klarname, Größe bzw. „mindestens …“, Einstufungspille (grau „Gehört zu macOS – behalten“, grün „Aufräumbar“, blau „Siehe Fund“), Erklärung, Lupe (im Finder zeigen); aufklappbar bei Unterbereichen. „Siehe Fund“ → Knopf „Im Tab Entwickler zeigen“ bzw. „Im Tab Speicher zeigen“ (wechselt den Tab).
4. **Aufräum-Karten** (§5) innerhalb der grünen Bereiche, im Stil der TP1-Fundkarten (Auswahlkreis, Größe, „Befehl anzeigen“), zusätzlich mit **roter Warnzeile**.
5. Zusammenfassungsleiste unten: ausgewählte Größe + Knopf „Aufräumen“ (öffnet den bekannten Bestätigungsdialog).
6. **Ohne Vollzugriff:** Onboarding-Karte oben; betroffene Bereiche „mindestens …“.
7. Erste Messung automatisch beim ersten Öffnen des Tabs pro App-Start; danach nur über „Neu messen“ oder nach einem Aufräumlauf in diesem Tab.

## 5. Aufräum-Aktionen

Neue Kategorie `systemData` (Tab `.systemData`, Titel „Systemdaten“, Symbol `chart.pie`). Alle Funde Risiko **`.review`**, **nie vorausgewählt**.

| Fund (scannerID) | Was | Methode | Admin | Warnzeile |
|---|---|---|---|---|
| Alte temporäre Dateien (`sysdata.temp`) | Einträge in **deinem eigenen** `T/`-Ordner (`FileManager.temporaryDirectory` bzw. `DARWIN_USER_TEMP_DIR`), deren Änderungsdatum älter als **3 Tage** ist (oberste Ebene, Ordner als Ganzes nur wenn alles darin älter ist) | `.delete` | nein | „Laufende Programme legen hier Arbeitsdateien ab. Nur Einträge älter als 3 Tage werden entfernt.“ |
| Systemweite Caches (`sysdata.libraryCaches`) | Kinder von `/Library/Caches`, ausgenommen `com.apple.iconservices.store`, `com.apple.aned`, `com.apple.amsengagementd.classicdatavault` und alles, was SafetyGuard sperrt | `.admin`: `/bin/rm -rf <kind>` je Kind | ja | „macOS und Apps bauen diese Caches neu auf. Der erste Start einiger Apps dauert danach länger – ein Neustart wird empfohlen.“ |
| Alte System-Protokolle (`sysdata.libraryLogs`) | Dateien unter `/Library/Logs/**` (inkl. `DiagnosticReports`) älter als **30 Tage** | `.admin`: `/bin/rm -f <datei>` je Datei | ja | „Alte Protokolle helfen bei der Fehlersuche. Danach sind sie weg.“ |
| Diagnosedaten (`sysdata.unifiedLog`) | `/private/var/db/diagnostics` + `/private/var/db/uuidtext` (Größe zur Info) | `.admin`: `/usr/bin/log erase --all` | ja | „Das komplette Systemprotokoll wird gelöscht. Für die Fehlersuche bei Problemen der letzten Tage fehlt es danach.“ |
| Heruntergeladenes macOS-Update | AssetsV2 `MacSoftwareUpdate*` | **`.hint(.openURL(Softwareupdate))`** | – | „Installiere das Update oder warte – macOS räumt die Datei selbst weg.“ |

**Bestätigung:** Enthält ein Plan Funde der Kategorie `systemData`, zeigt der Bestätigungsdialog eine **rote Warnkarte** („Du entfernst Systemdateien“ + Liste der Warnzeilen) und ein Kontrollkästchen **„Ich habe verstanden, dass Systemdateien entfernt werden.“** Ohne Haken ist „Aufräumen“ gesperrt; einen Return-Shortcut gibt es in diesem Fall nie. Alle Admin-Schritte eines Laufs → **eine** Passwortabfrage (TP1).

Ablauf und Ergebnis wie TP1 (`RemovalPlan`/`RemovalRunner`, Trockenlauf, Ergebnis-Banner mit Trockenlauf-Kennzeichnung je Lauf); danach neue Messung des Tabs.

## 6. Sicherheit (Änderungen an TP1, verbindlich)

- **SafetyGuard** – zusätzlich erlaubt (gleich oder darunter):
  - Kinder von `/Library/Caches` und `/Library/Logs` (nicht die Ordner selbst),
  - Inhalt des **eigenen** Temp-Ordners `DARWIN_USER_TEMP_DIR` (= `/private/var/folders/<a>/<b>/T`), nie der Ordner selbst, nie fremde `T/`-Ordner; Konstruktor bekommt `userTempDir` analog zu `userCacheDir` (gleiche Validierung).
  - Alles andere unter `/private/var` bleibt gesperrt; AssetsV2, `/System`, Caskroom/Cellar unverändert gesperrt.
- **Admin-Allow-Liste** – zusätzlich genau `["/usr/bin/log", ["erase", "--all"]]`; `/bin/rm`-Operanden weiter vollständig vom Guard geprüft (die neuen Ziele sind dadurch erlaubt).
- **Kein neuer Weg an SafetyGuard vorbei:** die neuen Funde laufen ausschließlich über `DeleteRemover`/`AdminRemover`.
- Nichts in `/private/var/db` außer über `log erase`; nichts in AssetsV2.
- Trockenlauf wirkt wie in TP1 auf alle neuen Funde.

## 7. Fehlerbehandlung

- `diskutil`/`tmutil` scheitert → Teilbericht mit Hinweis, Rest läuft.
- Bereich nicht messbar (Timeout/gesperrt) → „mindestens …“ bzw. „konnte nicht gemessen werden“.
- Aufräumen: Fehler je Eintrag im Ergebnis-Banner; abgebrochene Passwortabfrage → Admin-Schritte „abgebrochen“, Temp-Dateien-Löschung bleibt gültig.
- `log erase` liefert ≠ 0 → Fehler mit gekürztem stderr.

## 8. Tests

- `VolumeInventory`: aufgezeichnete `diskutil apfs list -plist`-Ausgabe von Franks Mac (Fixture), Rollen/Größen/Simulator-Volumes; Fehlerfall.
- `SystemDataScanner`: Fixture-Baum mit `/private/var/folders/x/y/{C,T}`, `/private/var/db/diagnostics`, `/Library/Caches`, `/Library/Logs`, AssetsV2-Typen; Summen, „Rest von“, `isLowerBound`, `unaccounted ≥ 0`.
- `AssetNameMap`: bekannte und unbekannte Typen.
- Aufräum-Funde: Altersgrenzen (Temp 3 Tage, Logs 30 Tage), Ausnahmen in `/Library/Caches`, AdminSteps exakt, Hinweis-Fund ohne Auswahl.
- SafetyGuard: neue Erlaubnisse (Kind von `/Library/Caches` erlaubt, `/Library/Caches` selbst verweigert, eigener `T/`-Inhalt erlaubt, `T/` selbst und fremdes `T/` verweigert, Symlink aus `T/` nach `~/Documents` verweigert).
- AdminRemover: `log erase --all` erlaubt, `log erase` ohne `--all` / `log show` verweigert.
- App: Bestätigungsdialog sperrt „Aufräumen“ ohne Haken bei `systemData`-Funden, kein Default-Shortcut; Messung beim ersten Tab-Öffnen genau einmal.
- Opt-in Live-Messung (wie TP1 `KLARSCHIFF_LIVE_SCAN`) für die Abnahme auf Franks Mac.

## 9. Nicht Teil von Teilprojekt 2

Größe einzelner Update-Schnappschüsse (APFS liefert sie ohne Admin nicht zuverlässig – wir zeigen nur die Differenz), Löschen in AssetsV2, `/private/var/db` außer Unified Log, Automatik/Wachstumswächter (TP3).
