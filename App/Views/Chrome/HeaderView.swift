import SwiftUI

/// Wortmarke und Untertitel; im Trockenlauf mit dauerhafter Pille „Trockenlauf aktiv“.
struct HeaderView: View {
    var dryRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text("Klarschiff")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(
                        colors: [Theme.turquoise, Theme.violet], startPoint: .leading, endPoint: .trailing))
                    .accessibilityAddTraits(.isHeader)
                if dryRun {
                    Label("Trockenlauf aktiv", systemImage: "flask")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.14), in: .capsule)
                        .fixedSize()
                        .help("Es wird nichts entfernt.")
                }
            }
            Text("Speicher aufräumen – KI-Reste, Caches und Liegengebliebenes.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
