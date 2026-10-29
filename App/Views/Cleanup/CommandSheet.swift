import AppKit
import SwiftUI

/// Zeigt kopierbare Befehle (monospaced, auswählbar) mit Knopf „Kopieren“.
struct CommandSheet: View {
    let title: String
    let lines: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var text: String { lines.joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.bold))
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(minHeight: 120, maxHeight: 360)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
            HStack {
                if copied {
                    Label("Kopiert", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    copied = true
                } label: {
                    Label("Kopieren", systemImage: "doc.on.doc")
                }
                Button("Schließen") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

#Preview {
    CommandSheet(title: "Instruments", lines: [
        "xcrun simctl runtime delete 'iOS 17.5'",
        "rm -rf '/Users/frank/Library/Application Support/Instruments'",
    ])
}
