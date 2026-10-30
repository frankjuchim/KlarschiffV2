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

    /// `--demo`: Vorschau-Daten statt echter Messungen (für Bildschirmfotos der Website); immer Trockenlauf,
    /// ohne Updater. `--tab <storage|developer|systemData|services|performance>` öffnet direkt diesen Tab.
    static let isDemo = CommandLine.arguments.contains("--demo")
    static let startTab: AppTab? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--tab"), i + 1 < args.count else { return nil }
        return AppTab(rawValue: args[i + 1])
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
        .defaultSize(width: 1240, height: 880)
        .windowResizability(.contentMinSize)
        // `--check`: kein Fenster beim Start (der AppDelegate schließt zur Sicherheit trotzdem alle).
        .defaultLaunchBehavior(BackgroundCheck.isRequested ? .suppressed : .automatic)
        .commands {
            if let updater = appDelegate.updater {
                CommandGroup(after: .appInfo) {
                    CheckForUpdatesButton(updater: updater)
                }
            }
            if let model = appDelegate.model {
                CommandMenu("Entwickler") {
                    DryRunToggle(model: model)
                }
            }
        }

        // ⌘, – Einstellungen des automatischen Checks.
        Settings {
            if let model = appDelegate.model {
                SettingsView(updater: appDelegate.updater)
                    .environment(model)
            }
        }
    }
}

/// Startpfade: normal (Modell + Mitteilungs-Delegate) oder `--check` (ohne Dock-Symbol und Fenster: Check
/// ausführen, ggf. Mitteilung senden, beenden). Der Check-Pfad baut weder `AppModel` noch Remover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model: AppModel?
    /// Sparkle nur im normalen Start (nicht beim Hintergrund-Check, nicht als Test-Host).
    let updater: AppUpdater?
    private let isCheckMode: Bool
    /// `--check`: Erst nach dem Lauf (oder dem Wächter) beenden – SwiftUI beendet eine Ein-Fenster-App sonst,
    /// sobald kein Fenster offen ist.
    private var checkFinished = false
    /// Ein Beenden-Wunsch wartet (`.terminateLater`) auf das Ende des Laufs.
    private var terminationPending = false
    /// Abmelden/Ausschalten/Neustart: sofort beenden, ein verlorener Check ist egal.
    private var systemIsPoweringOff = false

    override init() {
        isCheckMode = BackgroundCheck.isRequested && !KlarschiffApp.isTestHost
        if KlarschiffApp.isTestHost || isCheckMode {
            model = nil
        } else if KlarschiffApp.isDemo {
            model = AppModel.demo
        } else {
            model = AppModel(dependencies: .live())
        }
        updater = (model == nil || KlarschiffApp.isDemo) ? nil : AppUpdater()
        if let tab = KlarschiffApp.startTab { model?.selectedTab = tab }
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
        if KlarschiffApp.isDemo {
            // Feste Fenstergröße für Bildschirmfotos (unabhängig von der gemerkten Größe).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                    window.setContentSize(NSSize(width: 1240, height: 840))
                    window.center()
                }
            }
        }
        guard isCheckMode else { return }
        for window in NSApp.windows { window.close() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemIsPoweringOff = true }
        }
        Task { @MainActor in
            // Wächter: ein hängender Lauf endet nach spätestens 10 Minuten (dann ohne Verlaufseintrag).
            let outcome = await BackgroundCheck.withTimeout(BackgroundCheck.headlessTimeout) {
                await BackgroundCheck.run(dependencies: .live())
            }
            // `send` kehrt zurück, sobald das System die Mitteilung angenommen hat; kurzer Puffer zur Sicherheit.
            if outcome?.notification != nil { try? await Task.sleep(for: .seconds(1)) }
            finishCheck()
        }
    }

    private func finishCheck() {
        checkFinished = true
        if terminationPending {
            terminationPending = false
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Verlauf und Anmeldestatus können sich durch einen Hintergrund-Lauf geändert haben.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model else { return }
        model.refreshAgentStatus()
        Task {
            await model.loadCheckHistory()
            await model.refreshNotificationStatus()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isCheckMode
    }

    /// Nie ein endgültiges Nein: während des Laufs `.terminateLater` (Antwort beim Lauf- oder Wächter-Ende),
    /// beim Abmelden/Ausschalten sofort.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isCheckMode, !checkFinished, !systemIsPoweringOff, !Self.isSystemQuit() else { return .terminateNow }
        terminationPending = true
        return .terminateLater
    }

    /// Kommt das Beenden vom System (Abmelden, Neustart, Ausschalten)? Steht im Quit-Apple-Event.
    private static func isSystemQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown]
            .map { OSType($0) }.contains(reason)
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
                            HeaderView(dryRun: model.dryRun && !KlarschiffApp.isDemo)
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
            // Zeitplan gewählt, Agent aber nicht (mehr) angemeldet → einmal neu anmelden.
            await model.reapplyScheduleIfNeeded()
            await model.loadCheckHistory()
            await model.refreshNotificationStatus()
            // Alte Automatik sofort zeigen, nicht erst nach dem (langen) ersten Scan.
            await model.detectLegacy()
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
        case .services:
            ServicesTabView()
                .environment(model)
        case .performance:
            PerformanceTabView()
                .environment(model)
        }
    }
}
