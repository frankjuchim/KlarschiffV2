import AppKit
import ServiceManagement
import SwiftUI
import KlarschiffCore

/// Einstellungen (⌘,): Abschnitt „Automatischer Check“ mit Zeitplan, Anmeldestatus, „Jetzt prüfen“,
/// Statuszeile und Verlauf.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    static let explanation = "Der Check meldet sich nur, wenn es sich lohnt – und löscht nie etwas."
    static let notificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    static func label(_ schedule: CheckSchedule) -> String {
        switch schedule {
        case .off: "Aus"
        case .weekly: "Wöchentlich (sonntags 10 Uhr)"
        case .monthly: "Monatlich (Monatserster 10 Uhr)"
        }
    }

    private var busy: Bool { model.isChecking || model.isScanning || model.isRemoving || model.isMeasuringSystemData }

    var body: some View {
        Form {
            Section {
                Picker("Zeitplan", selection: Binding(
                    get: { model.checkSchedule },
                    set: { schedule in Task { await model.setCheckSchedule(schedule) } }
                )) {
                    ForEach(CheckSchedule.allCases, id: \.self) { schedule in
                        Text(Self.label(schedule)).tag(schedule)
                    }
                }
                Text(Self.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                agentHint
                notificationHint

                HStack(spacing: 12) {
                    Button("Jetzt prüfen") {
                        Task { await model.runCheckNow() }
                    }
                    .disabled(busy)
                    if model.isChecking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if let line = AppModel.statusLine(model.lastCheck, now: context.date) {
                        Text(line)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Automatischer Check")
            }

            Section("Verlauf") {
                CheckHistoryList(history: model.checkHistory)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 420)
        .task {
            model.refreshAgentStatus()
            await model.refreshNotificationStatus()
            await model.loadCheckHistory()
        }
    }

    /// Anmeldestatus des LaunchAgents – nur wenn ein Zeitplan gewählt ist.
    @ViewBuilder private var agentHint: some View {
        if model.checkSchedule != .off {
            switch model.agentStatus {
            case .enabled:
                Label("Angemeldet – der Check läuft automatisch.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .requiresApproval:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Bitte in den Systemeinstellungen unter Anmeldeobjekte erlauben.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("In den Systemeinstellungen erlauben") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            case .notFound:
                Label("Der Hintergrund-Check ist erst in der signierten App verfügbar.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            case .notRegistered:
                Label("Nicht angemeldet.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Mitteilungen: „nie gefragt“ ist harmlos, „abgelehnt“ heißt, der Check bleibt stumm.
    @ViewBuilder private var notificationHint: some View {
        switch model.notificationStatus {
        case .authorized:
            EmptyView()
        case .notDetermined:
            Label("Mitteilungen sind noch nicht erlaubt – sie werden beim Einschalten des Checks erfragt.", systemImage: "bell")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Mitteilungen sind ausgeschaltet. Ohne sie meldet sich der Check nicht.", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Mitteilungs-Einstellungen öffnen") {
                    NSWorkspace.shared.open(Self.notificationSettingsURL)
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel.preview)
}
