import SwiftUI
import KlarschiffCore

/// Tab „Systemdaten“ (Spec §4): Kopfkarte mit Balken, Schnappschüsse, Bereichsliste mit Aufräum-Karten,
/// Zusammenfassungsleiste unten. Misst beim ersten Öffnen pro App-Start.
struct SystemDataTabView: View {
    @Environment(AppModel.self) private var model
    @State private var showConfirm = false

    private var busy: Bool { model.isScanning || model.isRemoving }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = model.lastError {
                ErrorBanner(message: error) { model.lastError = nil }
            }
            if !model.hasFullDiskAccess {
                FullDiskAccessCard()
            }
            VolumeBarCard()
            if let report = model.lastRemoval {
                ResultBanner(report: report)
            }
            if let report = model.systemData {
                if SnapshotCard.isVisible(report) {
                    SnapshotCard(report: report)
                }
                let byArea = SystemAreaFindings.byArea(model.findings(in: .systemData).flatMap(\.1), areas: report.areas)
                ForEach(SystemAreaFindings.sortedBySize(report.areas)) { area in
                    SystemAreaCard(area: area, findings: byArea)
                }
                // Funde ohne passenden Bereich (z. B. Bereich nicht messbar) bleiben trotzdem erreichbar.
                ForEach(Self.unplaced(byArea, areas: report.areas)) { finding in
                    SystemCleanupCard(finding: finding)
                }
                let kept = model.keptFindings(in: .systemData)
                if !kept.isEmpty {
                    KeepSection(findings: kept)
                }
                SystemDataSummaryBar { showConfirm = true }
            }
        }
        .task { await model.measureSystemDataIfNeeded() }
        // Der erste Versuch kann an einem laufenden Scan/Aufräumen scheitern: danach erneut versuchen.
        .onChange(of: busy) { _, isBusy in
            guard !isBusy else { return }
            Task { await model.measureSystemDataIfNeeded() }
        }
        .sheet(isPresented: $showConfirm) {
            ConfirmSheet(tab: .systemData)
                .environment(model)
        }
    }

    /// Funde, deren Bereich in der Liste fehlt.
    private static func unplaced(_ byArea: [String: [Finding]], areas: [SystemArea]) -> [Finding] {
        var ids = Set<String>()
        func collect(_ a: SystemArea) { ids.insert(a.id); a.children.forEach(collect) }
        areas.forEach(collect)
        return byArea.filter { !ids.contains($0.key) }.values.flatMap { $0 }
            .sorted { $0.id.scannerID < $1.id.scannerID }
    }
}

/// Zusammenfassungsleiste: ausgewählte Größe und „Aufräumen“ (öffnet den Bestätigungsdialog).
private struct SystemDataSummaryBar: View {
    let onCleanup: () -> Void
    @Environment(AppModel.self) private var model

    private var busy: Bool { model.isScanning || model.isRemoving || model.isMeasuringSystemData }

    private var hasSelection: Bool {
        model.findings(in: .systemData).contains { _, findings in findings.contains { model.isSelected($0.id) } }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ByteFormat.string(model.selectedSize(in: .systemData)))
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("ausgewählt")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if model.isRemoving {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.removalProgress ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: onCleanup) {
                Label("Aufräumen", systemImage: "sparkles")
            }
            .buttonStyle(GradientButtonStyle())
            .disabled(busy || !hasSelection)
        }
        .glassCard(padding: 20)
    }
}

#Preview("Systemdaten") {
    ScrollView {
        SystemDataTabView()
            .padding(32)
    }
    .frame(width: 1100, height: 900)
    .background(BackgroundView())
    .environment(AppModel.preview)
}
