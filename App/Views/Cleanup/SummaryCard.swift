import SwiftUI
import KlarschiffCore

/// Zusammenfassung oben im Tab: ausgewählte Größe, „Neu scannen“, „Aufräumen“, Regeltext, Papierkorb-Knopf.
struct SummaryCard: View {
    let tab: AppTab
    let onCleanup: () -> Void
    @Environment(AppModel.self) private var model
    @State private var confirmTrash = false

    static let ruleText = "Vorausgewählt ist nur, was sich von selbst wieder aufbaut. Großes wird direkt gelöscht, alles andere landet im Papierkorb."

    private var busy: Bool { model.isScanning || model.isRemoving }

    private var hasSelection: Bool {
        model.findings(in: tab).contains { _, findings in findings.contains { model.isSelected($0.id) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ByteFormat.string(model.selectedSize(in: tab)))
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("ausgewählt von \(ByteFormat.string(model.foundSize(in: tab))) gefunden")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Button {
                    Task { await model.scan(includeSlowChecks: true) }
                } label: {
                    Label("Neu scannen", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(busy)

                Button(action: onCleanup) {
                    Label("Aufräumen", systemImage: "sparkles")
                }
                .buttonStyle(GradientButtonStyle())
                .disabled(busy || !hasSelection)
            }

            if model.isScanning {
                ProgressView(value: model.scanProgress) {
                    Text("Scanne …").font(.callout)
                }
                .tint(Theme.violet)
            } else if model.isRemoving {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.removalProgress ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if tab == .storage, model.lastCheck != nil {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if let line = AppModel.statusLine(model.lastCheck, now: context.date) {
                        Label(line, systemImage: "clock")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .center, spacing: 16) {
                Text(Self.ruleText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                if tab == .storage, let trash = model.trashBytes, trash > 0 {
                    Button {
                        confirmTrash = true
                    } label: {
                        Label("Papierkorb leeren (\(ByteFormat.string(trash)))", systemImage: "trash")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(busy)
                }
            }
        }
        .glassCard(padding: 28)
        .alert("Papierkorb endgültig leeren?", isPresented: $confirmTrash) {
            Button("Abbrechen", role: .cancel) {}
            Button("Leeren", role: .destructive) {
                Task { await model.emptyTrash() }
            }
        }
    }
}

/// Verlaufsknopf (Türkis → Violett) für die Hauptaktion „Aufräumen“.
struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GradientButton(configuration: configuration)
    }

    private struct GradientButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background {
                    Capsule()
                        .fill(Theme.accentGradient)
                        .shadow(color: Theme.violet.opacity(isEnabled ? 0.3 : 0), radius: 8, y: 3)
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
                .contentShape(.capsule)
        }
    }
}
