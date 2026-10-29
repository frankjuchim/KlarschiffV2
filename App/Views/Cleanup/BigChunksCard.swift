import AppKit
import SwiftUI
import KlarschiffCore

/// „Große Brocken“: Ordner über 1 GB als Balkenliste mit Icon, Größe und Lupe.
struct BigChunksCard: View {
    let chunks: [BigChunk]

    private var maxSize: Int64 { max(1, chunks.map(\.size).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Große Brocken", systemImage: "chart.bar.fill")
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("Ordner über 1 GB. Klarschiff löscht hier nur, was oben gelistet ist – den Rest räumst du am besten in der jeweiligen App auf oder deinstallierst die App.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(chunks) { chunk in
                    ChunkRow(chunk: chunk, fraction: Double(chunk.size) / Double(maxSize))
                }
            }
        }
        .glassCard(padding: 24)
    }
}

private struct ChunkRow: View {
    let chunk: BigChunk
    let fraction: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: chunk.url.path))
                .resizable()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(chunk.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if chunk.cleanableSize > 0 {
                        Text("davon \(ByteFormat.string(chunk.cleanableSize)) oben aufräumbar")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color(hex: 0x1F9D55))
                    }
                }
                GeometryReader { geo in
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: max(6, geo.size.width * fraction))
                }
                .frame(height: 5)
            }
            Text(ByteFormat.string(chunk.size))
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(minWidth: 80, alignment: .trailing)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([chunk.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Im Finder zeigen")
            .accessibilityLabel("Im Finder zeigen")
        }
    }
}
