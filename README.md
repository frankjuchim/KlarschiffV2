# Klarschiff 2

macOS-App (macOS 26), die Speicherfresser findet und sicher entfernt. Sie zeigt zuerst, was Platz belegt und warum,
und räumt nur auf, was du ausdrücklich auswählst. Papierkorb vor Löschen, Sicherheitsprüfung vor jedem Pfad,
Trockenlauf zum Ausprobieren.

## Aufbau

- `Packages/KlarschiffCore` – Scanner, Katalog, Entfernen, Sicherheitslogik (Swift Package)
- `App` – SwiftUI-App; das Xcode-Projekt wird aus `project.yml` erzeugt

Die gebaute App heißt `Klarschiff 2.app` (Anzeigename „Klarschiff 2“, Bundle-ID `de.frankjuchim.klarschiff2`);
Target, Scheme und Swift-Modul heißen weiter `Klarschiff`.

## Bauen

```sh
xcodegen generate
open Klarschiff.xcodeproj
```

## Tests

```sh
swift test --package-path Packages/KlarschiffCore
xcodegen generate && xcodebuild -scheme Klarschiff -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Optional gibt es einen reinen Lese-Scan gegen den echten Mac (entfernt nichts):

```sh
KLARSCHIFF_LIVE_SCAN=1 KLARSCHIFF_LIVE_SCAN_OUT=/tmp/live-scan.md \
  swift test --package-path Packages/KlarschiffCore --filter LiveScan
```

## Systemdaten

Der Tab „Systemdaten“ erklärt, was auf dem Daten-Volume als „Systemdaten“ Platz belegt: Er misst Systembereiche
(Assets, System-Datenbanken, Systembibliothek, Auslagerung …), „Deine Daten“ und den nicht zugeordneten Rest und
sagt zu jedem Bereich, ob er zu macOS gehört oder aufräumbar ist. Messen ist rein lesend. Aufräumfunde sind nie
vorausgewählt, tragen eine deutliche Warnung und lassen sich erst nach „Ich habe verstanden“ ausführen; Aktionen mit
Administratorrechten fragen genau einmal nach dem Passwort. „Nicht zugeordnet“ ist ein Näherungswert und eher zu hoch,
wenn Bereiche nicht vollständig gemessen werden konnten (z. B. ohne vollen Festplattenzugriff). Die Messung auf dem
echten Mac gibt es als Opt-in-Test:

```sh
KLARSCHIFF_LIVE_SCAN=1 KLARSCHIFF_LIVE_SCAN_OUT=/tmp/systemdata.md \
  swift test --package-path Packages/KlarschiffCore --filter liveSystemData
