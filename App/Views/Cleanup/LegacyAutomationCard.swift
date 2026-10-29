import SwiftUI
import KlarschiffCore

/// Karte oben im Tab „Speicher“, solange Überbleibsel der alten Aufräum-Automatik existieren (Spec §6).
struct LegacyAutomationCard: View {
    let items: [LegacyItem]
    @Environment(AppModel.self) private var model
    @State private var includeExtras = true
    @State private var confirm = false

    static let title = "Alte Aufräum-Automatik gefunden"
    static let extrasToggle = "Skript, Protokolle und die leere alte App ebenfalls in den Papierkorb legen"

    /// Häkchen-Text: „die leere alte App“ nur, wenn es sie gibt.
    nonisolated static func extrasToggleText(_ items: [LegacyItem]) -> String {
        hasEmptyApp(items) ? extrasToggle : "Skript und Protokolle ebenfalls in den Papierkorb legen"
    }

    /// Teil des Bestätigungstexts für die Extras – passend zu den gefundenen Teilen.
    nonisolated static func extrasNoun(_ items: [LegacyItem]) -> String {
        hasEmptyApp(items) ? "Skript, Protokolle und die leere alte App" : "Skript und Protokolle"
    }

    nonisolated static func hasEmptyApp(_ items: [LegacyItem]) -> Bool {
        items.contains { $0.kind == .emptyApp }
    }
    static let removeButton = "Alte Automatik entfernen"

    /// Die Erklärungen aus dem Kern setzen Dateinamen in `Backticks` – als Code darstellen statt wörtlich.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private var busy: Bool { model.isScanning || model.isRemoving || model.isMeasuringSystemData || model.isChecking }

    private var hasExtras: Bool {
        items.contains { if case .agent = $0.kind { false } else { true } }
    }

    private var hasAgents: Bool {
        items.contains { if case .agent = $0.kind { true } else { false } }
    }

    /// Bestätigungstext: was passiert, abhängig von Häkchen und Trockenlauf.
    private var confirmMessage: String {
        var text = hasAgents
            ? "Die alten Hintergrund-Agents werden gestoppt und in den Papierkorb gelegt."
            : "Nichts wird gestoppt."
        if hasExtras {
            let noun = Self.extrasNoun(items)
            text += includeExtras ? " \(noun) landen ebenfalls im Papierkorb." : " \(noun) bleiben liegen."
        }
        if model.dryRun { text += " Trockenlauf: Es wird nur gemeldet, nichts verändert." }
        return text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 12) {
                Text(Self.title)
                    .font(.title3.weight(.bold))
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.title)
                                    .fontWeight(.semibold)
                                if item.isLoaded {
                                    Text("läuft")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.orange.opacity(0.18), in: .capsule)
                                }
                            }
                            Text(Self.markdown(item.explanation))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if hasExtras {
                    Toggle(Self.extrasToggleText(items), isOn: $includeExtras)
                        .toggleStyle(.checkbox)
                }
                Button {
                    confirm = true
                } label: {
                    Label(Self.removeButton, systemImage: "trash")
                }
                .buttonStyle(.glass)
                .disabled(busy || !AppModel.legacyWouldRemove(items, includeExtras: includeExtras))
                .padding(.top, 2)
            }
        }
        .glassCard(padding: 24)
        .alert("Alte Automatik entfernen?", isPresented: $confirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Entfernen", role: .destructive) {
                let extras = includeExtras
                Task { await model.removeLegacy(includeExtras: extras) }
            }
        } message: {
            Text(confirmMessage)
        }
    }
}

#Preview {
    LegacyAutomationCard(items: PreviewLegacy.items)
        .padding()
        .frame(width: 900)
        .environment(AppModel.preview)
}
