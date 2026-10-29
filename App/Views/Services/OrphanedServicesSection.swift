import SwiftUI
import KlarschiffCore

/// Abschnitt „Verwaist“: Dienste, deren Programm bzw. App fehlt. Nur entfernbare Einträge haben einen Auswahlkreis.
struct OrphanedServicesSection: View {
    let items: [LaunchItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ServicesSectionHeader(
                title: "Verwaist", symbol: "exclamationmark.triangle.fill", style: AnyShapeStyle(Color.orange),
                count: items.count)
            ServiceList(items: items, orphaned: true)
        }
    }
}

#Preview("Verwaist") {
    let home = URL(filePath: "/Users/vorschau")
    OrphanedServicesSection(items: [
        LaunchItem(
            id: "user/com.example.helper", label: "com.example.helper", scope: .user,
            plistURL: home.appending(path: "Library/LaunchAgents/com.example.helper.plist"),
            programPath: "/Applications/Example.app/Contents/MacOS/Helper", startKind: .atLogin, isRunning: true,
            isOrphaned: true, displayName: "Helper",
            explanation: "Das Programm fehlt: /Applications/Example.app/Contents/MacOS/Helper. Die App wurde vermutlich gelöscht."),
    ])
    .padding(32)
    .frame(width: 1000)
    .background(BackgroundView())
    .environment(AppModel.preview)
}
