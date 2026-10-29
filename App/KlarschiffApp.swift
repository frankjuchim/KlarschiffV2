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
            CleanupTabView(tab: model.selectedTab)
                .environment(model)
        case .systemData, .services, .performance:
            PlaceholderTab(tab: model.selectedTab)
        }
    }
}
