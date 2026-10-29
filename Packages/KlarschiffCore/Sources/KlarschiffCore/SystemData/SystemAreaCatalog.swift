import Foundation

/// Deklarativer Katalog der Systembereiche (Spec §3.2).
public enum SystemAreaCatalog {
    public static func definitions() -> [SystemAreaDefinition] {
        [
            SystemAreaDefinition(
                id: "var.folders", path: "/private/var/folders",
                title: "Benutzer-Ordner des Systems",
                summary: "Hier legt macOS pro Benutzer Caches und temporäre Dateien ab.",
                verdict: .keep,
                children: [
                    SystemAreaDefinition(
                        id: "var.folders.caches", path: "/private/var/folders/*/*/C",
                        title: "Benutzer-Caches (System)",
                        summary: "Zwischenspeicher von macOS und Programmen. Er gehört zu macOS und baut sich selbst wieder auf. Die Instruments- und Clang-Caches daraus findest Du als eigene Funde im Tab Entwickler.",
                        verdict: .keep),
                    SystemAreaDefinition(
                        id: "var.folders.temp", path: "/private/var/folders/*/*/T",
                        title: "Temporäre Dateien",
                        summary: "Arbeitsdateien von Programmen. Alte Einträge (älter als 3 Tage) in Deinem eigenen Ordner kannst Du in Klarschiff 2 aufräumen.",
                        verdict: .cleanable),
                ],
                restTitle: "Sonstige Systemordner"),
            SystemAreaDefinition(
                id: "var.vm", path: "/private/var/vm",
                title: "Auslagerung & Ruhezustand",
                summary: "macOS lagert hier Arbeitsspeicher aus und sichert ihn für den Ruhezustand. Die Dateien werden nach einem Neustart oft kleiner. Bitte nicht anfassen.",
                verdict: .keep),
            SystemAreaDefinition(
                id: "var.db", path: "/private/var/db",
                title: "System-Datenbanken",
                summary: "Datenbanken und Protokolle, die macOS im Hintergrund pflegt.",
                verdict: .keep,
                children: [
                    SystemAreaDefinition(
                        id: "var.db.diagnostics", path: "/private/var/db/diagnostics",
                        title: "Diagnosedaten (Systemprotokoll)",
                        summary: "Das Systemprotokoll von macOS samt Zuordnungsdateien. Du kannst es löschen; macOS beginnt dann ein neues Protokoll. Dafür brauchst Du Dein Admin-Passwort.",
                        verdict: .cleanable),
                ],
                restTitle: "System-Datenbanken"),
            SystemAreaDefinition(
                id: "library", path: "/Library",
                title: "Systemweite Bibliothek",
                summary: "Einstellungen und Komponenten, die für alle Benutzer dieses Macs gelten.",
                verdict: .keep,
                children: [
                    SystemAreaDefinition(
                        id: "library.caches", path: "/Library/Caches",
                        title: "Systemweite Caches",
                        summary: "Zwischenspeicher, den macOS und Apps für alle Benutzer anlegen. Sie bauen sich von selbst neu auf, der erste Start mancher Apps dauert danach etwas länger.",
                        verdict: .cleanable),
                    SystemAreaDefinition(
                        id: "library.logs", path: "/Library/Logs",
                        title: "System-Protokolle",
                        summary: "Protokolldateien von macOS und Programmen. Alte Protokolle kannst Du bedenkenlos entfernen.",
                        verdict: .cleanable),
                ],
                restTitle: "Systemweite Einstellungen & Komponenten"),
            SystemAreaDefinition(
                id: "assets", path: "/System/Volumes/Data/System/Library/AssetsV2",
                title: "macOS-Komponenten (Assets)",
                summary: "Von macOS nachgeladene Zusatzdaten wie Sprachmodelle, Schriften, Wörterbücher und Simulator-Laufzeiten. Unten siehst Du, was davon wie viel Platz braucht.",
                verdict: .keep),
            SystemAreaDefinition(
                id: "developer", path: "/Library/Developer",
                title: "Entwicklerwerkzeuge",
                summary: "Command Line Tools und Simulator-Laufzeiten. Simulator-Laufzeiten entfernst Du sicher über den passenden Fund im Tab Entwickler.",
                verdict: .seeFinding(scannerID: "xcode.libraryDeveloper", tab: .developer)),
            SystemAreaDefinition(
                id: "opt", path: "/opt",
                title: "Zusatzsoftware",
                summary: "Hier liegen Programme, die Du nachinstalliert hast, zum Beispiel Homebrew oder Anaconda. Aufräumen kannst Du sie über den Fund im Tab Entwickler.",
                verdict: .seeFinding(scannerID: "brew.cleanup", tab: .developer)),
            SystemAreaDefinition(
                id: "usrlocal", path: "/usr/local",
                title: "Zusatzsoftware (/usr/local)",
                summary: "Programme und Bibliotheken, die nicht zu macOS gehören, zum Beispiel TeX Live. Ist TeX Live vorhanden, zeigt Dir der Tab Entwickler den passenden Fund.",
                verdict: .seeFinding(scannerID: "toolchains.texlive", tab: .developer)),
        ]
    }
}
