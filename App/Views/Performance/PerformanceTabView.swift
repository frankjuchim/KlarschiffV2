import SwiftUI
import KlarschiffCore

/// Tab „Leistung“ (Spec TP5 §4): Kachelreihe, „Was bremst gerade?“, „Aktivste Apps & Dienste“,
/// „Spotlight entlasten“, „Was Klarschiff 2 bewusst nicht tut“. Gemessen wird nur, solange der Tab sichtbar ist.
struct PerformanceTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let performance = model.performance
        VStack(alignment: .leading, spacing: 20) {
            MetricTiles(performance: performance)
            VStack(alignment: .leading, spacing: 14) {
                PerformanceSectionHeader(title: "Was bremst gerade?", symbol: "gauge.with.dots.needle.67percent")
                HintsSection(hints: performance.hints)
            }
            VStack(alignment: .leading, spacing: 14) {
                PerformanceSectionHeader(title: "Aktivste Apps & Dienste", symbol: "cpu")
                ActivityList(entries: performance.top)
            }
            SpotlightCard(performance: performance)
            RestraintCard()
        }
        .onAppear {
            performance.start()
            // Unstrukturiert: ein Tabwechsel darf die Suche nicht abbrechen.
            Task { await performance.scanSpotlightIfNeeded() }
        }
        .onDisappear { performance.stop() }
    }

    // MARK: - Texte der Kacheln

    /// „30 %“; vor der ersten Messung (noch kein Delta) „–“.
    nonisolated static func cpuValueText(load: Double, hasValue: Bool) -> String {
        guard hasValue else { return "–" }
        return "\(Int((min(1, max(0, load)) * 100).rounded())) %"
    }

    /// Arbeitsspeicher: großer Wert „10,6 GB“, Fußzeile „von 16 GB · entspannt“ (vor der ersten Messung „–“).
    nonisolated static func memoryTexts(used: UInt64, total: UInt64, pressure: Int) -> (value: String, footnote: String) {
        guard total > 0 else { return ("–", " ") }
        return (ByteFormat.memoryString(Int64(clamping: used)),
                "von \(ByteFormat.memoryString(Int64(clamping: total))) · \(PerformanceWords.memory(pressure: pressure))")
    }

    /// Ausgelagert: „354,8 MB“ bzw. „0 Byte“, Wort „nichts“/„wenig“/„viel“.
    nonisolated static func swapTexts(_ bytes: UInt64, measured: Bool) -> (value: String, footnote: String) {
        guard measured else { return ("–", " ") }
        return (ByteFormat.memoryString(Int64(clamping: bytes)), PerformanceWords.swap(bytes))
    }
}

/// Die vier Glas-Kacheln.
private struct MetricTiles: View {
    let performance: PerformanceModel

    var body: some View {
        let measured = performance.memoryTotal > 0
        let memory = PerformanceTabView.memoryTexts(
            used: performance.memoryUsed, total: performance.memoryTotal, pressure: performance.pressureLevel)
        let swap = PerformanceTabView.swapTexts(performance.swapUsed, measured: measured)
        HStack(alignment: .top, spacing: 16) {
            MetricTile(
                title: "Prozessor",
                value: PerformanceTabView.cpuValueText(load: performance.cpuLoad, hasValue: !performance.cpuHistory.isEmpty),
                footnote: performance.cpuHistory.isEmpty ? " " : PerformanceWords.cpu(performance.cpuLoad)
            ) {
                Sparkline(values: performance.cpuHistory, maxValue: 1,
                          color: performance.cpuLoad >= 0.7 ? .orange : Theme.turquoise)
            }
            MetricTile(title: "Arbeitsspeicher", value: memory.value, footnote: memory.footnote) {
                FractionBar(
                    fraction: measured ? Double(performance.memoryUsed) / Double(performance.memoryTotal) : 0,
                    fill: AnyShapeStyle(performance.pressureLevel >= 2 ? Color.orange : Color(hex: 0x1F9D55)))
            }
            MetricTile(title: "Ausgelagert", value: swap.value, footnote: swap.footnote) {
                FractionBar(
                    fraction: Double(performance.swapUsed) / 2_147_483_648 * 0.5,
                    fill: AnyShapeStyle(Theme.violet))
            }
            UptimeTile(bootTime: performance.bootTime)
        }
    }
}

/// „Seit Neustart“: aktualisiert sich jede Minute selbst (der Startzeitpunkt ändert sich ja nicht).
private struct UptimeTile: View {
    let bootTime: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let uptime = bootTime.map { PerformanceWords.uptime(since: $0, now: context.date) }
            MetricTile(title: "Seit Neustart", value: uptime?.value ?? "–", footnote: uptime?.word ?? " ")
        }
    }
}

/// Hinweise als Karten oder „Gerade bremst nichts.“
private struct HintsSection: View {
    let hints: [SlowdownHint]

    var body: some View {
        if hints.isEmpty {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(hex: 0x1F9D55))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gerade bremst nichts.")
                        .fontWeight(.semibold)
                    Text("Klarschiff 2 meldet sich erst, wenn etwas über Minuten auffällt.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .glassCard(padding: 20)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(hints) { hint in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hint.title)
                                .fontWeight(.semibold)
                            Text(hint.text)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .glassCard(padding: 20)
                }
            }
        }
    }
}

/// Abschnittsüberschrift mit Verlaufs-Symbol (wie in den anderen Tabs).
struct PerformanceSectionHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accentGradient)
            Text(title)
                .font(.title2.weight(.bold))
        }
        .padding(.horizontal, 4)
    }
}

#Preview("Leistung") {
    ScrollView {
        PerformanceTabView()
            .padding(32)
    }
    .frame(width: 1100, height: 1000)
    .background(BackgroundView())
    .environment(AppModel.preview)
}
