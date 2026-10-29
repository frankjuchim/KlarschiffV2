#!/usr/bin/env bash
# Baut, signiert, notarisiert und verpackt Klarschiff als DMG.
# Voraussetzungen: Config/Local.xcconfig mit DEVELOPMENT_TEAM und das Keychain-Profil
# "klarschiff-notary" (siehe README.md).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/Klarschiff.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Klarschiff.app"
ZIP="$BUILD/Klarschiff-notarize.zip"

xcodegen generate

VERSION="$(xcodebuild -project Klarschiff.xcodeproj -scheme Klarschiff -showBuildSettings 2>/dev/null \
  | awk '$1 == "MARKETING_VERSION" { print $3; exit }')"
if [[ -z "$VERSION" ]]; then
  echo "MARKETING_VERSION konnte nicht ermittelt werden." >&2
  exit 1
fi
DMG="$BUILD/Klarschiff-$VERSION.dmg"

rm -rf "$ARCHIVE" "$EXPORT" "$ZIP" "$DMG"
mkdir -p "$BUILD"

xcodebuild archive \
  -project Klarschiff.xcodeproj \
  -scheme Klarschiff \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile klarschiff-notary --wait
xcrun stapler staple "$APP"

hdiutil create -volname "Klarschiff" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "Fertig: $DMG"
