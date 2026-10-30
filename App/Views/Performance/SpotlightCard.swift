import AppKit
import SwiftUI
import KlarschiffCore

/// „Spotlight entlasten“: große Projektordner, die Spotlight unnötig durchsucht. Klarschiff 2 ändert nichts daran –
/// es zeigt die Ordner im Finder und öffnet die Spotlight-Einstellungen zum Ausschließen.
struct SpotlightCard: View {
    let performance: PerformanceModel

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!

    nonisolated static let explanation = "Spotlight durchsucht diese Projektordner mit, obwohl du darin nie etwas suchst – das kostet Rechenzeit und Akku. Schließ sie unter Systemeinstellungen → Spotlight → Datenschutz aus: einfach den Ordner in die Liste ziehen. Ordner, die du dort schon ausgeschlossen hast, können hier trotzdem noch auftauchen – Klarschiff 2 kann diese Liste nicht lesen. Klarschiff 2 ändert an deinen Projektordnern nichts."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                PerformanceSectionHeader(title: "Spotlight entlasten", symbol: "magnifyingglass.circle.fill")
                Spacer()
                Button {
                    Task { await performance.rescanSpotlight() }
                } label: {
                    Label("Neu suchen", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .disabled(performance.isScanningSpotlight)
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        if performance.spotlight.isEmpty {
            HStack(spacing: 10) {
                if performance.isScanningSpotlight {
                    ProgressView().controlSize(.small)
                    Text("Projektordner werden gesucht …")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color(hex: 0x1F9D55))
                    Text("Keine großen Projektordner gefunden.")
                        .fontWeight(.medium)
                        .foregroundStyle(Color(hex: 0x1F9D55))
                }
            }
            .glassCard(padding: 18)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(Self.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if performance.isScanningSpotlight {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Projektordner werden gesucht …")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(performance.spotlight.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { Divider() }
                        SpotlightRow(candidate: candidate)
                            .padding(.vertical, 10)
                    }
                }
                Button {
                    NSWorkspace.shared.open(Self.settingsURL)
                } label: {
                    Label("Spotlight-Einstellungen öffnen", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.glass)
            }
            .glassCard(padding: 22)
        }
    }

    /// Pfad mit „~“ statt Home-Ordner.
    nonisolated static func abbreviatedPath(_ url: URL, home: String = NSHomeDirectory()) -> String {
        let path = url.path
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !base.isEmpty else { return path }
        if path == base { return "~" }
        if path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
        return path
    }
}

private struct SpotlightRow: View {
    let candidate: SpotlightCandidate

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(SpotlightCard.abbreviatedPath(candidate.url))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(candidate.kind)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(ByteFormat.string(candidate.size))
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([candidate.url])
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Im Finder zeigen")
            .accessibilityLabel("Im Finder zeigen")
        }
    }
}
