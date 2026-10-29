import Foundation

public struct AdminRemover: Sendable {
    private let executor: PrivilegedExecutor
    private let safety: SafetyGuard

    public init(executor: PrivilegedExecutor, guard safety: SafetyGuard) {
        self.executor = executor
        self.safety = safety
    }

    /// Eine Einheit = Items mit den Schritten, die zu ihnen gehören.
    private struct Unit {
        var findingID: FindingID
        var items: [FindingItem]
        var failure: String?          // fest verdrahtetes Ergebnis (gesperrt, falsche Methode …)
        var start = 0                 // Position im gemeinsamen Schrittfeld
        var count = 0
    }

    public func remove(_ batch: [(Finding, [FindingItem])], dryRun: Bool) async -> [ItemResult] {
        var units: [Unit] = []
        var steps: [AdminStep] = []

        for (finding, items) in batch {
            guard case .admin(let all) = finding.method else {
                units.append(Unit(findingID: finding.id, items: items, failure: "Falsche Methode"))
                continue
            }
            var planned: [(items: [FindingItem], steps: [AdminStep], failure: String?)] = []
            if !all.isEmpty, all.count == finding.items.count {
                for item in items {
                    guard let idx = finding.items.firstIndex(where: { $0.id == item.id }) else {
                        planned.append(([item], [], "Unbekanntes Item")); continue
                    }
                    planned.append(([item], [all[idx]], nil))
                }
            } else {
                planned.append((items, all, nil))
            }
            for p in planned {
                var unit = Unit(findingID: finding.id, items: p.items, failure: p.failure)
                var keep: [AdminStep] = []
                for step in p.steps {
                    if case .denied(let reason) = verdict(for: step) {
                        unit.failure = unit.failure ?? RemovalText.denied(reason)
                    } else {
                        keep.append(step)
                    }
                }
                if unit.failure != nil { keep = [] } // ein gesperrter Schritt: nichts der Einheit ausführen
                if !keep.isEmpty, !dryRun {
                    unit.start = steps.count
                    unit.count = keep.count
                    steps += keep
                }
                units.append(unit)
            }
        }

        var run: AdminRunResult?
        if !dryRun, !steps.isEmpty { run = await executor.run(steps) }

        var results: [ItemResult] = []
        for unit in units {
            let outcome: ItemOutcome
            if let f = unit.failure {
                outcome = .failed(f)
            } else if dryRun {
                outcome = .skipped(RemovalText.dryRun)
            } else if unit.count == 0 {
                outcome = .failed("Nichts auszuführen")
            } else {
                switch run {
                case .cancelled: outcome = .cancelled
                case .failed(let msg): outcome = .failed(msg)
                case .completed(let codes):
                    let mine = (unit.start..<unit.start + unit.count).map { codes.indices.contains($0) ? codes[$0] : -1 }
                    if mine.allSatisfy({ $0 == 0 }) {
                        outcome = .removed(freed: nil) // wird je Item unten mit Größe ersetzt
                    } else if mine.contains(-1) {
                        outcome = .failed("Nicht ausgeführt")
                    } else {
                        outcome = .failed("Exit \(mine.first { $0 != 0 } ?? 1)")
                    }
                case nil: outcome = .failed("Nicht ausgeführt")
                }
            }
            if unit.items.isEmpty {
                results.append(ItemResult(findingID: unit.findingID, itemID: nil, outcome: outcome))
            }
            for item in unit.items {
                var o = outcome
                if case .removed = o { o = .removed(freed: item.size) }
                results.append(ItemResult(findingID: unit.findingID, itemID: item.id, outcome: o))
            }
        }
        return results
    }

    private static let snapshotDate = try! NSRegularExpression(pattern: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\z"#)

    /// Allow-List: nur `/bin/rm` (jeder Operand geprüft), `tmutil deletelocalsnapshots <Datum>` und `log erase --all`.
    private func verdict(for step: AdminStep) -> SafetyVerdict {
        switch step.executable {
        case "/bin/rm": return rmVerdict(step.arguments)
        case "/usr/bin/tmutil":
            if step.arguments.count == 2, step.arguments[0] == "deletelocalsnapshots",
               Self.snapshotDate.firstMatch(in: step.arguments[1], range: NSRange(step.arguments[1].startIndex..., in: step.arguments[1])) != nil {
                return .allowed
            }
            return .denied("Unbekanntes Admin-Werkzeug")
        case "/usr/bin/log":
            return step.arguments == ["erase", "--all"] ? .allowed : .denied("Unbekanntes Admin-Werkzeug")
        default: return .denied("Unbekanntes Admin-Werkzeug")
        }
    }

    private static func isNormalizedAbsolute(_ p: String) -> Bool {
        guard p.hasPrefix("/"), p.count > 1, !p.hasSuffix("/") else { return false }
        return !p.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .contains { $0.isEmpty || String($0) == "." || String($0) == ".." }
    }

    private static let knownRmOptions: Set<String> = ["-r", "-f", "-R", "-rf", "-fr", "-Rf", "-fR"]

    /// BSD-`rm` beendet Optionen am ersten Nicht-Option-Argument (oder `--`); alles danach ist ein Operand.
    private func rmVerdict(_ args: [String]) -> SafetyVerdict {
        var optionsEnded = false
        var targets = 0
        for arg in args {
            if !optionsEnded {
                if arg == "--" { optionsEnded = true; continue }
                if arg.hasPrefix("-") {
                    if Self.knownRmOptions.contains(arg) { continue }
                    return .denied("Unbekannte rm-Option")
                }
                optionsEnded = true
            }
            targets += 1
            guard arg.hasPrefix("/") else { return .denied("Liegt außerhalb der erlaubten Ordner") }
            // rm bekommt den Rohstring: nur exakt die normalisierte Form, die der Guard prüft (kein Folgen von Symlink/).
            if !Self.isNormalizedAbsolute(arg) { return .denied("Pfad nicht eindeutig") }
            // /Library/Caches ist für alle beschreibbar: nur direkte Kinder (rm folgt Zwischen-Symlinks als root).
            let lower = arg.lowercased().split(separator: "/").map(String.init)
            if lower.count > 3, lower[0] == "library", lower[1] == "caches" { return .denied("Pfad nicht eindeutig") }
            if case .denied(let r) = safety.check(URL(filePath: arg)) { return .denied(r) }
        }
        return targets == 0 ? .denied("Kein Ziel angegeben") : .allowed
    }
}
