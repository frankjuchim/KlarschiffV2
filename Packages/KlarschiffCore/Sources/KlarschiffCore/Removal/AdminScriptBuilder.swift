import Foundation

public enum AdminScriptBuilder {
    /// Je Schritt eine Zeile; kein `set -e`, damit alle Schritte laufen. Alles über `ShellQuote.quote`.
    public static func script(for steps: [AdminStep]) -> String {
        steps.enumerated().map { i, step in
            let cmd = ([step.executable] + step.arguments).map(ShellQuote.quote).joined(separator: " ")
            return "\(cmd); echo \"KS_STEP \(i) $?\""
        }.joined(separator: "\n")
    }

    /// Liest `KS_STEP <n> <exit>`-Zeilen. Fehlende Schritte = -1; der letzte Marker je Schritt gewinnt.
    public static func parse(_ output: String, stepCount: Int) -> [Int32] {
        var codes = [Int32](repeating: -1, count: max(stepCount, 0))
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 3, parts[0] == "KS_STEP",
                  let n = Int(parts[1]), let code = Int32(parts[2]),
                  codes.indices.contains(n) else { continue }
            codes[n] = code
        }
        return codes
    }
}
