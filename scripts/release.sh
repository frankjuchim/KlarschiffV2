#!/usr/bin/env bash
# Baut, signiert, notarisiert und verpackt Klarschiff 2 als DMG.
# Voraussetzungen: Config/Local.xcconfig mit DEVELOPMENT_TEAM, das Keychain-Profil
# "klarschiff-notary" und der Sparkle-Schlüssel im Schlüsselbund (siehe README.md).
# Vor jedem Release MARKETING_VERSION und CURRENT_PROJECT_VERSION in project.yml erhöhen:
# Sparkle vergleicht CURRENT_PROJECT_VERSION (CFBundleVersion).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/Klarschiff-2.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Klarschiff 2.app"
ZIP="$BUILD/Klarschiff-2-notarize.zip"

xcodegen generate

SETTINGS="$(xcodebuild -project Klarschiff.xcodeproj -scheme Klarschiff -showBuildSettings 2>/dev/null)"
VERSION="$(awk '$1 == "MARKETING_VERSION" { print $3; exit }' <<<"$SETTINGS")"
BUILD_NUMBER="$(awk '$1 == "CURRENT_PROJECT_VERSION" { print $3; exit }' <<<"$SETTINGS")"
if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
  echo "MARKETING_VERSION/CURRENT_PROJECT_VERSION konnten nicht ermittelt werden." >&2
  exit 1
fi
DMG="$BUILD/Klarschiff-2-$VERSION.dmg"
STAGE="$BUILD/dmg"
PACKAGES="$BUILD/SourcePackages"
SIGN_UPDATE="$PACKAGES/artifacts/sparkle/Sparkle/bin/sign_update"

rm -rf "$ARCHIVE" "$EXPORT" "$ZIP" "$DMG" "$STAGE"
mkdir -p "$BUILD"

xcodebuild archive \
  -project Klarschiff.xcodeproj \
  -scheme Klarschiff \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -clonedSourcePackagesDirPath "$PACKAGES"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile klarschiff-notary --wait
xcrun stapler staple "$APP"

# DMG mit Verknüpfung zum Programme-Ordner (Installation per Ziehen).
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Klarschiff 2.app"
ln -s /Applications "$STAGE/Programme"
hdiutil create -volname "Klarschiff 2" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# Sparkle-Signatur (privater Schlüssel aus dem Schlüsselbund).
SIGNATURE="$("$SIGN_UPDATE" "$DMG")"

echo
echo "Fertig: $DMG"
echo "Version $VERSION, Build $BUILD_NUMBER"
echo "Sparkle-Signatur: $SIGNATURE"
echo
echo "Im Website-Repository:"
echo "node scripts/klarschiff-release.mjs \"$DMG\" --build $BUILD_NUMBER --signature '$SIGNATURE'"
