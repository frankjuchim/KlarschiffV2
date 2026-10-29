import SwiftUI

/// Pastell-Hintergrund wie Klarschiff 1: große, weichgezeichnete Farbkreise auf hellem Grund.
struct BackgroundView: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let d = max(w, h)
            ZStack {
                Theme.canvas
                blob(0x7FE3D8, size: d * 0.55, x: w * 0.02, y: h * 0.25)
                blob(0xB9A6FF, size: d * 0.6, x: w * 0.95, y: h * 0.35)
                blob(0xF7B8E0, size: d * 0.45, x: w * 0.08, y: h * 0.98)
                blob(0xA9C8FF, size: d * 0.5, x: w * 0.6, y: h * 0.85)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func blob(_ hex: UInt32, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(Color(hex: hex).opacity(0.75))
            .frame(width: size, height: size)
            .blur(radius: size * 0.22)
            .position(x: x, y: y)
    }
}
