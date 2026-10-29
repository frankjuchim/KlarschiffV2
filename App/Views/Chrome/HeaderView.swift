import SwiftUI

/// Wortmarke und Untertitel.
struct HeaderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Klarschiff")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(
                    colors: [Theme.turquoise, Theme.violet], startPoint: .leading, endPoint: .trailing))
                .accessibilityAddTraits(.isHeader)
            Text("Speicher aufräumen – KI-Reste, Caches und Liegengebliebenes.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
