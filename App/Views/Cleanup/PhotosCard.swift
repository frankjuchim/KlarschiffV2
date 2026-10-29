import AppKit
import SwiftUI
import KlarschiffCore

/// Fotos-Mediathek: nur Erklärung und Größe, keine Löschfunktion.
struct PhotosCard: View {
    let info: PhotosInfo

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 8) {
                Text("Fotos-Mediathek")
                    .font(.title3.weight(.bold))
                Text("Klarschiff löscht keine Fotos. Mit ‚Mac-Speicher optimieren‘ lagert Fotos Originale in iCloud aus – aber erst, wenn der Speicher knapp wird. Ob alles hochgeladen ist, steht unten in der Mediathek.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([info.libraryURL])
                } label: {
                    Label("Im Finder zeigen", systemImage: "magnifyingglass")
                }
                .buttonStyle(.glass)
                .padding(.top, 4)
            }
            Spacer(minLength: 12)
            Text(ByteFormat.string(info.librarySize))
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
        }
        .glassCard(padding: 24)
    }
}
