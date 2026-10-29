import Foundation

/// Wurzel, relativ zu der die Muster einer `PathRule` aufgelöst werden.
public enum PathBase: Sendable {
    /// Home-Verzeichnis (`ScanContext.home`).
    case home
    /// Benutzer-Cache-Ordner `DARWIN_USER_CACHE_DIR` (`ScanContext.userCacheDir`).
    case userCache
    /// Absoluter Pfad unterhalb von `ScanContext.rootPrefix`.
    case absolute
}

public enum Grouping: Sendable {
    /// Ein Fund, Einträge = getroffene Pfade.
    case single
    /// Je getroffener Pfad ein eigener Fund (key = Pfad).
    case perMatch
}

/// Wie der Name eines getroffenen Pfads im Titel eines `perMatch`-Funds erscheint.
public enum MatchName: Sendable {
    /// Letzte Pfadkomponente, z. B. „Pixel_7.avd“.
    case lastComponent
    /// Letzte Pfadkomponente ohne Endung, z. B. „Ubuntu“ statt „Ubuntu.utm“.
    case withoutExtension
    /// Hugging-Face-Cache: `models--org--name` → „org/name“.
    case huggingFace
}

/// Datum je Eintrag: wird als `date` und deutsches `detail` gesetzt; Einträge dann neueste zuerst.
public enum ItemDate: Sendable {
    case none
    /// Xcode-Archiv: `CreationDate` aus `Info.plist`, sonst Änderungsdatum des Ordners.
    case xcodeArchive
}

/// Deklarative Beschreibung eines dateibasierten Funds.
public struct PathRule: Sendable {
    public var id: String
    public var category: Category
    public var title: String
    public var summary: String
    public var base: PathBase
    /// Relativ zu `base`, durch „/“ getrennt; `*` steht für beliebige Zeichen innerhalb **einer** Pfadkomponente.
    public var patterns: [String]
    public var risk: Risk
    public var method: RemovalMethod
    public var blockingApps: [AppRef]
    /// Nur Dateien älter als n Tage (rekursiv); Einträge sind dann die einzelnen Dateien.
    public var minAgeDays: Int?
    public var minSize: Int64
    public var grouping: Grouping
    public var needsFullDiskAccess: Bool
    /// Namen, die beim Auflösen und bei der Rekursion übersprungen werden.
    public var excludeNames: Set<String>
    public var matchName: MatchName
    /// Begleitdateien: zu jedem Treffer `<name ohne Endung>.<ext>` im selben Ordner, falls vorhanden,
    /// als weiterer Eintrag desselben Funds (z. B. die `.ini` neben einem Android-`.avd`-Ordner).
    public var companionExtensions: [String]
    public var itemDate: ItemDate

    public init(
        id: String, category: Category, title: String, summary: String, base: PathBase,
        patterns: [String], risk: Risk, method: RemovalMethod, blockingApps: [AppRef] = [],
        minAgeDays: Int? = nil, minSize: Int64 = 1, grouping: Grouping = .single,
        needsFullDiskAccess: Bool = false, excludeNames: Set<String> = [], matchName: MatchName = .lastComponent,
        companionExtensions: [String] = [], itemDate: ItemDate = .none
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.summary = summary
        self.base = base
        self.patterns = patterns
        self.risk = risk
        self.method = method
        self.blockingApps = blockingApps
        self.minAgeDays = minAgeDays
        self.minSize = minSize
        self.grouping = grouping
        self.needsFullDiskAccess = needsFullDiskAccess
        self.excludeNames = excludeNames
        self.matchName = matchName
        self.companionExtensions = companionExtensions
        self.itemDate = itemDate
    }
}
