import Foundation

public enum LaunchScope: String, Codable, Sendable, CaseIterable {
    case user, allUsers, system, loginItem

    public var title: String {
        switch self {
        case .user: "Benutzer"
        case .allUsers: "Alle Benutzer"
        case .system: "System"
        case .loginItem: "Anmeldeobjekt"
        }
    }
}

public enum StartKind: String, Codable, Sendable {
    case atLogin, scheduled, onDemand

    public var title: String {
        switch self {
        case .atLogin: "startet bei der Anmeldung"
        case .scheduled: "startet zeitgesteuert"
        case .onDemand: "startet bei Bedarf"
        }
    }
}

/// Ein Hintergrunddienst (LaunchAgent, -Daemon oder Anmeldeobjekt).
public struct LaunchItem: Sendable, Identifiable, Equatable {
    public var id: String
    public var label: String
    public var scope: LaunchScope
    public var plistURL: URL?
    public var programPath: String?
    public var associatedBundleIDs: [String]
    public var appURL: URL?
    public var startKind: StartKind
    public var isRunning: Bool
    public var isOrphaned: Bool
    public var isOwnAgent: Bool
    public var displayName: String
    public var explanation: String
    /// Keine zugehörige App erkennbar (für die Statuszeile, statt eines Textvergleichs).
    public var hasNoKnownApp: Bool
    /// Ein nicht entfernbarer Dienst derselben launchd-Domäne trägt dasselbe Label (Benutzer und Alle Benutzer teilen
    /// `gui/<uid>`) – dann wird dieser Eintrag weder gestoppt noch entfernt. Gesetzt von `ServiceRemoval.markSharedLabels`.
    public var sharesLabelWithKeptService: Bool

    public init(
        id: String, label: String, scope: LaunchScope, plistURL: URL? = nil, programPath: String? = nil,
        associatedBundleIDs: [String] = [], appURL: URL? = nil, startKind: StartKind = .onDemand,
        isRunning: Bool = false, isOrphaned: Bool = false, isOwnAgent: Bool = false,
        displayName: String, explanation: String, hasNoKnownApp: Bool = false, sharesLabelWithKeptService: Bool = false
    ) {
        self.id = id
        self.label = label
        self.scope = scope
        self.plistURL = plistURL
        self.programPath = programPath
        self.associatedBundleIDs = associatedBundleIDs
        self.appURL = appURL
        self.startKind = startKind
        self.isRunning = isRunning
        self.isOrphaned = isOrphaned
        self.isOwnAgent = isOwnAgent
        self.displayName = displayName
        self.explanation = explanation
        self.hasNoKnownApp = hasNoKnownApp
        self.sharesLabelWithKeptService = sharesLabelWithKeptService
    }
}
