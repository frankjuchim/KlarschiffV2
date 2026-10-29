import SwiftUI
import KlarschiffCore

/// Pillen-Tabs; der aktive Tab hat eine Verlaufsfüllung.
struct TabBarView: View {
    @Binding var selection: AppTab

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    pill(tab)
                }
            }
            .padding(5)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private func pill(_ tab: AppTab) -> some View {
        let active = tab == selection
        return Button {
            withAnimation(.snappy) { selection = tab }
        } label: {
            Label(tab.title, systemImage: tab.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if active {
                        Capsule()
                            .fill(Theme.accentGradient)
                            .shadow(color: Theme.violet.opacity(0.25), radius: 6, y: 2)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
