import SwiftUI
import KlarschiffCore

/// Bestätigung vor dem Aufräumen: was, wie viel, mit welcher Methode; Optionen (direkt löschen, zap);
/// „Befehle anzeigen“. Jede Optionsänderung baut den Plan neu.
struct ConfirmSheet: View {
    let tab: AppTab
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var options = RemovalOptions()
    @State private var showCommands = false
    @State private var acknowledged = false

    var body: some View {
        let plan = model.makePlan(tab: tab, options: options)
        let groups = Self.groups(for: plan)
        let needsAck = Self.requiresSystemAcknowledgement(plan)
        let isServices = Self.isServicesPlan(plan)
        let commands = isServices
            ? model.serviceCommandLines(for: Set(plan.allSteps.flatMap { $0.1.map(\.id) })) : plan.commandPreview
        VStack(alignment: .leading, spacing: 16) {
            Text(Self.title(plan))
                .font(.title2.weight(.bold))
            if model.dryRun {
                Label("Trockenlauf – es wird nichts entfernt.", systemImage: "flask")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if needsAck {
                let texts = Self.warningCardTexts(plan)
                SystemWarningCard(title: texts.title, toggle: texts.toggle, lines: Self.systemWarningLines(plan),
                                  acknowledged: $acknowledged)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        MethodGroupView(group: group, showsSizes: !isServices)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)

            let cleanupOptions = optionToggles(plan)
            if !cleanupOptions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(cleanupOptions) { option in
                        Toggle(isOn: binding(for: option)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.text)
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    showCommands = true
                } label: {
                    Label("Befehle anzeigen", systemImage: "terminal")
                }
                .disabled(commands.isEmpty)
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    dismiss()
                    Task { await model.execute(plan) }
                } label: {
                    Label(isServices ? "Entfernen" : "Aufräumen", systemImage: isServices ? "bolt.fill" : "sparkles")
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(Self.allowsDefaultAction(plan) ? .defaultAction : nil)
                .disabled(groups.isEmpty || model.isScanning || model.isRemoving || model.isMeasuringSystemData || model.isChecking
                          || model.isLoadingServices || (needsAck && !acknowledged))
            }
        }
        .padding(24)
        .frame(width: 600)
        .sheet(isPresented: $showCommands) {
            CommandSheet(title: isServices ? "Befehle zum Entfernen" : "Befehle zum Aufräumen", lines: commands)
        }
    }

    /// Return löst „Aufräumen“ nur aus, wenn nichts endgültig gelöscht wird und keine Admin-Schritte anstehen.
    /// Bei Systemfunden nie: dort muss das Häkchen bewusst gesetzt werden.
    nonisolated static func allowsDefaultAction(_ plan: RemovalPlan) -> Bool {
        !requiresSystemAcknowledgement(plan) && plan.deleteSteps.isEmpty && plan.adminSteps.isEmpty
    }

    /// Plant der Plan mindestens einen Systemfund oder Admin-Schritte für Hintergrunddienste, braucht „Aufräumen“
    /// das Häkchen der Warnkarte (TP4: Kategorie `services` mit Admin zählt wie `systemData`).
    nonisolated static func requiresSystemAcknowledgement(_ plan: RemovalPlan) -> Bool {
        plan.allSteps.contains { $0.0.category == .systemData }
            || plan.adminSteps.contains { $0.0.category == .services }
    }

    /// Nur Hintergrunddienste im Plan? Dann ohne Bytes („Hintergrunddienste entfernen?“, Knopf „Entfernen“).
    nonisolated static func isServicesPlan(_ plan: RemovalPlan) -> Bool {
        !plan.allSteps.isEmpty && plan.allSteps.allSatisfy { $0.0.category == .services }
    }

    /// Überschrift des Dialogs.
    nonisolated static func title(_ plan: RemovalPlan) -> String {
        isServicesPlan(plan) ? "Hintergrunddienste entfernen?" : "\(ByteFormat.string(plan.totalSize)) aufräumen?"
    }

    /// Titel und Häkchen der roten Karte: Systemfunde wie bisher, sonst (nur Hintergrunddienste) eigene Worte.
    nonisolated static func warningCardTexts(_ plan: RemovalPlan) -> (title: String, toggle: String) {
        if plan.allSteps.contains(where: { $0.0.category == .systemData }) {
            return ("Du entfernst Systemdateien", "Ich habe verstanden, dass Systemdateien entfernt werden.")
        }
        return ("Du entfernst Hintergrunddienste",
                "Ich habe verstanden, dass die Hintergrunddienste endgültig entfernt werden.")
    }

    nonisolated static let servicesAdminWarning =
        "Achtung: Die Startdateien unter /Library werden mit deinem Admin-Passwort endgültig gelöscht – nicht über den Papierkorb."

