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
    case systemData
    case services

    public var tab: AppTab {
        switch self {
        case .system, .aiLeftovers, .appCaches, .personalData, .apps: .storage
        case .xcode, .simulators, .homebrew, .languages, .toolchains: .developer
        case .systemData: .systemData
        case .services: .services
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
        case .systemData: "Systemdaten"
        case .services: "Hintergrunddienste"
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
        case .systemData: "chart.pie"
        case .services: "gearshape.2"
        }
    }

    /// Reihenfolge innerhalb des Tabs (Deklarationsreihenfolge).
    public var sortOrder: Int {
        Category.allCases.firstIndex(of: self)!
    }
}

extension Category {
    /// Kategorie zum Scanner-ID-Präfix (vor dem ersten Punkt); unbekannt → nil.
    public static func forScannerID(_ id: String) -> Category? {
        let prefix = id.split(separator: ".", maxSplits: 1).first.map(String.init) ?? id
        switch prefix {
        case "system": return .system
        case "ai": return .aiLeftovers
        case "appCaches": return .appCaches
        case "personal": return .personalData
        case "apps": return .apps
        case "xcode": return .xcode
        case "sim", "simulators": return .simulators
        case "brew": return .homebrew
        case "languages": return .languages
        case "toolchains": return .toolchains
        case "sysdata", "systemdata": return .systemData
        case "services": return .services
        default: return nil
        }
    }
}
