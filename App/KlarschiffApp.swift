import AppKit
import SwiftUI
import KlarschiffCore
@preconcurrency import UserNotifications

@main
struct KlarschiffApp: App {
    /// Als Test-Host (XCTest/Swift Testing) wird weder gescannt noch etwas Echtes verdrahtet.
    static let isTestHost: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }()

    /// Besitzt das Modell (für den Mitteilungs-Klick) und führt den `--check`-Lauf ohne Fenster aus.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Klarschiff 2", id: "main") {
            Group {
                if let model = appDelegate.model {
                    RootView(model: model)
                } else {
                    Text("Klarschiff 2 (Test-Host)")
                }
            }
            .frame(minWidth: 1000, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
        // `--check`: kein Fenster beim Start (der AppDelegate schließt zur Sicherheit trotzdem alle).
        .defaultLaunchBehavior(BackgroundCheck.isRequested ? .suppressed : .automatic)
        .commands {
            if let model = appDelegate.model {
                CommandMenu("Entwickler") {
                    DryRunToggle(model: model)
                }
            }
        }
    }
}

/// Startpfade: normal (Modell + Mitteilungs-Delegate) oder `--check` (ohne Dock-Symbol und Fenster: Check
/// ausführen, ggf. Mitteilung senden, beenden). Der Check-Pfad baut weder `AppModel` noch Remover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model: AppModel?
    private let isCheckMode: Bool
    /// `--check`: Erst nach dem Lauf beenden – SwiftUI beendet eine Ein-Fenster-App sonst, sobald kein Fenster offen ist.
    private var checkFinished = false

    override init() {
        isCheckMode = BackgroundCheck.isRequested && !KlarschiffApp.isTestHost
        model = (KlarschiffApp.isTestHost || isCheckMode) ? nil : AppModel(dependencies: .live())
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if isCheckMode {
            // Vor dem ersten Fenster: kein Dock-Symbol, keine Menüleiste.
            NSApp.setActivationPolicy(.prohibited)
            return
        }
        // Muss vor dem Ende des Startens stehen, damit ein Klick, der die App startet, ankommt.
        if model != nil { UNUserNotificationCenter.current().delegate = self }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isCheckMode else { return }
        for window in NSApp.windows { window.close() }
        Task { @MainActor in
            _ = await BackgroundCheck.run(dependencies: .live())
            // `send` kehrt zurück, sobald das System die Mitteilung angenommen hat; kurzer Puffer zur Sicherheit.
            try? await Task.sleep(for: .seconds(1))
            checkFinished = true
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isCheckMode
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (isCheckMode && !checkFinished) ? .terminateCancel : .terminateNow
    }

    /// Klick auf die Mitteilung: App nach vorn, Ziel-Tab setzen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let tab = response.notification.request.content.userInfo["tab"] as? String
        await MainActor.run {
            model?.openTab(fromNotification: tab)
            NSApp.activate()
        }
    }

    /// „Jetzt prüfen“ bei offener App: Mitteilung trotzdem zeigen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// Schalter „Trockenlauf“ im Menü „Entwickler“; bei erzwungenem Trockenlauf (Startargument) an und gesperrt.
struct DryRunToggle: View {
    let model: AppModel

    var body: some View {
        Toggle("Trockenlauf", isOn: Binding(get: { model.dryRun }, set: { model.setDryRunSetting($0) }))
            .disabled(model.isDryRunForced || model.isRemoving || model.isScanning)
    }
}

/// Fensterinhalt: Hintergrund, Header mit Tabs und Kapazitätskarte, darunter der aktive Tab.
struct RootView: View {
    @Bindable var model: AppModel
    @State private var didStart = false

    var body: some View {
        ZStack {
            BackgroundView()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 16) {
                            HeaderView(dryRun: model.dryRun)
                            TabBarView(selection: $model.selectedTab)
                        }
                        Spacer(minLength: 0)
                        CapacityCard(disk: model.disk)
                    }
                    tabContent
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: Theme.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
        .task {
            guard !didStart else { return }
            didStart = true
            model.refreshSystemState()
            model.refreshAgentStatus()
            await model.loadCheckHistory()
            await model.scan(includeSlowChecks: false)
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch model.selectedTab {
        case .storage, .developer:
            CleanupTabView(tab: model.selectedTab)
                .environment(model)
        case .systemData:
            SystemDataTabView()
                .environment(model)
        case .services, .performance:
            PlaceholderTab(tab: model.selectedTab)
        }
    }
}
