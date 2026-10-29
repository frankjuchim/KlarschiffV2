# Klarschiff 2

macOS-App (macOS 26), die Speicherfresser findet und sicher entfernt. Sie zeigt zuerst, was Platz belegt und warum,
und räumt nur auf, was du ausdrücklich auswählst. Papierkorb vor Löschen, Sicherheitsprüfung vor jedem Pfad,
Trockenlauf zum Ausprobieren.

## Aufbau

- `Packages/KlarschiffCore` – Scanner, Katalog, Entfernen, Sicherheitslogik (Swift Package)
- `App` – SwiftUI-App; das Xcode-Projekt wird aus `project.yml` erzeugt

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

Die App mit dem Argument `--dry-run` starten (z. B. in Xcode unter Scheme > Run > Arguments). Dann läuft alles
wie gewohnt, es wird aber nichts entfernt.

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
legt `build/Klarschiff-<Version>.dmg` ab. Die Version stammt aus `MARKETING_VERSION` in `project.yml`.
