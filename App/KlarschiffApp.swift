import SwiftUI
import KlarschiffCore

@main
struct KlarschiffApp: App {
    /// Als Test-Host (XCTest/Swift Testing) wird weder gescannt noch etwas Echtes verdrahtet.
    private static let isTestHost: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }()

    @State private var model: AppModel? = KlarschiffApp.isTestHost ? nil : AppModel(dependencies: .live())

    var body: some Scene {
        Window("Klarschiff", id: "main") {
            Group {
                if let model {
                    RootView(model: model)
                } else {
                    Text("Klarschiff (Test-Host)")
                }
            }
            .frame(minWidth: 1000, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
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
                            HeaderView()
                            TabBarView(selection: $model.selectedTab)
                        }
                        Spacer(minLength: 0)
                        CapacityCard(disk: model.disk)
                    }
                    if model.dryRun {
                        Label("Trockenlauf: Es wird nichts entfernt.", systemImage: "flask")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
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
            await model.scan(includeSlowChecks: false)
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch model.selectedTab {
        case .storage, .developer:
            TemporaryFindingsList(model: model, tab: model.selectedTab)
        case .systemData, .services, .performance:
            PlaceholderTab(tab: model.selectedTab)
        }
    }
}

/// Vorläufige Fundliste (Titel + Größe je Fund); Task 17 ersetzt sie durch `CleanupTabView`.
struct TemporaryFindingsList: View {
    let model: AppModel
    let tab: AppTab

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ByteFormat.string(model.selectedSize(in: tab)))
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("ausgewählt von \(ByteFormat.string(model.foundSize(in: tab))) gefunden")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isScanning {
                    ProgressView(value: model.scanProgress) {
                        Text("Scanne …").font(.callout)
                    }
                    .frame(width: 200)
                }
            }
            .glassCard(padding: 24)

            ForEach(model.findings(in: tab), id: \.0) { category, findings in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(category.title, systemImage: category.symbol)
                            .font(.title3.weight(.bold))
                        Spacer()
                        Text(ByteFormat.string(findings.reduce(0) { $0 + ($1.size ?? 0) }))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    VStack(spacing: 0) {
                        ForEach(findings) { finding in
                            HStack {
                                Image(systemName: model.isSelected(finding.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.isSelected(finding.id) ? Theme.violet : .secondary)
                                Text(finding.title)
                                Text(finding.risk.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(finding.size.map(ByteFormat.string) ?? "–")
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .glassCard(padding: 16)
                }
            }
        }
    }
}
