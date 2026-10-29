import AppKit
import SwiftUI
import KlarschiffCore

/// Karte eines Systembereichs: Klarname, Größe bzw. „mindestens …“, Einstufungspille, Erklärung, Lupe;
/// aufklappbar bei Unterbereichen. Aufräum-Karten (Spec §5) stehen direkt im passenden grünen Bereich.
struct SystemAreaCard: View {
    let area: SystemArea
    /// Aufräum-Funde je Bereichs-ID (siehe `SystemAreaFindings`).
    let findings: [String: [Finding]]
    @State private var expanded: Bool

    init(area: SystemArea, findings: [String: [Finding]]) {
        self.area = area
        self.findings = findings
        // Bereiche mit Aufräum-Karten in Unterbereichen starten aufgeklappt, damit die Karten sichtbar sind.
        _expanded = State(initialValue: area.children.contains { !(findings[$0.id] ?? []).isEmpty })
    }

    private var children: [SystemArea] { SystemAreaFindings.sortedBySize(area.children) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                AreaInfo(area: area, titleFont: .system(size: 16, weight: .semibold))
                Spacer(minLength: 12)
                AreaSize(area: area, font: .system(size: 18, weight: .bold))
                if !children.isEmpty {
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

            ForEach(findings[area.id] ?? []) { finding in
                SystemCleanupCard(finding: finding)
            }

            if expanded, !children.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(children) { child in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                AreaInfo(area: child, titleFont: .system(size: 14, weight: .semibold))
                                Spacer(minLength: 12)
                                AreaSize(area: child, font: .system(size: 15, weight: .semibold))
                            }
                            ForEach(findings[child.id] ?? []) { finding in
                                SystemCleanupCard(finding: finding)
                            }
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
        .glassCard(padding: 18)
    }
}

/// Titelzeile mit Pille und Lupe, Erklärung und ggf. „Im Tab … zeigen“.
private struct AreaInfo: View {
    let area: SystemArea
    let titleFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(area.title)
                    .font(titleFont)
                VerdictPill(verdict: area.verdict)
                if let url = SystemAreaFindings.revealURL(area.url) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Im Finder zeigen")
                    .accessibilityLabel("Im Finder zeigen")
                }
            }
            Text(area.summary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tab = SystemAreaFindings.targetTab(area) {
                SeeFindingButton(tab: tab)
                    .padding(.top, 2)
            }
        }
    }
}

/// Größe rechts: „12,3 GB“, „mindestens 12,3 GB“ oder „konnte nicht gemessen werden“.
private struct AreaSize: View {
    let area: SystemArea
    let font: Font

    var body: some View {
        Group {
            if let size = area.size {
                Text(area.isLowerBound ? "mindestens \(ByteFormat.string(size))" : ByteFormat.string(size))
                    .font(font)
                    .monospacedDigit()
            } else {
                Text("konnte nicht gemessen werden")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

/// Einstufungspille: grau „Gehört zu macOS – behalten“, grün „Aufräumbar“, blau „Siehe Fund“.
struct VerdictPill: View {
    let verdict: AreaVerdict

    var body: some View {
        switch verdict {
        case .keep: Pill(text: "Gehört zu macOS – behalten", color: Color(hex: 0x6B7A99))
        case .cleanable: Pill(text: "Aufräumbar", color: Color(hex: 0x1F9D55))
        case .seeFinding: Pill(text: "Siehe Fund", color: .blue)
        }
    }
}

/// „Im Tab Entwickler zeigen“ bzw. „Im Tab Speicher zeigen“: wechselt den Tab.
struct SeeFindingButton: View {
    let tab: AppTab
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.selectedTab = tab
        } label: {
            Label("Im Tab \(tab.title) zeigen", systemImage: "arrow.right.circle")
        }
        .buttonStyle(.glass)
    }
}

/// Aufräum-Karte im Stil der Fundkarten, darüber die rote Warnzeile „Achtung: …“.
struct SystemCleanupCard: View {
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let warning = SystemCleanup.warning(for: finding.id.scannerID) {
                Label("Achtung: \(warning)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(hex: 0xE5484D))
                    .fixedSize(horizontal: false, vertical: true)
            }
            FindingCard(finding: finding, summaryText: SystemAreaFindings.summaryWithoutWarning(finding))
        }
    }
}

/// Zuordnung Aufräum-Fund ↔ Bereich und kleine Hilfen der Bereichsliste.
enum SystemAreaFindings {
    static let areaForScanner: [String: String] = [
        "sysdata.libraryCaches": "library.caches",
        "sysdata.libraryLogs": "library.logs",
        "sysdata.temp": "var.folders.temp",
        "sysdata.unifiedLog": "var.db.diagnostics",
        "sysdata.macUpdate": "assets",
    ]

    /// Funde je Bereichs-ID; Funde ohne bekannten Bereich unter dem leeren Schlüssel.
    static func byArea(_ findings: [Finding]) -> [String: [Finding]] {
        Dictionary(grouping: findings) { areaForScanner[$0.id.scannerID] ?? "" }
    }

    /// Tab für „Im Tab … zeigen“: bei „Siehe Fund“ und bei den Benutzer-Caches (Instruments/Clang im Tab Entwickler).
    static func targetTab(_ area: SystemArea) -> AppTab? {
        if case .seeFinding(_, let tab) = area.verdict { return tab }
        return area.id == "var.folders.caches" ? .developer : nil
    }

    /// Ordner für die Lupe; bei Mustern wie `/private/var/folders/*/*/C` der Teil vor dem ersten `*`.
    static func revealURL(_ url: URL) -> URL? {
        let parts = url.pathComponents
        guard let star = parts.firstIndex(of: "*") else { return url }
        guard star > 1 else { return nil }
        return URL(filePath: NSString.path(withComponents: Array(parts[..<star])), directoryHint: .isDirectory)
    }

    /// Größte zuerst; nicht messbare ans Ende.
    static func sortedBySize(_ areas: [SystemArea]) -> [SystemArea] {
        areas.sorted { ($0.size ?? -1) > ($1.size ?? -1) }
    }

    /// Summary ohne die vorangestellte Warnzeile (die steht rot über der Karte).
    static func summaryWithoutWarning(_ f: Finding) -> String {
        guard let warning = SystemCleanup.warning(for: f.id.scannerID) else { return f.summary }
        let prefix = "Achtung: \(warning)"
        guard f.summary.hasPrefix(prefix) else { return f.summary }
        return f.summary.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
}
