import AppKit
import SwiftUI
import KlarschiffCore

/// Karte eines Fundes: Auswahlkreis, Titel mit Pillen, Kurzbeschreibung, Größe rechts, Chevron zum Aufklappen.
/// „Nur Hinweis“-Karten haben statt des Auswahlkreises einen Aktionsknopf.
struct FindingCard: View {
    let finding: Finding
    /// Abweichender Beschreibungstext (z. B. ohne die rot darüber stehende Warnzeile); nil = `finding.summary`.
    var summaryText: String? = nil
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var showCommand = false

    private var busy: Bool { model.isScanning || model.isRemoving || model.isChecking }
    private var isHint: Bool { AppModel.isHint(finding) }
    /// Ohne Vollzugriff nicht messbar: keine Auswahl, Hinweis statt Größe.
    private var lacksAccess: Bool { Self.lacksAccess(finding) }
    private var selectable: Bool { !isHint && !lacksAccess }
    private var selectableCount: Int { finding.items.filter { $0.blockingApp == nil }.count }
    private var canExpand: Bool { !finding.items.isEmpty || !finding.commandPreview.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                if selectable {
                    SelectionCircle(state: selectionState) { model.toggle(finding.id) }
                        .disabled(selectableCount == 0)
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    titleRow
                    if !(summaryText ?? finding.summary).isEmpty {
                        Text(summaryText ?? finding.summary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if isHint, case .hint(let action?) = finding.method {
                        HintActionButton(action: action)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 12)
                if !Self.hidesSizeColumn(finding) {
                    sizeColumn
                }
                if canExpand {
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .frame(width: 24, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(expanded ? "Einklappen" : "Aufklappen")
                }
            }

            if expanded {
                Divider()
                FindingItemsList(finding: finding, selectable: selectable)
                HStack(spacing: 12) {
                    if !finding.commandPreview.isEmpty {
                        Button {
                            showCommand = true
                        } label: {
                            Label("Befehl anzeigen", systemImage: "terminal")
                        }
                        .buttonStyle(.glass)
                    }
                    Spacer()
                    Button {
                        Task { await model.keep(finding.id) }
                    } label: {
                        Label("Immer behalten", systemImage: "pin")
                    }
                    .buttonStyle(.glass)
                    .disabled(busy)
                }
            }
        }
        .glassCard(padding: 18)
        .sheet(isPresented: $showCommand) {
            CommandSheet(title: finding.title, lines: finding.commandPreview)
        }
    }

    /// Hinweis-Karten ohne messbare Größe zeigen keine Größenspalte (kein „Null Byte“).
    /// „braucht Vollzugriff“ bleibt sichtbar.
    nonisolated static func hidesSizeColumn(_ f: Finding) -> Bool {
        f.risk == .hintOnly && (f.size ?? 0) == 0 && !lacksAccess(f)
    }

    /// Ohne Vollzugriff nicht messbar (Größe fehlt).
    nonisolated static func lacksAccess(_ f: Finding) -> Bool {
        f.needsFullDiskAccess && f.size == nil
    }

    private var selectionState: SelectionCircle.State {
        let chosen = model.selection[finding.id]?.count ?? 0
        if chosen == 0 { return .off }
        return chosen >= selectableCount ? .on : .partial
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(finding.title)
                .font(.system(size: 16, weight: .semibold))
            RiskPill(risk: finding.risk)
            if finding.keepSuggested {
                Pill(text: "Neueste – behalten empfohlen", color: .blue)
            }
            if !finding.blockingApps.isEmpty {
                BlockingWarning(apps: finding.blockingApps)
            }
        }
    }

    private var sizeColumn: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Group {
                if lacksAccess {
                    Text("braucht Vollzugriff")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if let size = finding.size {
                    Text(ByteFormat.string(size))
                        .font(.system(size: 18, weight: .bold))
                        .monospacedDigit()
                } else {
                    Text("Größe nicht messbar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !finding.items.isEmpty {
                Text(EntryCount.text(finding.items.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .fixedSize()
    }
}

// MARK: - Bausteine (auch von FindingItemsList und KeepSection genutzt)

/// „1 Eintrag“ / „2.229 Einträge“.
enum EntryCount {
    static func text(_ n: Int) -> String {
        n == 1 ? "1 Eintrag" : "\(n.formatted(.number.locale(Locale(identifier: "de_DE")))) Einträge"
    }
}

/// Auswahlkreis: leer, halb (nur einige Einträge) oder voll.
struct SelectionCircle: View {
    enum State { case off, partial, on }
    let state: State
    var size: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch state {
                case .off:
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                case .partial:
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.white, Theme.accentGradient)
                case .on:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Theme.accentGradient)
                }
            }
            .font(.system(size: size))
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Auswählen")
        .accessibilityValue(state == .off ? "Nicht ausgewählt" : state == .on ? "Ausgewählt" : "Teilweise ausgewählt")
    }
}

/// Kleine farbige Pille, z. B. „Sicher“.
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: .capsule)
            .fixedSize()
    }
}

/// Risiko-Pille: Sicher (grün), Prüfen (rot), Nur Hinweis (grau-blau).
struct RiskPill: View {
    let risk: Risk

    var body: some View {
        Pill(text: risk.label, color: color)
    }

    private var color: Color {
        switch risk {
        case .safe: Color(hex: 0x1F9D55)
        case .review: Color(hex: 0xE5484D)
        case .hintOnly: Color(hex: 0x6B7A99)
        }
    }
}

/// Orange Warnung „App läuft – vorher beenden“ mit Knopf „Beenden“ (danach Neu-Scan über das Modell).
struct BlockingWarning: View {
    let apps: [AppRef]
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Label("App läuft – vorher beenden", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .fixedSize()
            Button("Beenden") {
                Task {
                    for app in apps { await model.terminate(app) }
                }
            }
            .controlSize(.small)
            .buttonStyle(.glass)
            .disabled(model.isScanning || model.isRemoving || model.isChecking)
            .help(apps.map(\.displayName).joined(separator: ", "))
        }
    }
}

/// Aktionsknopf einer Hinweis-Karte (`HintAction`).
struct HintActionButton: View {
    let action: HintAction

    var body: some View {
        switch action {
        case .openURL(let url):
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label(Self.openLabel(for: url), systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.glass)
        case .revealInFinder(let url):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Im Finder zeigen", systemImage: "magnifyingglass")
            }
            .buttonStyle(.glass)
        }
    }

    nonisolated static func openLabel(for url: URL) -> String {
        url.absoluteString.contains("Software-Update") ? "Softwareupdate öffnen" : "Öffnen"
    }
}
