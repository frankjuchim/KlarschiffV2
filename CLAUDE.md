# Klarschiff 2

macOS-App zum sicheren Aufräumen von Speicher (privat, Direkt-Download, keine Sandbox). Nachfolger von Klarschiff 1.

## Wo steht was
- Anforderungen: `docs/Briefing.md`, Design-Referenz `docs/screenshots/`
- Spec Teilprojekt 1: `docs/superpowers/specs/2026-10-29-klarschiff2-teilprojekt1-design.md`
- Plan Teilprojekt 1: `docs/superpowers/plans/2026-10-29-klarschiff2-teilprojekt1.md`
- Übergabe/Status: `docs/UEBERGABE.md`

## Konventionen
- Swift 6, macOS 26, SwiftUI mit Liquid Glass; Logik nur in `Packages/KlarschiffCore`, App ist dünn.
- Xcode-Projekt per XcodeGen: `xcodegen generate` (`.xcodeproj` nicht einchecken).
- Tests: `swift test --package-path Packages/KlarschiffCore`; App: `xcodebuild -scheme Klarschiff -destination 'platform=macOS' test`.
- UI-Texte Deutsch, Du-Form, freundlich-erklärend wie Klarschiff 1.
- Sicherheitsregeln aus Spec Abschnitt 7 sind verbindlich. Nichts wird ohne `SafetyGuard` gelöscht. Beim Testen der echten App zuerst `--dry-run`.
- `Config/Local.xcconfig` (Team-ID) nie einchecken.
