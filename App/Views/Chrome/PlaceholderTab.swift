import SwiftUI
import KlarschiffCore

/// Freundliche Platzhalter-Karte für Tabs, die in späteren Teilprojekten kommen.
struct PlaceholderTab: View {
    let tab: AppTab

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: tab.symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(tab.title)
                    .font(.title2.weight(.bold))
                Text(Self.text(for: tab))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .glassCard(padding: 24)
    }

    static func text(for tab: AppTab) -> String {
        switch tab {
        case .systemData: "Kommt bald: Hier erklärt Klarschiff, woraus ‚Systemdaten‘ besteht."
        case .services: "Kommt bald: Hier siehst du, welche Hintergrunddienste und Agents laufen – und kannst aufräumen."
        case .performance: "Kommt bald: Tipps und Werkzeuge, damit dein Mac wieder flott läuft."
        case .storage, .developer: ""
        }
    }
}
