import SwiftUI
import KlarschiffCore

/// Ergebnis nach dem Aufräumen: freigewordener Platz, aufklappbare Fehler je Eintrag; schließbar.
struct ResultBanner: View {
    let report: RemovalReport
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(report.failures.isEmpty ? Color(hex: 0x1F9D55) : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(freedText)
                        .font(.headline)
                    if !report.failures.isEmpty {
                        Button {
                            withAnimation(.snappy) { expanded.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Text(Self.failureText(report.failures.count))
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .rotationEffect(.degrees(expanded ? 180 : 0))
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    model.lastRemoval = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Schließen")
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(report.failures.enumerated()), id: \.offset) { _, result in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(model.label(for: result))
                                .fontWeight(.medium)
                            Text(Self.reason(result.outcome))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 40)
            }
        }
        .glassCard(padding: 18)
    }

    private var freedText: String {
        Self.headline(report, legacy: model.lastRemovalWasLegacy, services: model.lastRemovalWasServices,
                      dryRun: model.lastRemovalWasDryRun)
    }

    /// Überschrift: freigewordener Platz – nach dem Entfernen der alten Automatik bzw. von Hintergrunddiensten
    /// (Dateien ohne Größe) ein Erfolgssatz. Das Trockenlauf-Etikett gehört zum jeweiligen Lauf.
    nonisolated static func headline(_ report: RemovalReport, legacy: Bool, services: Bool = false, dryRun: Bool) -> String {
        let base: String
        if legacy {
            base = report.failures.isEmpty ? "Alte Automatik entfernt." : "Alte Automatik nur teilweise entfernt."
        } else if services {
            if report.failures.isEmpty {
                base = "Hintergrunddienste entfernt."
            } else if report.results.allSatisfy({ !Self.isRemoved($0.outcome) }) {
                // Kein einziger Dienst entfernt (alle abgebrochen bzw. fehlgeschlagen).
                base = "Hintergrunddienste nicht entfernt."
            } else {
                base = "Hintergrunddienste nur teilweise entfernt."
            }
        } else {
            base = "\(ByteFormat.string(report.freedBytes)) frei geworden."
        }
        return dryRun ? base + " (Trockenlauf)" : base
    }

    private nonisolated static func isRemoved(_ outcome: ItemOutcome) -> Bool {
        if case .removed = outcome { return true }
        return false
    }

    /// „n Einträge konnten nicht entfernt werden.“ (Einzahl bei genau einem Eintrag).
    nonisolated static func failureText(_ n: Int) -> String {
        n == 1 ? "1 Eintrag konnte nicht entfernt werden." : "\(n) Einträge konnten nicht entfernt werden."
    }

    static func reason(_ outcome: ItemOutcome) -> String {
        switch outcome {
        case .failed(let message), .skipped(let message): message
        case .cancelled: "Abgebrochen"
        case .removed: "Entfernt"
        }
    }
}
