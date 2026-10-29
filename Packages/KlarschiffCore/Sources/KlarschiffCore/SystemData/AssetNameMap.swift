import Foundation

/// Klarnamen und Einstufungen für AssetsV2-Asset-Typen (Spec §3.3).
public enum AssetNameMap {
    static let prefix = "com_apple_MobileAsset_"

    private enum Match: Sendable {
        case exact(String)
        case prefix(String)
        case suffix(String)

        func matches(_ key: String) -> Bool {
            switch self {
            case .exact(let s): key == s
            case .prefix(let s): key.hasPrefix(s)
            case .suffix(let s): key.hasSuffix(s)
            }
        }
    }

    private struct Rule: Sendable {
        var match: Match
        var title: String
        var explanation: String
        var verdict: AreaVerdict = .keep
    }

    private static let simFinding = AreaVerdict.seeFinding(scannerID: "sim.runtimes", tab: .developer)
    private static let xcodeHint = "Verwalte sie über Xcode, nicht von Hand."

    // Reihenfolge zählt: erste passende Regel gewinnt.
    private static let rules: [Rule] = [
        Rule(match: .exact("iOSSimulatorRuntime"), title: "iOS-Simulator",
             explanation: "Laufzeit für den iOS-Simulator. Entfernen kannst Du sie sicher über den Fund „Simulator-Runtimes“ im Tab Entwickler.", verdict: simFinding),
        Rule(match: .exact("appleTVOSSimulatorRuntime"), title: "tvOS-Simulator",
             explanation: "Laufzeit für den tvOS-Simulator. Entfernen kannst Du sie sicher über den Fund „Simulator-Runtimes“ im Tab Entwickler.", verdict: simFinding),
        Rule(match: .exact("watchOSSimulatorRuntime"), title: "watchOS-Simulator",
             explanation: "Laufzeit für den watchOS-Simulator. Entfernen kannst Du sie sicher über den Fund „Simulator-Runtimes“ im Tab Entwickler.", verdict: simFinding),
        Rule(match: .exact("xrOSSimulatorRuntime"), title: "visionOS-Simulator",
             explanation: "Laufzeit für den visionOS-Simulator. Entfernen kannst Du sie sicher über den Fund „Simulator-Runtimes“ im Tab Entwickler.", verdict: simFinding),
        Rule(match: .exact("MacSoftwareUpdate"), title: "Heruntergeladenes macOS-Update",
             explanation: "Ein von macOS vorab geladenes Update. Es verschwindet nach der Installation von selbst. Willst Du es nicht, lösche es in den Systemeinstellungen unter Softwareupdate."),
        Rule(match: .exact("MacSplatSoftwareUpdate"), title: "Heruntergeladenes macOS-Update",
             explanation: "Ein von macOS vorab geladenes Update. Es verschwindet nach der Installation von selbst. Willst Du es nicht, lösche es in den Systemeinstellungen unter Softwareupdate."),
        Rule(match: .exact("SFRSoftwareUpdate"), title: "Schnelle Sicherheitsupdates",
             explanation: "Daten für kleine Sicherheitsupdates, die macOS ohne Neustart einspielt."),
        Rule(match: .exact("MacRecoveryOSUpdate"), title: "Wiederherstellungs-Update",
             explanation: "Aktualisierung der macOS-Wiederherstellung. macOS verwaltet sie selbst."),
        Rule(match: .exact("RecoveryOSUpdateBrain"), title: "Wiederherstellungs-Update (Werkzeug)",
             explanation: "Hilfsprogramm für das Update der macOS-Wiederherstellung."),
        Rule(match: .exact("MobileSoftwareUpdate_MacUpdateBrain"), title: "Update-Werkzeug",
             explanation: "Hilfsprogramm, mit dem macOS Updates installiert."),
        Rule(match: .exact("SoftwareUpdateDocumentation"), title: "Update-Beschreibungen",
             explanation: "Die Texte, die macOS bei Updates anzeigt."),
        Rule(match: .exact("AppleDeveloperDocumentation"), title: "Xcode-Dokumentation",
             explanation: "Die Entwicklerdokumentation für Xcode. " + xcodeHint),
        Rule(match: .exact("MetalToolchain"), title: "Metal-Werkzeuge",
             explanation: "Compiler für Grafikprogrammierung mit Metal. " + xcodeHint),
        Rule(match: .exact("SourceEditorAssets"), title: "Xcode-Editor-Daten",
             explanation: "Zusatzdaten für den Quelltext-Editor von Xcode. " + xcodeHint),
        Rule(match: .prefix("Trial_Siri"), title: "Siri-Sprachdaten",
             explanation: "Sprach- und Verständnisdaten für Siri. macOS verwaltet sie selbst."),
        Rule(match: .prefix("UAF_Siri"), title: "Siri-Sprachdaten",
             explanation: "Sprach- und Verständnisdaten für Siri. macOS verwaltet sie selbst."),
        Rule(match: .prefix("VoiceTrigger"), title: "Sprachaktivierung („Hey Siri“)",
             explanation: "Erkennung des Aktivierungsworts für Siri."),
        Rule(match: .exact("UAF_Speech_AutomaticSpeechRecognition"), title: "Spracherkennung",
             explanation: "Modelle zum Diktieren und Erkennen gesprochener Sprache."),
        Rule(match: .prefix("SpeechEndpoint"), title: "Spracherkennung",
             explanation: "Modelle zum Diktieren und Erkennen gesprochener Sprache."),
        Rule(match: .prefix("SpeechTranslation"), title: "Sprachübersetzung",
             explanation: "Modelle für die Übersetzung gesprochener Sprache."),
        Rule(match: .prefix("UAF_Translation"), title: "Übersetzung",
             explanation: "Sprachpakete für die Übersetzen-App und Systemfunktionen."),
        Rule(match: .prefix("TTSAX"), title: "Sprachausgabe",
             explanation: "Modelle, mit denen macOS Text vorliest."),
        Rule(match: .prefix("VoiceServices"), title: "Stimmen",
             explanation: "Stimmen zum Vorlesen von Text. Du kannst sie in den Systemeinstellungen unter Bedienungshilfen verwalten."),
        Rule(match: .exact("MacinTalkVoiceAssets"), title: "Stimmen",
             explanation: "Klassische Computerstimmen zum Vorlesen von Text."),
        Rule(match: .prefix("UAF_FM_"), title: "Apple-Intelligence-Modelle",
             explanation: "Sprachmodelle für Apple Intelligence. macOS lädt und löscht sie selbst, je nach Einstellung."),
        Rule(match: .prefix("UAF_Photos"), title: "Fotos-Modelle (Apple Intelligence)",
             explanation: "Modelle für Fotos-Funktionen wie Bereinigen."),
        Rule(match: .exact("ImageCaptionModel"), title: "Bildbeschreibungs-Modell",
             explanation: "Modell, das Bilder automatisch beschreibt."),
        Rule(match: .prefix("UAF_LinguisticData"), title: "Sprachdaten",
             explanation: "Daten für Rechtschreibprüfung, Textvorschläge und Spracherkennung."),
        Rule(match: .prefix("LinguisticData"), title: "Sprachdaten",
             explanation: "Daten für Rechtschreibprüfung, Textvorschläge und Spracherkennung."),
        Rule(match: .prefix("DictionaryServices_"), title: "Wörterbücher",
             explanation: "Die Wörterbücher der Lexikon-App und der Nachschlagen-Funktion."),
        Rule(match: .prefix("Font"), title: "Schriften",
             explanation: "Zusätzliche Schriften, die macOS bei Bedarf nachlädt."),
        Rule(match: .exact("DesktopPicture"), title: "Hintergrundbilder",
             explanation: "Die Bilder und bewegten Hintergründe aus den Systemeinstellungen."),
        Rule(match: .exact("SafariBackgroundImage"), title: "Safari-Hintergrundbilder",
             explanation: "Hintergrundbilder für die Startseite von Safari."),
        Rule(match: .exact("ComfortSoundsAssets"), title: "Hintergrundgeräusche",
             explanation: "Klänge wie Regen oder Meeresrauschen aus den Bedienungshilfen."),
        Rule(match: .exact("RawCamera_Camera"), title: "RAW-Kamera-Unterstützung",
             explanation: "Damit Fotos und Vorschau RAW-Bilder vieler Kameras öffnen können."),
        Rule(match: .exact("TimeZoneUpdate"), title: "Zeitzonen-Daten",
             explanation: "Aktuelle Zeitzonen- und Sommerzeitregeln."),
        Rule(match: .exact("KextDenyList"), title: "Sperrliste für Kernel-Erweiterungen",
             explanation: "Liste unsicherer Systemerweiterungen, die macOS nicht laden soll."),
        Rule(match: .prefix("PKITrust"), title: "Zertifikats-Vertrauensdaten",
             explanation: "Liste vertrauenswürdiger Zertifikate für sichere Verbindungen."),
        Rule(match: .prefix("UARP_"), title: "Zubehör-Firmware",
             explanation: "Aktualisierungen für angeschlossenes Apple-Zubehör."),
        Rule(match: .prefix("MobileAccessoryUpdate"), title: "Zubehör-Firmware",
             explanation: "Aktualisierungen für angeschlossenes Apple-Zubehör."),
        Rule(match: .exact("HomeKitDevices"), title: "HomeKit-Gerätedaten",
             explanation: "Informationen zu Smart-Home-Geräten für die Home-App."),
        Rule(match: .exact("RegulatoryCertification"), title: "Zulassungsinformationen",
             explanation: "Zulassungsdaten, die Du in den Systemeinstellungen unter Rechtliches findest."),
    ]

    private static func key(_ directory: String) -> String {
        directory.hasPrefix(prefix) ? String(directory.dropFirst(prefix.count)) : directory
    }

    private static func rule(for directory: String) -> Rule? {
        let k = key(directory)
        return rules.first { $0.match.matches(k) }
    }

    public static func entry(forAssetDirectory name: String) -> (title: String, verdict: AreaVerdict) {
        if let r = rule(for: name) { return (r.title, r.verdict) }
        return (key(name), .keep)
    }

    /// Erklärung zum Asset-Typ (Du-Form); Fallback für unbekannte Typen.
    public static func explanation(forAssetDirectory name: String) -> String {
        rule(for: name)?.explanation
            ?? "Eine Systemkomponente, die macOS selbst verwaltet. Du kannst sie behalten."
    }

    /// Nur für Tests: alle Einstufungen bzw. Titel der bekannten Regeln.
    static var allKnownVerdicts: [AreaVerdict] { rules.map(\.verdict) }
    static var allKnownTitles: [String] { rules.flatMap { [$0.title, $0.explanation] } }
}
