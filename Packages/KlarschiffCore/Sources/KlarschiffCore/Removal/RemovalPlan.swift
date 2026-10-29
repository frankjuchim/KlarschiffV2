import Foundation

public struct RemovalOptions: Sendable {
    /// P > 10 GB: im Dialog gewählt, direkt löschen statt in den Papierkorb.
    public var deleteDirectly: Set<FindingID>
    public var zap: Set<FindingID>
    public var dryRun: Bool

    public init(deleteDirectly: Set<FindingID> = [], zap: Set<FindingID> = [], dryRun: Bool = false) {
        self.deleteDirectly = deleteDirectly
        self.zap = zap
        self.dryRun = dryRun
    }
}

public struct RemovalPlan: Sendable {
    public static let directDeleteThreshold: Int64 = 10_000_000_000

    public var toolSteps: [(Finding, [FindingItem])] = []
    public var trashSteps: [(Finding, [FindingItem])] = []
    public var deleteSteps: [(Finding, [FindingItem])] = []
    public var adminSteps: [(Finding, [FindingItem])] = []
    public var totalSize: Int64 = 0
    public var directDeleteCandidates: [Finding] = []
    public let options: RemovalOptions

    public var needsAdmin: Bool { !adminSteps.isEmpty }

    public init(findings: [Finding], selection: [FindingID: Set<String>], options: RemovalOptions) {
        self.options = options
        for finding in findings {
            if case .hint = finding.method { continue }
            guard let selected = selection[finding.id], !selected.isEmpty else { continue }
            let items = finding.items.filter { selected.contains($0.id) }
            guard !items.isEmpty else { continue }
            totalSize += items.reduce(0) { $0 + ($1.size ?? 0) }

            switch finding.method {
            case .tool(let commands, let fallback):
                var planned = finding
                if options.zap.contains(finding.id) {
                    let zapped = commands.map { c -> ToolCommand in
                        guard c.tool == "brew", c.arguments.starts(with: ["uninstall", "--cask"]),
                              !c.arguments.contains("--zap") else { return c }
                        var copy = c
                        copy.arguments.append("--zap")
                        return copy
                    }
                    planned = Self.copy(finding, method: .tool(zapped, fallback: fallback))
                }
                toolSteps.append((planned, items))
            case .trash:
                let candidate = finding.risk == .review && (finding.size ?? 0) > Self.directDeleteThreshold
                if candidate { directDeleteCandidates.append(finding) }
                if candidate, options.deleteDirectly.contains(finding.id) {
                    deleteSteps.append((finding, items))
                } else {
                    trashSteps.append((finding, items))
                }
            case .delete: deleteSteps.append((finding, items))
            case .admin: adminSteps.append((finding, items))
            case .hint: break
            }
        }
    }

    private static func copy(_ f: Finding, method: RemovalMethod) -> Finding {
        Finding(id: f.id, category: f.category, title: f.title, summary: f.summary, risk: f.risk, method: method,
                items: f.items, size: f.size, blockingApps: f.blockingApps, keepSuggested: f.keepSuggested,
                commandPreview: f.commandPreview, needsFullDiskAccess: f.needsFullDiskAccess, watchedApps: f.watchedApps)
    }

    /// Kopierbare Befehle in Ausführungsreihenfolge (Werkzeug → Papierkorb → Löschen → Admin).
    public var commandPreview: [String] {
        var out: [String] = []
        for (f, _) in toolSteps {
            if case .tool(let cmds, _) = f.method { out += cmds.map(\.display) }
        }
        for (_, items) in trashSteps {
            out += items.compactMap { $0.url.map { "In den Papierkorb: \($0.path)" } }
        }
        for (_, items) in deleteSteps {
            out += items.compactMap { $0.url.map { "rm -rf " + ShellQuote.quote($0.path) } }
        }
        for (f, items) in adminSteps {
            guard case .admin(let steps) = f.method else { continue }
            let mine: [AdminStep]
            if steps.count == f.items.count {
                let ids = Set(items.map(\.id))
                mine = zip(f.items, steps).filter { ids.contains($0.0.id) }.map(\.1)
            } else {
                mine = steps
            }
            out += mine.map { "sudo " + ([$0.executable] + $0.arguments).map(ShellQuote.quote).joined(separator: " ") }
        }
        return out
    }
}