```

## Automatischer Check

Optional prüft Klarschiff 2 im Hintergrund (täglich oder wöchentlich, einstellbar unter ⌘,) per LaunchAgent, was sich
aufräumen ließe, speichert das im Verlauf und meldet Auffälligkeiten per Mitteilung. Der Check **löscht nie etwas** und
fragt im Hintergrund nie nach Rechten; aufgeräumt wird nur in der App, wenn du es auswählst. Von Hand:
`"Klarschiff 2.app/Contents/MacOS/Klarschiff 2" --check`. Eine Migrationskarte erkennt die alte Aufräum-Automatik
(zwei Agents, `cleanup.sh` samt Protokollen) und entfernt sie erst nach deiner Bestätigung.

## Hintergrunddienste

Der Tab „Hintergrunddienste“ listet LaunchAgents und -Daemons (ohne Apple) aus `~/Library/LaunchAgents`,
`/Library/LaunchAgents` und `/Library/LaunchDaemons` sowie Anmeldeobjekte, erklärt sie mit Bereich, Startart und
„läuft gerade“ und erkennt **verwaiste** Dienste, deren Programm oder App fehlt. Nur diese lassen sich nach Bestätigung
entfernen (Benutzerdienste per `launchctl bootout` und Papierkorb, Einträge unter `/Library` mit einer Passwortabfrage);
alle anderen Dienste und Anmeldeobjekte werden nur erklärt. Livetest: `KLARSCHIFF_LIVE_SCAN=1 swift test --package-path Packages/KlarschiffCore --filter liveServices`.

## Leistung

Der Tab „Leistung“ zeigt live Prozessor, Arbeitsspeicher (mit Speicherdruck), Auslagerung und Laufzeit in Kacheln
und darunter die zwölf aktivsten Apps (Prozesse gebündelt, RAM, CPU mit Verlauf). Reguläre Apps lassen sich mit
„Beenden“ freundlich schließen (nie Finder, Klarschiff 2 oder Systemdienste). Dazu erkennt er Bremser und schlägt große
Projektordner (`node_modules`, `.build` …) vor, die Spotlight unnötig durchsucht. Alles lesend, nichts passiert automatisch.
Livetest: `KLARSCHIFF_LIVE_SCAN=1 swift test --package-path Packages/KlarschiffCore --filter livePerformance`.

## Trockenlauf

Im Trockenlauf läuft alles wie gewohnt, es wird aber nichts entfernt. Er ist aktiv, wenn die App mit dem
Argument `--dry-run` (oder `KLARSCHIFF_DRY_RUN=1`) startet oder wenn im Menü „Entwickler“ der Schalter
„Trockenlauf“ an ist (bleibt gespeichert). Solange er aktiv ist, zeigt der Kopfbereich „Trockenlauf aktiv“.

**Entwickeln:** Ein Start aus Xcode ist immer ein Trockenlauf – das Scheme übergibt beim Run `--dry-run`, der
Schalter lässt sich dann nicht ausschalten. Für einen echten Lauf die gebaute App aus dem Finder starten.

## Release

Einmalig einrichten:

1. `Config/Local.xcconfig` anlegen (wird nicht eingecheckt) mit
   `DEVELOPMENT_TEAM = <TeamID>`
   (Vorlage: `Config/Local.xcconfig.example`).
2. Notarisierungs-Zugang im Schlüsselbund ablegen:
   ```sh
   xcrun notarytool store-credentials klarschiff-notary
   ```
3. Sparkle-Schlüssel: liegt im Schlüsselbund (angelegt am 30.10.2026 mit `generate_keys`), der öffentliche
   Schlüssel steht in `Config/Klarschiff-Info.plist`. **Sichern**, sonst lassen sich keine Updates mehr signieren:
   `generate_keys -x <Datei>` (Werkzeug unter `build/SourcePackages/artifacts/sparkle/Sparkle/bin/` nach dem
   ersten Release) und die Datei an einem sicheren Ort ablegen.

Vor jedem Release in `project.yml` `MARKETING_VERSION` (z. B. 0.2.0) und `CURRENT_PROJECT_VERSION` (z. B. 2)
erhöhen – Sparkle erkennt ein Update an der höheren `CURRENT_PROJECT_VERSION`. Dann:

```sh
scripts/release.sh
```

Das Skript erzeugt das Projekt, archiviert, exportiert (Developer ID), notarisiert, heftet das Ticket an,
legt `build/Klarschiff-2-<Version>.dmg` ab (darin `Klarschiff 2.app` und eine Verknüpfung zu Programme),
signiert die DMG für Sparkle und gibt am Ende den Befehl für das Website-Repository aus
(`node scripts/klarschiff-release.mjs … --build … --signature …`).

## Updates

Sparkle prüft einmal täglich `https://frankjuchim.de/download/klarschiff/appcast.xml` (fragt beim zweiten Start,
ob automatisch gesucht werden darf). Von Hand: App-Menü → „Nach Updates suchen …“ oder Einstellungen → Updates.
Der Feed wird von der Website aus deren `src/data/klarschiff.json` erzeugt; die Adressen nicht ohne Rückfrage ändern.
