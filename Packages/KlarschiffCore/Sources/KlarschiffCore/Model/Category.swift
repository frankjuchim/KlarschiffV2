import Foundation

public enum AppTab: String, CaseIterable, Sendable {
    case storage, developer, systemData, services, performance

    public var title: String {
        switch self {
        case .storage: "Speicher"
        case .developer: "Entwickler"
        case .systemData: "Systemdaten"
        case .services: "Hintergrunddienste"
        case .performance: "Leistung"
        }
    }

    public var symbol: String {
        switch self {
        case .storage: "internaldrive"
        case .developer: "hammer"
        case .systemData: "chart.pie"
        case .services: "gearshape.2"
        case .performance: "gauge.with.dots.needle.50percent"
        }
    }
}

public enum Category: String, CaseIterable, Sendable {
    case system, aiLeftovers, appCaches, personalData, apps
    case xcode, simulators, homebrew, languages, toolchains

    public var tab: AppTab {
        switch self {
        case .system, .aiLeftovers, .appCaches, .personalData, .apps: .storage
        case .xcode, .simulators, .homebrew, .languages, .toolchains: .developer
        }
    }

    public var title: String {
        switch self {
        case .system: "System"
        case .aiLeftovers: "KI-Reste"
        case .appCaches: "App-Caches"
        case .personalData: "Persönliche Daten"
        case .apps: "Apps"
        case .xcode: "Xcode"
        case .simulators: "Simulatoren"
        case .homebrew: "Homebrew"
        case .languages: "Sprachen & Paketmanager"
        case .toolchains: "Toolchains & SDKs"
        }
    }

    public var symbol: String {
        switch self {
        case .system: "macwindow"
        case .aiLeftovers: "sparkles"
        case .appCaches: "archivebox"
        case .personalData: "person.crop.circle"
        case .apps: "app.dashed"
        case .xcode: "hammer"
        case .simulators: "iphone"
        case .homebrew: "mug"
        case .languages: "shippingbox"
        case .toolchains: "wrench.and.screwdriver"
        }
    }

    /// Reihenfolge innerhalb des Tabs (Deklarationsreihenfolge).
    public var sortOrder: Int {
        Category.allCases.firstIndex(of: self)!
    }
}
