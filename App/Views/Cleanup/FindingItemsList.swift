import AppKit
import SwiftUI
import KlarschiffCore

/// Aufgeklappte Einträge eines Fundes: Einzelauswahl, Name/Pfad, Datum, Größe, Lupe (im Finder zeigen).
struct FindingItemsList: View {
    let finding: Finding
    /// Ob Einträge einzeln auswählbar sind (nicht bei Hinweisen oder fehlendem Vollzugriff).
    let selectable: Bool

    var body: some View {
        if finding.items.count > 12 {
            ScrollView {
                rows.padding(.trailing, 8)
            }
            .frame(maxHeight: 360)
        } else {
            rows
        }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(finding.items) { item in
                ItemRow(findingID: finding.id, item: item, selectable: selectable)
            }
        }
    }
}

private struct ItemRow: View {
    let findingID: FindingID
    let item: FindingItem
    let selectable: Bool
    @Environment(AppModel.self) private var model

    private static let dateStyle = Date.FormatStyle(date: .numeric, time: .omitted)
        .locale(Locale(identifier: "de_DE"))

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if selectable {
                if item.blockingApp == nil {
                    let on = model.selection[findingID]?.contains(item.id) ?? false
                    SelectionCircle(state: on ? .on : .off, size: 17) { model.toggleItem(findingID, item: item.id) }
                        .frame(width: 22)
                } else {
                    Image(systemName: "circle.slash")
                        .font(.system(size: 17))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22)
                        .accessibilityLabel("Gesperrt")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let app = item.blockingApp {
                        BlockingWarning(apps: [app])
                    }
                }
                if let secondary = item.url?.path ?? item.detail, secondary != item.name {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            if let date = item.date {
                Text(date.formatted(Self.dateStyle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(item.size.map(ByteFormat.string) ?? "Größe nicht messbar")
                .font(item.size == nil ? .caption : .callout.weight(.semibold))
                .foregroundStyle(item.size == nil ? .secondary : .primary)
                .monospacedDigit()
                .frame(minWidth: 80, alignment: .trailing)
            if let url = item.url {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Im Finder zeigen")
                .accessibilityLabel("Im Finder zeigen")
            } else {
                Color.clear.frame(width: 16, height: 1)
            }
        }
    }
}
