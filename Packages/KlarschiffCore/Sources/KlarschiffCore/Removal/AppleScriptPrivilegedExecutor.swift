import Foundation

public struct AppleScriptPrivilegedExecutor: PrivilegedExecutor {
    public init() {}

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public func run(_ steps: [AdminStep]) async -> AdminRunResult {
        let script = AdminScriptBuilder.script(for: steps)
        let source = "do shell script \(Self.appleScriptString(script)) with administrator privileges"
        let count = steps.count
        return await MainActor.run {
            var error: NSDictionary?
            guard let apple = NSAppleScript(source: source) else { return .failed("Skript konnte nicht erstellt werden") }
            let out = apple.executeAndReturnError(&error)
            if let error {
                if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
                return .failed((error[NSAppleScript.errorMessage] as? String) ?? "Unbekannter Fehler")
            }
            return .completed(AdminScriptBuilder.parse(out.stringValue ?? "", stepCount: count))
        }
    }
}
