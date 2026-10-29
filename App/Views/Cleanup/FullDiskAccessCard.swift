import AppKit
import SwiftUI
import KlarschiffCore

/// Onboarding-Karte, solange der Vollzugriff fehlt.
struct FullDiskAccessCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 8) {
                Text("Klarschiff braucht Vollzugriff auf die Festplatte")
                    .font(.title3.weight(.bold))
                Text("Sonst bleiben Backups, Mail-Anhänge, Container-Caches und der Papierkorb unsichtbar. Klarschiff liest nur, gelöscht wird nur, was du auswählst.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                } label: {
                    Label("Systemeinstellungen öffnen", systemImage: "gearshape")
                }
                .buttonStyle(.glass)
                .padding(.top, 4)
            }
        }
        .glassCard(padding: 24)
    }
}

#Preview {
    FullDiskAccessCard()
        .padding()
        .frame(width: 900)
}
