import AppKit
import SwiftUI
import KlarschiffCore

/// „Aktivste Apps & Dienste“: je Zeile Symbol, Name (Schloss bei Systemprozessen), Prozessanzahl · RAM,
/// CPU-Verlauf und CPU-%; bei eigenen Apps ein x mit Bestätigung „<App> beenden?“.
struct ActivityList: View {
    let entries: [ActivityEntry]
    @Environment(AppModel.self) private var model
    @State private var pendingQuit: ActivityEntry?
    @State private var isQuitting = false
    @State private var statusText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let statusText {
                Label(statusText, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Die Aktivität wird gemessen …")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        ActivityRow(
                            entry: entry,
                            canQuit: model.performance.requestQuit(entry),
                            quitDisabled: isQuitting || model.isRemoving
                        ) { pendingQuit = entry }
                        .padding(.vertical, 10)
                    }
                }
            }
            .glassCard(padding: 18)
        }
        .alert(
            pendingQuit.map { Self.quitTitle($0.name) } ?? "",
            isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
            presenting: pendingQuit
        ) { entry in
            Button("Abbrechen", role: .cancel) { pendingQuit = nil }
            Button("Beenden") { quit(entry) }
        } message: { _ in
            Text("Die App wird freundlich gebeten, sich zu beenden. Ungesicherte Änderungen fragt sie selbst ab.")
        }
    }

    private func quit(_ entry: ActivityEntry) {
        pendingQuit = nil
        isQuitting = true
        Task {
            let text = await model.performance.quit(entry, dryRun: model.dryRun)
            isQuitting = false
            withAnimation { statusText = text }
            try? await Task.sleep(for: .seconds(5))
            if statusText == text { withAnimation { statusText = nil } }
        }
    }

    // MARK: - Texte

    nonisolated static func quitTitle(_ name: String) -> String {
        "\(name) beenden?"
    }

    /// „1 Prozess“ / „3 Prozesse“.
    nonisolated static func processCountText(_ n: Int) -> String {
        n == 1 ? "1 Prozess" : "\(n) Prozesse"
    }

    /// CPU-Anteil mit einer Nachkommastelle, deutsches Komma: „12,3 %“.
    nonisolated static func cpuText(_ percent: Double) -> String {
        let number = max(0, percent).formatted(
            .number.precision(.fractionLength(1)).grouping(.never).locale(Locale(identifier: "de_DE")))
        return "\(number) %"
    }

    /// Untertitel: „3 Prozesse · 18,1 MB“ (RAM in Binäreinheiten wie die Aktivitätsanzeige).
    nonisolated static func detailText(_ entry: ActivityEntry) -> String {
        "\(processCountText(entry.processCount)) · \(ByteFormat.memoryString(Int64(clamping: entry.residentBytes)))"
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    let canQuit: Bool
    let quitDisabled: Bool
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isSystem {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help("Systemprozess – Klarschiff 2 beendet ihn nicht.")
                            .accessibilityLabel("Systemprozess")
                    }
                }
                Text(ActivityList.detailText(entry))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Sparkline(values: entry.history, maxValue: 100, color: entry.cpuPercent >= 50 ? .orange : Theme.turquoise)
                .frame(width: 125, height: 26)
                .accessibilityHidden(true)
            Text(ActivityList.cpuText(entry.cpuPercent))
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
                .accessibilityLabel("Prozessor \(ActivityList.cpuText(entry.cpuPercent))")
            Group {
                if canQuit {
                    Button(action: onQuit) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 24, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(quitDisabled)
                    .help("\(entry.name) beenden")
                    .accessibilityLabel("\(entry.name) beenden")
                } else {
                    Color.clear
                }
            }
            .frame(width: 24, height: 24)
        }
    }

    @ViewBuilder private var icon: some View {
        if let path = entry.appPath, let image = AppIconCache.shared.icon(forPath: path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "gearshape.2")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Symbole je App-Pfad merken: die Liste wird alle 2 s neu gezeichnet, Datei-Abfragen kosten unnötig Zeit.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var icons: [String: NSImage] = [:]

    /// nil, wenn es den Pfad nicht gibt (dann zeigt die Zeile ein neutrales Symbol).
    func icon(forPath path: String) -> NSImage? {
        if let cached = icons[path] { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }
}
