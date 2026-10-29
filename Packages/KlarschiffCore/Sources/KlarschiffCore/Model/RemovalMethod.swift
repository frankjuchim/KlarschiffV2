import Foundation

/// POSIX-Single-Quote-Helfer für kopierbare Befehle und Admin-Skripte.
public enum ShellQuote {
    private static let harmless = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:@%+=,-")

    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ harmless.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct ToolCommand: Hashable, Codable, Sendable {
    public var tool: String
    public var arguments: [String]
    public var timeout: Duration

    public init(tool: String, arguments: [String], timeout: Duration) {
        self.tool = tool
        self.arguments = arguments
        self.timeout = timeout
    }

    /// Gequoteter, kopierbarer Befehl.
    public var display: String {
        ([tool] + arguments).map(ShellQuote.quote).joined(separator: " ")
    }
}

public struct AdminStep: Hashable, Codable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum HintAction: Hashable, Codable, Sendable {
    case openURL(URL)
    case revealInFinder(URL)
}

public enum Fallback: Hashable, Codable, Sendable {
    case delete, trash
}

public enum RemovalMethod: Hashable, Codable, Sendable {
    case trash
    case delete
    case tool([ToolCommand], fallback: Fallback?)
    case admin([AdminStep])
    case hint(HintAction?)
}
