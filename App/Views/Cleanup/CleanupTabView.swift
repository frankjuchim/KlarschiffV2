import SwiftUI
import KlarschiffCore

/// Tab „Speicher“ bzw. „Entwickler“: Zusammenfassung, Funde je Kategorie, Behalten-Bereich.
/// Der Speicher-Tab zeigt zusätzlich Fotos, Große Brocken und den Papierkorb-Knopf.
struct CleanupTabView: View {
    let tab: AppTab
    @Environment(AppModel.self) private var model
    @State private var showConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = model.lastError {
                ErrorBanner(message: error) { model.lastError = nil }
            }
            if !model.hasFullDiskAccess {
                FullDiskAccessCard()
            }
            SummaryCard(tab: tab) { showConfirm = true }
            if let report = model.lastRemoval {
                ResultBanner(report: report)
            }
            ForEach(groups) { group in
                CategorySection(category: group.category, findings: group.findings, failures: group.failures)
            }
            if tab == .storage {
                if let photos = model.photos {
                    PhotosCard(info: photos)
                }
                if !model.bigChunks.isEmpty {
                    BigChunksCard(chunks: model.bigChunks)
                }
            }
            let kept = model.keptFindings(in: tab)
            if !kept.isEmpty {
                KeepSection(findings: kept)
            }
        }
        .sheet(isPresented: $showConfirm) {
            ConfirmSheet(tab: tab)
                .environment(model)
        }
    }

    /// Kategorien mit Funden oder Scanner-Fehlern, in Kategorie-Reihenfolge.
    private var groups: [CategoryGroup] {
        var byCategory: [KlarschiffCore.Category: CategoryGroup] = [:]
        for (category, findings) in model.findings(in: tab) {
            byCategory[category] = CategoryGroup(category: category, findings: findings, failures: [])
        }
        for failure in model.failures(in: tab) {
            let category = model.failureCategory(failure) ?? (tab == .storage ? .system : .xcode)
            byCategory[category, default: CategoryGroup(category: category, findings: [], failures: [])]
                .failures.append(failure)
        }
        return byCategory.values.sorted { $0.category.sortOrder < $1.category.sortOrder }
    }
}

private struct CategoryGroup: Identifiable {
    var id: KlarschiffCore.Category { category }
    let category: KlarschiffCore.Category
    var findings: [Finding]
    var failures: [ScanFailure]
}

/// Schließbares Fehler-Banner für `AppModel.lastError`.
struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Schließen")
        }
        .glassCard(padding: 16)
    }
}

#Preview("Speicher") {
    ScrollView {
        CleanupTabView(tab: .storage)
            .padding(32)
    }
    .frame(width: 1100, height: 900)
    .background(BackgroundView())
    .environment(AppModel.preview)
}

#Preview("Entwickler") {
    ScrollView {
        CleanupTabView(tab: .developer)
            .padding(32)
    }
    .frame(width: 1100, height: 900)
    .background(BackgroundView())
    .environment(AppModel.preview)
}
