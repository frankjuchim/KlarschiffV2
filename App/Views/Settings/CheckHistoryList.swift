import SwiftUI
import KlarschiffCore

/// Anzeigetexte einer Verlaufszeile: Datum, aufräumbar, frei, Auffälligkeiten als kurze Texte.
struct CheckHistoryRow: Equatable {
    var date: String
    var cleanable: String
    var free: String
    /// Wachstum zuerst, dann knapper Speicher. „Aufräumbar“ steht schon in `cleanable` und fehlt hier.
    var alerts: [String]

    init(_ s: CheckSnapshot, timeZone: TimeZone = .current) {
        let style = Date.FormatStyle(locale: Locale(identifier: "de_DE"), timeZone: timeZone)
            .weekday(.abbreviated).day().month(.abbreviated).year().hour().minute()
        date = s.date.formatted(style)
        cleanable = "\(ByteFormat.string(s.cleanableTotal)) aufräumbar"
        free = "\(ByteFormat.string(s.freeBytes)) frei"
        var growth: [String] = []
        var low: [String] = []
        for alert in s.alerts {
            switch alert {
            case .growth(_, let title, let from, let to): growth.append("\(title) +\(ByteFormat.string(to - from))")
            case .lowSpace(let free, _): low.append("Nur noch \(ByteFormat.string(free)) frei")
            case .cleanable: break
            }
        }
        alerts = growth + low
    }

    /// Neueste zuerst.
    static func sorted(_ history: [CheckSnapshot]) -> [CheckSnapshot] {
        history.sorted { $0.date > $1.date }
    }
}

/// Verlauf des automatischen Checks (neueste zuerst).
struct CheckHistoryList: View {
    let history: [CheckSnapshot]

    var body: some View {
        if history.isEmpty {
            Text("Noch kein Check gelaufen.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(CheckHistoryRow.sorted(history).enumerated()), id: \.offset) { _, snapshot in
                let row = CheckHistoryRow(snapshot)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.date)
                            .fontWeight(.medium)
                        Spacer(minLength: 12)
                        Text("\(row.cleanable) · \(row.free)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ForEach(row.alerts, id: \.self) { alert in
                        Label(alert, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
