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

    var body: some View {
        let plan = model.makePlan(tab: tab, options: options)
        let groups = Self.groups(for: plan)
        VStack(alignment: .leading, spacing: 16) {
            Text("\(ByteFormat.string(plan.totalSize)) aufräumen?")
                .font(.title2.weight(.bold))
            if model.dryRun {
                Label("Trockenlauf – es wird nichts entfernt.", systemImage: "flask")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        MethodGroupView(group: group)
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
                .disabled(plan.commandPreview.isEmpty)
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    dismiss()
                    Task { await model.execute(plan) }
                } label: {
                    Label("Aufräumen", systemImage: "sparkles")
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(Self.allowsDefaultAction(plan) ? .defaultAction : nil)
                .disabled(groups.isEmpty || model.isScanning || model.isRemoving)
            }
        }
        .padding(24)
        .frame(width: 600)
        .sheet(isPresented: $showCommands) {
            CommandSheet(title: "Befehle zum Aufräumen", lines: plan.commandPreview)
        }
    }

    /// Return löst „Aufräumen“ nur aus, wenn nichts endgültig gelöscht wird und keine Admin-Schritte anstehen.
    nonisolated static func allowsDefaultAction(_ plan: RemovalPlan) -> Bool {
        plan.deleteSteps.isEmpty && plan.adminSteps.isEmpty
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

private struct MethodGroupView: View {
    let group: ConfirmSheet.MethodGroup

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
                    Text(ByteFormat.string(row.size))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .padding(.leading, 28)
            }
        }
    }
}
