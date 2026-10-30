import Combine
import Sparkle
import SwiftUI

/// Automatische Updates über Sparkle: Feed und Schlüssel stehen in `Config/Klarschiff-Info.plist`.
/// Nur im normalen Start aktiv (nicht beim `--check` im Hintergrund, nicht als Test-Host).
@MainActor
final class AppUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false
    private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Schalter in den Einstellungen; Sparkle merkt sich die Wahl selbst.
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }
}

/// Menüpunkt „Nach Updates suchen …“ im App-Menü.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Nach Updates suchen …") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// Abschnitt „Updates“ in den Einstellungen.
struct UpdateSettingsSection: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Section("Updates") {
            Toggle("Automatisch nach Updates suchen", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.automaticallyChecks = $0 }
            ))
            HStack {
                Text("Version \(Self.versionText)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Jetzt nach Updates suchen") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    /// „0.1.0 (1)“ aus der Info.plist.
    nonisolated static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
