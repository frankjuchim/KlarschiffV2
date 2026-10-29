import SwiftUI
import KlarschiffCore

/// Eine Kategorie: Kopfzeile mit Symbol, Titel und Summe, darunter Fehler-Karten und Fund-Karten.
struct CategorySection: View {
    let category: KlarschiffCore.Category
    let findings: [Finding]
    let failures: [ScanFailure]

    private var total: Int64 {
        findings.filter { !AppModel.isHint($0) }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(category.title)
                } icon: {
                    Image(systemName: category.symbol)
                        .foregroundStyle(Theme.accentGradient)
                }
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                Spacer()
                if !findings.isEmpty {
                    Text(ByteFormat.string(total))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 4)

            ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                Label("Konnte nicht geprüft werden: \(failure.message)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .glassCard(padding: 18)
            }

            ForEach(findings) { finding in
                FindingCard(finding: finding)
            }
        }
    }
}
