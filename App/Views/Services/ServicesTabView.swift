import AppKit
import ServiceManagement
import SwiftUI
import KlarschiffCore

/// Tab „Hintergrunddienste“ (Spec TP4 §4): Kopfkarte, Abschnitt „Verwaist“ (auswählbar), Abschnitt „Aktiv“
/// nach Bereich gruppiert (nur erklärt), Hinweiskarte zu den Anmeldeobjekten. Liest beim ersten Öffnen pro App-Start.
struct ServicesTabView: View {
    @Environment(AppModel.self) private var model
    @State private var showConfirm = false

    /// Was den ersten Ladeversuch blockiert (Scan, Entfernen, Check, Systemdaten-Messung).
    private var busy: Bool { model.isScanning || model.isRemoving || model.isChecking || model.isMeasuringSystemData }

    var body: some View {
        let sections = Self.sections(model.services)
        VStack(alignment: .leading, spacing: 20) {
            if let error = model.lastError {
                ErrorBanner(message: error) { model.lastError = nil }
            }
            ServicesHeadCard(orphanedCount: sections.orphaned.count) { showConfirm = true }
            if let report = model.lastRemoval {
                ResultBanner(report: report)
            }
            if !sections.orphaned.isEmpty {
                OrphanedServicesSection(items: sections.orphaned)
            }
            if !sections.active.isEmpty {
                ActiveServicesSection(groups: sections.active)
            }
            if model.hasLoadedServices {
                LoginItemsHintCard(failed: model.loginItemsFailed)
            }
        }
        // Unstrukturiert: ein Tabwechsel darf das erste Einlesen nicht abbrechen.
        .onAppear { Task { await model.loadServicesIfNeeded() } }
        // Der erste Versuch kann an einem laufenden Scan/Entfernen/Check scheitern: danach erneut versuchen.
        .onChange(of: busy) { _, isBusy in
            guard !isBusy else { return }
            Task { await model.loadServicesIfNeeded() }
        }
        .sheet(isPresented: $showConfirm) {
            ConfirmSheet(tab: .services)
                .environment(model)
        }
    }

    // MARK: - Gruppierung

    /// Einträge eines Bereichs im Abschnitt „Aktiv“.
    struct ScopeGroup: Identifiable, Equatable {
        var id: LaunchScope { scope }
        let scope: LaunchScope
        let items: [LaunchItem]
    }

    struct Sections: Equatable {
        /// Verwaiste, nicht eigene Einträge (Abschnitt „Verwaist“), Reihenfolge wie geliefert.
        let orphaned: [LaunchItem]
        /// Alle übrigen, nach Bereich gruppiert (Benutzer / Alle Benutzer / System / Anmeldeobjekt); leere Bereiche fehlen.
        let active: [ScopeGroup]
    }

    nonisolated static func sections(_ items: [LaunchItem]) -> Sections {
        // Der eigene Check gehört nie zu „Verwaist“ (Selbstschutz, auch wenn ein Eintrag es behauptet).
        let isOrphan: (LaunchItem) -> Bool = { $0.isOrphaned && !$0.isOwnAgent }
        let orphaned = items.filter(isOrphan)
        let rest = items.filter { !isOrphan($0) }
        let groups = LaunchScope.allCases.compactMap { scope -> ScopeGroup? in
            let inScope = rest.filter { $0.scope == scope }
            return inScope.isEmpty ? nil : ScopeGroup(scope: scope, items: inScope)
        }
        return Sections(orphaned: orphaned, active: groups)
    }

    /// Kopfzeile: große Zahl + Text, bei null nur „Keine verwaisten Hintergrunddienste“.
    nonisolated static func headline(orphanedCount n: Int) -> (number: String?, text: String) {
        switch n {
        case 0: (nil, "Keine verwaisten Hintergrunddienste")
        case 1: ("1", "verwaister Hintergrunddienst")
        default: ("\(n)", "verwaiste Hintergrunddienste")
        }
    }

    nonisolated static let subtitle = "Dienste, deren App gelöscht wurde, laufen sonst weiter oder starten ins Leere."
}

/// Kopfkarte: Anzahl verwaister Dienste, „Neu prüfen“, „Entfernen“ (öffnet den Bestätigungsdialog), Untertitel.
private struct ServicesHeadCard: View {
    let orphanedCount: Int
    let onRemove: () -> Void
    @Environment(AppModel.self) private var model

    private var busy: Bool {
        model.isScanning || model.isRemoving || model.isChecking || model.isMeasuringSystemData || model.isLoadingServices
    }

    var body: some View {
        let headline = ServicesTabView.headline(orphanedCount: orphanedCount)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if !model.hasLoadedServices {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Hintergrunddienste werden geprüft …")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    } else if let number = headline.number {
                        Text(number)
                            .font(.system(size: 52, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(headline.text)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(headline.text)
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                    }
                }
                Spacer(minLength: 16)
                Button {
                    Task { await model.reloadServices() }
                } label: {
                    Label("Neu prüfen", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(busy)

                Button(action: onRemove) {
                    Label("Entfernen", systemImage: "bolt.fill")
                }
                .buttonStyle(GradientButtonStyle())
                .disabled(busy || model.selectedServices.isEmpty)
            }

            if model.isRemoving {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.removalProgress ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if model.isLoadingServices, model.hasLoadedServices {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Hintergrunddienste werden geprüft …")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text(ServicesTabView.subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard(padding: 28)
    }
}

/// Abschnitt „Aktiv“: alle nicht verwaisten Einträge, je Bereich eine Karte. Keine Auswahl.
private struct ActiveServicesSection: View {
    let groups: [ServicesTabView.ScopeGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ServicesSectionHeader(
                title: "Aktiv", symbol: "checkmark.seal.fill", style: AnyShapeStyle(Theme.accentGradient),
                count: groups.reduce(0) { $0 + $1.items.count })
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.scope.title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    ServiceList(items: group.items, orphaned: false)
                }
            }
        }
    }
}

/// Überschrift eines Abschnitts mit Symbol und Anzahl rechts.
struct ServicesSectionHeader: View {
    let title: String
    let symbol: String
    let style: AnyShapeStyle
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(style)
            Text(title)
                .font(.title2.weight(.bold))
            Spacer()
            Text("\(count)")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

/// Eine Glaskarte mit Zeilen, durch Trennlinien getrennt.
struct ServiceList: View {
    let items: [LaunchItem]
    let orphaned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                ServiceRow(item: item, orphaned: orphaned)
                    .padding(.vertical, 12)
            }
        }
        .glassCard(padding: 18)
    }
}

/// Hinweis: Anmeldeobjekte schaltet man in den Systemeinstellungen; Klarschiff 2 entfernt sie nie.
private struct LoginItemsHintCard: View {
    let failed: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
            VStack(alignment: .leading, spacing: 4) {
                Text("Anmeldeobjekte schaltest du in den Systemeinstellungen ein und aus.")
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                if failed {
                    Label("Anmeldeobjekte konnten nicht gelesen werden.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            Button {
                SMAppService.openSystemSettingsLoginItems()
            } label: {
                Label("Anmeldeobjekte öffnen", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.glass)
        }
        .glassCard(padding: 20)
    }
}

#Preview("Hintergrunddienste") {
    ScrollView {
        ServicesTabView()
            .padding(32)
    }
    .frame(width: 1100, height: 900)
    .background(BackgroundView())
    .environment(AppModel.preview)
}
