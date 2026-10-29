import SwiftUI
import KlarschiffCore

/// Schnappschuss-Karte (Spec §4.2): erklärt Update- und Time-Machine-Schnappschüsse.
/// Sichtbar, wenn Schnappschüsse existieren oder mehr als 5 GB nicht zuzuordnen sind.
struct SnapshotCard: View {
    let report: SystemDataReport

    static let unaccountedThreshold: Int64 = 5_000_000_000

    static func isVisible(_ report: SystemDataReport) -> Bool {
        !report.snapshotFindings.isEmpty || report.unaccounted > unaccountedThreshold
    }

    private var update: Finding? { report.snapshotFindings.first { $0.id.key == "update" } }
    private var timeMachine: Finding? { report.snapshotFindings.first { $0.id.key == "timeMachine" } }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 12) {
                Text("Schnappschüsse")
                    .font(.title3.weight(.bold))
                Text(intro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let update {
                    SnapshotKind(
                        title: "Update-Schnappschüsse (\(update.items.count))",
                        text: "macOS hält sie für ein ausstehendes Update fest und schützt sie. Sie verschwinden, sobald du das Update installierst und neu startest.") {
                            if case .hint(let action?) = update.method {
                                HintActionButton(action: action)
                            }
                        }
                }
                if let timeMachine {
                    SnapshotKind(
                        title: "Time-Machine-Schnappschüsse (\(timeMachine.items.count))",
                        text: "Lokale Kopien deiner Time-Machine-Sicherung. macOS löscht sie bei Platzmangel selbst; entfernen kannst du sie im Tab Speicher.") {
                            SeeFindingButton(tab: .storage)
                        }
                }
                if update == nil, timeMachine == nil {
                    Text("Gerade findet Klarschiff 2 keine lokalen Schnappschüsse. Der nicht zuordenbare Rest stammt dann meist aus Ordnern, die ohne Vollzugriff oder Admin-Rechte nicht lesbar sind.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .glassCard(padding: 24)
    }

    private var intro: String { Self.intro(report) }

    /// Nennt den Balken-Posten nur, wenn er auch angezeigt wird (Inventar vorhanden, Wert > 0).
    static func intro(_ report: SystemDataReport) -> String {
        let base = "Lokale Schnappschüsse belegen Platz, den macOS nicht einzeln ausweist."
        guard report.inventory != nil, report.unaccounted > 0 else { return base }
        let prefix = report.unaccountedIsUpperBound ? "höchstens " : ""
        return base + " Er steckt im Posten „Schnappschüsse & nicht zuordenbar“ (\(prefix)\(ByteFormat.string(report.unaccounted)))."
    }
}

/// Eine Schnappschuss-Art mit Erklärung und Knopf.
private struct SnapshotKind<Action: View>: View {
    let title: String
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            action()
                .padding(.top, 2)
        }
    }
}
