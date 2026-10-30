import SwiftUI

/// Kleine Verlaufslinie mit zarter Fläche darunter. Werte von 0 bis `maxValue` (größere Werte erweitern die Skala).
struct Sparkline: View {
    let values: [Double]
    var maxValue: Double = 1
    var color: Color = Theme.turquoise

    var body: some View {
        GeometryReader { geo in
            let points = Self.points(values, maxValue: maxValue, size: geo.size)
            if points.count >= 2 {
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        for pt in points { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: points[0])
                        for pt in points.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            } else {
                // Noch kein Verlauf: ruhige Grundlinie.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height - 1))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 1))
                }
                .stroke(color.opacity(0.3), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }

    /// Punkte von links nach rechts; die Skala wächst mit, falls ein Wert `maxValue` übersteigt.
    nonisolated static func points(_ values: [Double], maxValue: Double, size: CGSize) -> [CGPoint] {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return [] }
        let top = max(maxValue, values.max() ?? 0, .leastNonzeroMagnitude)
        let inset: CGFloat = 1.5
        let usable = max(0, size.height - 2 * inset)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let fraction = CGFloat(min(1, max(0, v / top)))
            return CGPoint(x: CGFloat(i) * step, y: inset + usable * (1 - fraction))
        }
    }
}

#Preview {
    Sparkline(values: [0.1, 0.3, 0.25, 0.6, 0.4, 0.45, 0.2], color: .orange)
        .frame(width: 140, height: 30)
        .padding()
}
