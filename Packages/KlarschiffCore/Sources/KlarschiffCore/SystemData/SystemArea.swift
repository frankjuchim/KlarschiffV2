import Foundation

/// Einstufung eines Systembereichs.
public enum AreaVerdict: Sendable, Equatable {
    /// „Gehört zu macOS – behalten“.
    case keep
    /// „Aufräumbar“ (über einen Systemdaten-Fund, siehe Spec §5).
    case cleanable
    /// „Siehe Fund“: ein Scanner eines anderen Tabs deckt den Bereich ab.
    case seeFinding(scannerID: String, tab: AppTab)
}

/// Deklarative Beschreibung eines Bereichs (Pfad absolut, wird über `ScanContext.absolute` aufgelöst).
public struct SystemAreaDefinition: Sendable {
    public var id: String
    public var path: String
    public var title: String
    public var summary: String
    public var verdict: AreaVerdict
    public var children: [SystemAreaDefinition]
    /// Titel des „Rest von“-Kinds; nil = kein Rest.
    public var restTitle: String?
    /// Weitere Pfade, die zur Größe dieses Bereichs zählen (Messung = path + extraPaths).
    public var extraPaths: [String]

    public init(id: String, path: String, title: String, summary: String, verdict: AreaVerdict,
                children: [SystemAreaDefinition] = [], restTitle: String? = nil, extraPaths: [String] = []) {
        self.id = id
        self.path = path
        self.title = title
        self.summary = summary
        self.verdict = verdict
        self.children = children
        self.restTitle = restTitle
        self.extraPaths = extraPaths
    }
}

/// Gemessener Bereich.
public struct SystemArea: Sendable, Identifiable {
    public var id: String
    public var url: URL
    public var title: String
    public var summary: String
    public var verdict: AreaVerdict
    public var size: Int64?
    public var isLowerBound: Bool
    public var children: [SystemArea]

    public init(id: String, url: URL, title: String, summary: String, verdict: AreaVerdict,
                size: Int64?, isLowerBound: Bool, children: [SystemArea] = []) {
        self.id = id
        self.url = url
        self.title = title
        self.summary = summary
        self.verdict = verdict
        self.size = size
        self.isLowerBound = isLowerBound
        self.children = children
    }
}
