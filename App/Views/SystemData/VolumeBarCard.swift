import SwiftUI
import KlarschiffCore

/// Kopfkarte: gestapelter Balken über den Datenträger, Legende mit Größen, Erklärsatz, „Neu messen“.
struct VolumeBarCard: View {
    @Environment(AppModel.self) private var model

    static let explanation = "Die Zahl ‚Systemdaten‘ in den Systemeinstellungen entspricht ungefähr Systembereiche + Schnappschüsse + Auslagerung. macOS rechnet etwas anders – kleine Abweichungen sind normal."
    static let noInventoryNote = "Datenträger konnte nicht gelesen werden – der Balken zeigt nur die gemessenen Bereiche."

    private var busy: Bool { model.isScanning || model.isRemoving || model.isMeasuringSystemData }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Woraus besteht dein Datenträger?")
                        .font(.title2.weight(.bold))
                    if let report = model.systemData, !model.isMeasuringSystemData {
                        Text("Gemessen um \(Self.timeText(report.measuredAt))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 16)
                Button {
                    Task { await model.measureSystemData() }
                } label: {
                    Label("Neu messen", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(busy)
            }

            if model.isMeasuringSystemData {
                ProgressView(value: model.systemDataProgress) {
                    Text("Messe Systemdaten …").font(.callout)
                }
                .tint(Theme.violet)
            } else if model.systemData == nil {
                Text(model.isScanning || model.isRemoving
                     ? "Die Messung startet, sobald Klarschiff 2 mit dem Scannen fertig ist."
                     : "Noch nicht gemessen.")
                    .foregroundStyle(.secondary)
            }

            if let report = model.systemData {
                let segments = Self.segments(report)
                StackedBar(segments: segments)
                Legend(segments: Self.legendSegments(segments))
                if let note = Self.simulatorNote(report) {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if report.inventory == nil {
                    Label(Self.noInventoryNote, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(Self.notes(report).enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(Self.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard(padding: 28)
    }

    private static let timeStyle = Date.FormatStyle(locale: Locale(identifier: "de_DE"))
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    static func timeText(_ date: Date) -> String { date.formatted(timeStyle) }

    /// Segmente laut Spec §4.1, Summe = Container; ohne Inventar nur die gemessenen Bereiche.
    /// Simulator-Volumes sind Disk-Images in AssetsV2 (schon in „Systembereiche“) und daher kein eigenes Segment.
    static func segments(_ r: SystemDataReport) -> [BarSegment] {
        var out: [BarSegment] = []
        func add(_ title: String, _ bytes: Int64, _ color: Color, prefix: String? = nil) {
            out.append(BarSegment(title: title, bytes: max(0, bytes), color: color, prefix: prefix))
        }
        let userPrefix = r.userDataIsLowerBound ? "mindestens" : nil
        guard let inv = r.inventory else {
            add("Deine Daten", r.userData, Theme.turquoise, prefix: userPrefix)
            add("Systembereiche", r.systemAreasTotal, Theme.violet)
            return out
        }
        func consumed(_ roles: Set<VolumeRole>) -> Int64 {
            inv.volumes.filter { roles.contains($0.role) }.reduce(0) { $0 + $1.consumed }
        }
        add("macOS-System", consumed([.system, .preboot, .recovery]), Color(hex: 0x6B7A99))
        add("Auslagerung (VM)", consumed([.vm]), Color(hex: 0xA0AEC8))
        add("Deine Daten", r.userData, Theme.turquoise, prefix: userPrefix)
        add("Systembereiche", r.systemAreasTotal, Theme.violet)
        add("Schnappschüsse & nicht zuordenbar", r.unaccounted, Color(hex: 0xE8A33D),
            prefix: r.unaccountedIsUpperBound ? "höchstens" : nil)
        add("Frei", inv.containerFree, Color.primary.opacity(0.08))
        return out
    }

    /// „Simulator-Volumes: X (bereits in Systembereichen enthalten)“, nur wenn welche existieren.
    static func simulatorNote(_ r: SystemDataReport) -> String? {
        guard let inv = r.inventory else { return nil }
        let sims = inv.volumes.filter { $0.role == .simulator } + inv.simulatorVolumes
        let bytes = sims.reduce(Int64(0)) { $0 + $1.consumed }
        guard !sims.isEmpty, bytes > 0 else { return nil }
        return "Simulator-Volumes: \(ByteFormat.string(bytes)) (bereits in Systembereichen enthalten)"
    }

    /// Legende ohne leere Segmente; „Frei“ bleibt immer.
    static func legendSegments(_ segments: [BarSegment]) -> [BarSegment] {
        segments.filter { $0.bytes > 0 || $0.title == "Frei" }
    }

    /// Hinweise aus der Messung, die nicht schon an einem Bereich stehen (Volumes, nicht zugeordnet, Schnappschüsse, Aufräum-Funde).
    static func notes(_ r: SystemDataReport) -> [String] {
        let labels = [
            "sysdata.temp": "Temporäre Dateien", "sysdata.libraryCaches": "Systemweite Caches",
            "sysdata.libraryLogs": "System-Protokolle", "sysdata.unifiedLog": "Diagnosedaten",
            "sysdata.macUpdate": "macOS-Update", "system.snapshots": "Schnappschüsse",
        ]
        return r.failures.compactMap { f in
            if f.scannerID == "systemdata.unaccounted" { return r.inventory == nil ? nil : f.message }
            if f.scannerID == "systemdata.volumes" { return r.inventory == nil ? nil : f.message }
            if let label = labels[f.scannerID] { return "\(label): \(f.message)" }
            return nil
        }
    }
}

struct BarSegment: Identifiable {
    var id: String { title }
    let title: String
    let bytes: Int64
    let color: Color
    /// „mindestens“ / „höchstens“ vor der Größe.
    let prefix: String?

    var sizeText: String {
        let s = ByteFormat.string(bytes)
        return prefix.map { "\($0) \(s)" } ?? s
    }
}

/// Gestapelter Balken; Segmentbreite proportional zur Summe aller Segmente.
private struct StackedBar: View {
    let segments: [BarSegment]

    var body: some View {
        let visible = segments.filter { $0.bytes > 0 }
        let total = max(1, visible.reduce(Int64(0)) { $0 + $1.bytes })
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let usable = max(0, geo.size.width - spacing * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: spacing) {
                ForEach(visible) { s in
                    Rectangle()
                        .fill(s.color)
                        .frame(width: usable * CGFloat(Double(s.bytes) / Double(total)))
                        .help("\(s.title): \(s.sizeText)")
                }
            }
            .clipShape(.capsule)
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(visible.map { "\($0.title) \($0.sizeText)" }.joined(separator: ", "))
    }
}

/// Legende: Farbpunkt, Name, Größe.
private struct Legend: View {
    let segments: [BarSegment]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(segments) { s in
                HStack(spacing: 8) {
                    Circle()
                        .fill(s.color)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                        .frame(width: 10, height: 10)
                    Text(s.title)
                    Text(s.sizeText)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.callout)
            }
        }
    }
}
