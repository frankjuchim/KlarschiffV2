import SwiftUI
import KlarschiffCore

/// Eingeklappter Bereich „Behalten (n)“ am Ende des Tabs; je Zeile „Nicht mehr behalten“.
struct KeepSection: View {
    let findings: [Finding]
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    Label("Behalten (\(findings.count))", systemImage: "pin.fill")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                ForEach(findings) { finding in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title).fontWeight(.medium)
                            Text(finding.category.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(finding.size.map(ByteFormat.string) ?? "Größe nicht messbar")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("Nicht mehr behalten") {
                            Task { await model.unkeep(finding.id) }
                        }
                        .buttonStyle(.glass)
                        .disabled(model.isScanning || model.isRemoving || model.isChecking)
                    }
                }
            }
        }
        .glassCard(padding: 18)
    }
}
