import Foundation

public struct FindingID: Hashable, Codable, Sendable {
    public var scannerID: String
    public var key: String

    public init(scannerID: String, key: String) {
        self.scannerID = scannerID
        self.key = key
    }
}

public struct AppRef: Hashable, Codable, Sendable {
    public var bundleID: String?
    public var processName: String?
    public var displayName: String

    public init(bundleID: String?, processName: String?, displayName: String) {
        self.bundleID = bundleID
        self.processName = processName
        self.displayName = displayName
    }
}

public struct FindingItem: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var url: URL?
    public var name: String
    public var size: Int64?
    public var date: Date?
    public var detail: String?
    /// Laufende App, die genau dieses Item blockiert (Item-Ebene; der Fund bleibt vorauswählbar).
    public var blockingApp: AppRef?

    public init(
        id: String, url: URL? = nil, name: String, size: Int64? = nil, date: Date? = nil, detail: String? = nil,
        blockingApp: AppRef? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.size = size
        self.date = date
        self.detail = detail
        self.blockingApp = blockingApp
    }
}

public struct Finding: Identifiable, Sendable {
    public let id: FindingID
    public let category: Category
    public let title: String
    public let summary: String
    public let risk: Risk
    public let method: RemovalMethod
    public let items: [FindingItem]
    public let size: Int64?
    public let blockingApps: [AppRef]
    public let keepSuggested: Bool
    public let commandPreview: [String]
    public let needsFullDiskAccess: Bool

    public init(
        id: FindingID, category: Category, title: String, summary: String, risk: Risk,
        method: RemovalMethod, items: [FindingItem], size: Int64?, blockingApps: [AppRef],
        keepSuggested: Bool, commandPreview: [String], needsFullDiskAccess: Bool
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.summary = summary
        self.risk = risk
        self.method = method
        self.items = items
        self.size = size
        self.blockingApps = blockingApps
        self.keepSuggested = keepSuggested
        self.commandPreview = commandPreview
        self.needsFullDiskAccess = needsFullDiskAccess
    }

    public var tab: AppTab { category.tab }

    public func isPreselected(isKept: Bool) -> Bool {
        risk == .safe && !keepSuggested && !isKept && blockingApps.isEmpty
    }
}
