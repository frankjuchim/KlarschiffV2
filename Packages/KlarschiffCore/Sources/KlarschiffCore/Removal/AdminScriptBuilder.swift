import Foundation

public enum AdminScriptBuilder {
    /// Zufälliger Marker pro Lauf, damit Schritt-Ausgaben keine Exit-Codes vortäuschen können.
    public static func makeNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Exit-Code eines übersprungenen bedingten Schritts.
    public static let skippedCode: Int32 = 125

    /// Je Schritt eine Zeile; kein `set -e`, damit alle Schritte laufen. Alles über `ShellQuote.quote`.
    /// Bedingte Schritte (`runsIfPreviousSucceeded`) laufen nur nach Erfolg des vorherigen Schritts
    /// (nach `launchctl bootout` auch 3/113), sonst Exit `skippedCode`.
    public static func script(for steps: [AdminStep], nonce: String) -> String {
        steps.enumerated().map { i, step in
            let cmd = ([step.executable] + step.arguments).map(ShellQuote.quote).joined(separator: " ")
            let marker = "echo \"KS_STEP \(nonce) \(i) $ks_rc\""
            guard step.runsIfPreviousSucceeded else { return "\(cmd); ks_rc=$?; \(marker)" }
            let okCodes = i > 0 && steps[i - 1].isBootout
                ? ([0] + AdminStep.bootoutNotLoadedCodes.sorted()).map(String.init).joined(separator: "|") : "0"
            return "case \"$ks_rc\" in \(okCodes)) \(cmd); ks_rc=$?;; *) ks_rc=\(skippedCode);; esac; \(marker)"
        }.joined(separator: "\n")
    }

    /// Liest `KS_STEP <nonce> <n> <exit>`-Zeilen. Fehlende Schritte = -1; der letzte Marker je Schritt gewinnt.
    public static func parse(_ output: String, stepCount: Int, nonce: String) -> [Int32] {
        var codes = [Int32](repeating: -1, count: max(stepCount, 0))
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 4, parts[0] == "KS_STEP", parts[1] == nonce,
                  let n = Int(parts[2]), let code = Int32(parts[3]),
                  codes.indices.contains(n) else { continue }
            codes[n] = code
        }
        return codes
    }
}
