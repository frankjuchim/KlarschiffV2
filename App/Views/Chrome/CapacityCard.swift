import SwiftUI
import KlarschiffCore

/// Kapazitätskarte rechts oben: „<frei> frei“, Verlaufsbalken (belegter Anteil), „von <gesamt>“.
struct CapacityCard: View {
    let disk: DiskSpace?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(disk.map { "\(ByteFormat.string($0.free)) frei" } ?? "– frei")
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: geo.size.width * usedFraction)
                }
            }
            .frame(height: 6)
            Text(disk.map { "von \(ByteFormat.string($0.total))" } ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(16)
        .frame(width: 210)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
    }

    private var usedFraction: CGFloat {
        guard let disk, disk.total > 0 else { return 0 }
        return CGFloat(min(1, max(0, Double(disk.total - disk.free) / Double(disk.total))))
    }
}
