import Foundation

public enum Risk: String, Codable, Sendable {
    case safe, review, hintOnly

    public var label: String {
        switch self {
        case .safe: "Sicher"
        case .review: "Prüfen"
        case .hintOnly: "Nur Hinweis"
        }
    }
}
