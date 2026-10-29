import SwiftUI

extension Color {
    /// Farbe aus einem 24-Bit-Hexwert, z. B. `Color(hex: 0x7FE3D8)`.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// Gemeinsame Farben und Maße des Klarschiff-Looks (Spec 4.1).
enum Theme {
    static let canvas = Color(hex: 0xF4F5FB)
    static let turquoise = Color(hex: 0x2EC4B6)
    static let violet = Color(hex: 0x7B61FF)
    static let accentGradient = LinearGradient(colors: [turquoise, violet], startPoint: .leading, endPoint: .trailing)
    static let cardRadius: CGFloat = 22
    static let maxContentWidth: CGFloat = 1250
}

extension View {
    /// Liquid-Glass-Karte mit Standard-Innenabstand.
    func glassCard(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardRadius))
    }
}
