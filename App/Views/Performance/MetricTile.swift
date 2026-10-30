import SwiftUI

/// Glas-Kachel der Kachelreihe: Titel, großer Wert, Grafik (Sparkline/Balken), Fußzeile mit Wort.
struct MetricTile<Graphic: View>: View {
    let title: String
    let value: String
    let footnote: String
    @ViewBuilder var graphic: Graphic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            graphic
                .frame(height: 26)
            Text(footnote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .glassCard(padding: 20)
        .accessibilityElement(children: .combine)
    }
}

extension MetricTile where Graphic == Color {
    /// Kachel ohne Grafik (gleiche Höhe wie die anderen).
    init(title: String, value: String, footnote: String) {
        self.init(title: title, value: value, footnote: footnote) { Color.clear }
    }
}

/// Schmaler Anteilsbalken (z. B. benutzter Arbeitsspeicher).
struct FractionBar: View {
    let fraction: Double
    let fill: AnyShapeStyle

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(fill)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

#Preview {
    HStack {
        MetricTile(title: "Prozessor", value: "30 %", footnote: "kühl") {
            Sparkline(values: [0.2, 0.3, 0.28, 0.31])
        }
        MetricTile(title: "Seit Neustart", value: "9 Stunden", footnote: "frisch genug")
    }
    .padding()
    .frame(width: 600)
}