    /// Warnzeilen der geplanten Systemfunde: „Achtung: “ + volle Warnzeile (Spec §5), ohne Doppelte, in Planreihenfolge;
    /// bei Admin-Schritten für Hintergrunddienste ein Satz zu den Startdateien.
    nonisolated static func systemWarningLines(_ plan: RemovalPlan) -> [String] {
        var out: [String] = []
        for (f, _) in plan.allSteps where f.category == .systemData {
            guard let w = SystemCleanup.warning(for: f.id.scannerID) else { continue }
            let line = "Achtung: " + w
            if !out.contains(line) { out.append(line) }
        }
        if plan.adminSteps.contains(where: { $0.0.category == .services }) {
            out.append(servicesAdminWarning)
        }
        return out
    }

    // MARK: - Optionen

    private struct OptionRow: Identifiable {
        enum Kind { case deleteDirectly, zap }
        var id: String { "\(kind)-\(findingID.scannerID)-\(findingID.key)" }
        let kind: Kind
        let findingID: FindingID
        let text: String
        let detail: String
    }

    private func optionToggles(_ plan: RemovalPlan) -> [OptionRow] {
        let direct = plan.directDeleteCandidates.map { f in
            OptionRow(
                kind: .deleteDirectly, findingID: f.id,
                text: "Direkt löschen statt Papierkorb (schafft sofort Platz)",
                detail: "\(f.title) · \(f.size.map(ByteFormat.string) ?? "Größe nicht messbar")")
        }
        let casks = plan.toolSteps.map(\.0).filter { $0.id.scannerID == "brew.cask" }.map { f in
            OptionRow(kind: .zap, findingID: f.id, text: "Auch Einstellungen entfernen (zap)", detail: f.title)
        }
        return direct + casks
    }

    private func binding(for option: OptionRow) -> Binding<Bool> {
        Binding {
            switch option.kind {
            case .deleteDirectly: options.deleteDirectly.contains(option.findingID)
            case .zap: options.zap.contains(option.findingID)
            }
        } set: { on in
            switch option.kind {
            case .deleteDirectly:
                if on { options.deleteDirectly.insert(option.findingID) } else { options.deleteDirectly.remove(option.findingID) }
            case .zap:
                if on { options.zap.insert(option.findingID) } else { options.zap.remove(option.findingID) }
            }
        }
    }

    // MARK: - Gruppen je Methode

    struct MethodGroup: Identifiable {
        let id: String
        let text: String
        let symbol: String
        let emphasized: Bool
        let rows: [(title: String, count: Int, size: Int64)]
    }

    nonisolated static func groups(for plan: RemovalPlan) -> [MethodGroup] {
        func rows(_ steps: [(Finding, [FindingItem])]) -> [(title: String, count: Int, size: Int64)] {
            steps.map { f, items in (f.title, items.count, items.reduce(0) { $0 + ($1.size ?? 0) }) }
        }
        var out: [MethodGroup] = []

        // Werkzeug-Schritte nach Werkzeug (erster ToolCommand) gruppiert, Reihenfolge bleibt erhalten.
        var toolOrder: [String] = []
        var byTool: [String: [(Finding, [FindingItem])]] = [:]
        for step in plan.toolSteps {
            var tool = "Werkzeug"
            if case .tool(let commands, _) = step.0.method, let first = commands.first {
                tool = URL(filePath: first.tool).lastPathComponent
            }
            if byTool[tool] == nil { toolOrder.append(tool) }
            byTool[tool, default: []].append(step)
        }
        for tool in toolOrder {
            out.append(MethodGroup(
                id: "tool-\(tool)", text: "Über \(tool) entfernt – direkt, nicht im Papierkorb", symbol: "wrench.and.screwdriver",
                emphasized: true, rows: rows(byTool[tool] ?? [])))
        }
        if !plan.trashSteps.isEmpty {
            out.append(MethodGroup(
                id: "trash", text: "In den Papierkorb", symbol: "trash", emphasized: false,
                rows: rows(plan.trashSteps)))
        }
        if !plan.deleteSteps.isEmpty {
            out.append(MethodGroup(
                id: "delete", text: "Wird direkt gelöscht – nicht im Papierkorb", symbol: "exclamationmark.octagon",
                emphasized: true, rows: rows(plan.deleteSteps)))
        }
        if !plan.adminSteps.isEmpty {
            out.append(MethodGroup(
                id: "admin", text: "Braucht dein Admin-Passwort (eine Abfrage)", symbol: "lock",
                emphasized: true, rows: rows(plan.adminSteps)))
        }
        return out
    }
}

private struct SystemWarningCard: View {
    let title: String
    let toggle: String
    let lines: [String]
    @Binding var acknowledged: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout)
            }
            Toggle(toggle, isOn: $acknowledged)
                .toggleStyle(.checkbox)
                .fontWeight(.semibold)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.5)))
    }
}

private struct MethodGroupView: View {
    let group: ConfirmSheet.MethodGroup
    /// Hintergrunddienste haben keine Größe – dann keine Spalte „Null Byte“.
    var showsSizes = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(group.text, systemImage: group.symbol)
                .font(.headline)
                .foregroundStyle(group.emphasized ? Color.orange : Color.primary)
            ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.title)
                    Text(EntryCount.text(row.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showsSizes {
                        Text(ByteFormat.string(row.size))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
                .padding(.leading, 28)
            }
        }
    }
}
