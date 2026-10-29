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

Dann:

```sh
scripts/release.sh
```

Das Skript erzeugt das Projekt, archiviert, exportiert (Developer ID), notarisiert, heftet das Ticket an und
legt `build/Klarschiff-2-<Version>.dmg` (darin `Klarschiff 2.app`) ab. Die Version stammt aus `MARKETING_VERSION` in `project.yml`.
