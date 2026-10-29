import AppKit
import SwiftUI
import KlarschiffCore

/// Zeile eines Hintergrunddienstes: Name, Bereich-Pille, Erklärung, Label (monospaced) · Startart, „läuft gerade“, Lupe.
/// Verwaiste Zeilen: Auswahlkreis (nur wenn entfernbar), „Programm fehlt: …“ und „Befehl anzeigen“.
struct ServiceRow: View {
    let item: LaunchItem
    let orphaned: Bool
    @Environment(AppModel.self) private var model
    @State private var showCommand = false

    private var busy: Bool {
        model.isScanning || model.isRemoving || model.isChecking || model.isMeasuringSystemData || model.isLoadingServices
    }

    var body: some View {
        let selectable = orphaned && model.isServiceSelectable(item)
        let commands = orphaned ? ServiceCommandPreview.lines(model.serviceFindings(for: [item.id])) : []
        HStack(alignment: .top, spacing: 14) {
            if orphaned {
                SelectionCircle(state: model.selectedServices.contains(item.id) ? .on : .off) {
                    model.toggleService(item.id)
                }
                .disabled(!selectable || busy)
                .opacity(selectable ? 1 : 0.35)
                .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.displayName)
                        .font(.system(size: 16, weight: .semibold))
                    ScopePill(scope: item.scope)
                }
                Text(orphaned ? Self.missingText(item) : Self.statusText(item))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("\(item.label) · \(Self.startText(item))")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if item.isRunning {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(hex: 0x1F9D55))
                                .frame(width: 7, height: 7)
                            Text("läuft gerade")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Color(hex: 0x1F9D55))
                        }
                        .fixedSize()
                    }
                }
                if orphaned, !commands.isEmpty {
                    Button {
                        showCommand = true
                    } label: {
                        Label("Befehl anzeigen", systemImage: "terminal")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            if let url = Self.revealURL(item) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
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
        .sheet(isPresented: $showCommand) {
            CommandSheet(title: item.displayName, lines: commands)
        }
    }

    // MARK: - Texte

    /// Aktive Einträge: „App ist installiert.“ bzw. neutral „Gehört zu keiner App“; Sonderfälle (eigener Check,
    /// nicht lesbare plist, Laufwerk fehlt, Anmeldeobjekt ohne App-Pfad) zeigen ihre Erklärung.
    nonisolated static func statusText(_ item: LaunchItem) -> String {
        if item.isOwnAgent { return item.explanation }
        if item.appURL != nil { return "App ist installiert." }
        if item.scope == .loginItem { return item.explanation }
        if item.explanation == "Gehört zu keiner erkennbaren App." { return "Gehört zu keiner App" }
        return item.explanation
    }

    /// Verwaiste Einträge: „Programm fehlt: <Pfad>“, ohne bekannten Pfad die Erklärung.
    nonisolated static func missingText(_ item: LaunchItem) -> String {
        if let path = item.programPath, !path.isEmpty { return "Programm fehlt: \(path)" }
        return item.explanation
    }

    /// Startart; ausgeschaltete Anmeldeobjekte „ausgeschaltet“.
    nonisolated static func startText(_ item: LaunchItem) -> String {
        if item.scope == .loginItem, item.startKind != .atLogin { return "ausgeschaltet" }
        return item.startKind.title
    }

    /// Lupe: plist im Finder zeigen, sonst die App.
    nonisolated static func revealURL(_ item: LaunchItem) -> URL? {
        item.plistURL ?? item.appURL
    }
}

/// Bereich-Pille: Benutzer/Anmeldeobjekt türkis, Alle Benutzer/System violett (wie Klarschiff 1).
struct ScopePill: View {
    let scope: LaunchScope

    var body: some View {
        Pill(text: scope.title, color: color)
    }

    private var color: Color {
        switch scope {
        case .user, .loginItem: Color(hex: 0x1BA89C)
        case .allUsers, .system: Theme.violet
        }
    }
}

/// Kopierbare Befehle für Hintergrunddienste in Ausführungsreihenfolge: `launchctl bootout gui/…` (ohne Admin),
/// dann Papierkorb, dann Admin-Schritte (mit `sudo`).
enum ServiceCommandPreview {
    static func lines(_ findings: [Finding]) -> [String] {
        let selection = Dictionary(findings.map { ($0.id, Set($0.items.map(\.id))) }, uniquingKeysWith: { a, b in a.union(b) })
        let plan = RemovalPlan(findings: findings, selection: selection, options: RemovalOptions())
        let bootouts = findings.flatMap(\.commandPreview).filter { $0.contains(" bootout gui/") }
        return bootouts + plan.commandPreview
    }
}
