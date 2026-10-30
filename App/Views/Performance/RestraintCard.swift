import SwiftUI

/// „Was Klarschiff 2 bewusst nicht tut“ (Spec TP5 §2): kein „RAM freigeben“, kein Dauer-Cache-Leeren.
struct RestraintCard: View {
    nonisolated static let points: [(title: String, text: String)] = [
        ("Kein „RAM freigeben“",
         "macOS nutzt freien Arbeitsspeicher absichtlich als Zwischenspeicher. Ihn „freizugeben“ macht den Mac eher langsamer."),
        ("Kein Dauer-Cache-Leeren",
         "Caches beschleunigen deinen Mac. Aufgeräumt wird nur gezielt – im Tab Speicher."),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 12) {
                Text("Was Klarschiff 2 bewusst nicht tut")
                    .font(.title3.weight(.bold))
                ForEach(Self.points, id: \.title) { point in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(point.title)
                            .fontWeight(.semibold)
                        Text(point.text)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .glassCard(padding: 24)
    }
}

#Preview {
    RestraintCard()
        .padding()
        .frame(width: 700)
}
