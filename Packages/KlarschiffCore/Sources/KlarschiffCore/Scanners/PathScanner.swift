import Foundation
import Darwin

/// Generischer Scanner für eine deklarative `PathRule`.
///
/// Muster werden komponentenweise auf dem echten Dateisystem aufgelöst (nur die nötigen Ordner werden gelistet).
/// Symlinks werden nie verfolgt oder angeboten; versteckte Einträge treffen nur Musterkomponenten,
/// die selbst mit „.“ beginnen oder wörtlich sind.
public struct PathScanner: Scanner {
    public let rule: PathRule

    public init(rule: PathRule) { self.rule = rule }

    public var id: String { rule.id }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let blocking = ctx.runningApps.running(rule.blockingApps)

        if rule.needsFullDiskAccess && !ctx.hasFullDiskAccess {
            return [makeFinding(key: "all", title: rule.title, items: [], size: nil,
                                blocking: blocking, ctx: ctx, needsFullDiskAccess: true)]
        }

        let base = baseURL(ctx)
        var seen = Set<String>()
        var matches: [URL] = []
        for pattern in rule.patterns {
            try Task.checkCancellation()
            for url in try Self.resolve(pattern, base: base, exclude: rule.excludeNames)
            where seen.insert(url.path).inserted {
                matches.append(url)
            }
        }

        var groups: [(match: URL, items: [FindingItem])] = []
        for match in matches {
            let targets: [URL]
            if let days = rule.minAgeDays {
                let cutoff = ctx.now.addingTimeInterval(-Double(days) * 86_400)
                targets = try Self.files(under: match, olderThan: cutoff, exclude: rule.excludeNames)
            } else {
                targets = [match]
            }
            guard !targets.isEmpty else { continue }
            let sizes = try await ctx.sizer.sizes(of: targets)
            var items = targets.compactMap { url -> FindingItem? in
                let size = sizes[url] ?? 0
                guard size >= rule.minSize else { return nil }
                return FindingItem(id: url.path, url: url, name: url.lastPathComponent, size: size)
            }
            guard !items.isEmpty else { continue }
            // Begleitdateien gehören zum Treffer und zählen unabhängig von `minSize` mit.
            for companion in companions(of: match) where seen.insert(companion.path).inserted {
                let size = try await ctx.sizer.size(of: companion)
                items.append(FindingItem(id: companion.path, url: companion, name: companion.lastPathComponent, size: size))
            }
            groups.append((match, items))
        }

        switch rule.grouping {
        case .single:
            let items = Self.dated(groups.flatMap(\.items), rule.itemDate)
            guard !items.isEmpty else { return [] }
            return [makeFinding(key: "all", title: rule.title, items: items,
                                size: Self.total(items), blocking: blocking, ctx: ctx)]
        case .perMatch:
            return groups.map { group in
                makeFinding(key: group.match.path, title: "\(rule.title): \(matchName(group.match))",
                            items: group.items, size: Self.total(group.items), blocking: blocking, ctx: ctx)
            }
        }
    }

    // MARK: - Fund bauen

    private func makeFinding(
        key: String, title: String, items: [FindingItem], size: Int64?, blocking: [AppRef],
        ctx: ScanContext, needsFullDiskAccess: Bool = false
    ) -> Finding {
        let method = effectiveMethod(ctx, firstURL: items.first?.url)
        // Ein Hinweis ist nie entfernbar und darf daher nie vorausgewählt sein.
        let risk: Risk
        if case .hint = method { risk = .hintOnly } else { risk = rule.risk }
        return Finding(
            id: FindingID(scannerID: rule.id, key: key), category: rule.category, title: title,
            summary: rule.summary, risk: risk, method: method, items: items, size: size,
            blockingApps: blocking, keepSuggested: false,
            commandPreview: Self.preview(method, items: items), needsFullDiskAccess: needsFullDiskAccess,
            watchedApps: rule.blockingApps)
    }

    /// Werkzeug fehlt → Fallback (ohne Fallback: Hinweis). Hinweise ohne Aktion zeigen den ersten Eintrag im Finder.
    private func effectiveMethod(_ ctx: ScanContext, firstURL: URL?) -> RemovalMethod {
        let reveal: RemovalMethod = firstURL.map { .hint(.revealInFinder($0)) } ?? .hint(nil)
        switch rule.method {
        case .tool(let commands, let fallback):
            if commands.allSatisfy({ ctx.tools.path(for: $0.tool) != nil }) { return rule.method }
            switch fallback {
            case .delete: return .delete
            case .trash: return .trash
            case nil: return reveal
            }
        case .hint(nil):
            return reveal
        default:
            return rule.method
        }
    }

    /// Vorhandene Begleitdateien `<stem>.<ext>` neben dem Treffer (ohne Symlinks).
    private func companions(of match: URL) -> [URL] {
        let stem = match.deletingPathExtension().lastPathComponent
        let dir = match.deletingLastPathComponent()
        return rule.companionExtensions.compactMap { ext in
            let url = dir.appending(path: "\(stem).\(ext)")
            guard url.path != match.path, let type = Self.entryType(url), type != .typeSymbolicLink else { return nil }
            return url
        }
    }

    static func preview(_ method: RemovalMethod, items: [FindingItem]) -> [String] {
        let urls = items.compactMap(\.url)
        switch method {
        case .trash: return urls.map { "In den Papierkorb: \($0.path)" }
        case .delete: return urls.map { "rm -rf " + ShellQuote.quote($0.path) }
        case .tool(let commands, _): return commands.map(\.display)
        case .admin, .hint: return []
        }
    }

    private func matchName(_ url: URL) -> String {
        let name = url.lastPathComponent
        switch rule.matchName {
        case .lastComponent:
            return name
        case .withoutExtension:
            let stripped = url.deletingPathExtension().lastPathComponent
            return stripped.isEmpty ? name : stripped
        case .huggingFace:
            guard let r = name.range(of: "--") else { return name }
            let rest = name[r.upperBound...]
            return rest.isEmpty ? name : rest.replacingOccurrences(of: "--", with: "/")
        }
    }

    /// Setzt Datum und deutsches Detail je Eintrag und sortiert neueste zuerst (ohne Datum zuletzt).
    static func dated(_ items: [FindingItem], _ kind: ItemDate) -> [FindingItem] {
        guard case .xcodeArchive = kind else { return items }
        let withDates = items.map { item -> FindingItem in
            var item = item
            if let url = item.url, let date = archiveDate(url) {
                item.date = date
                item.detail = GermanDate.string(date)
            }
            return item
        }
        return withDates.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// `CreationDate` aus der `Info.plist` des Archivs, sonst Änderungsdatum des Ordners.
    private static func archiveDate(_ archive: URL) -> Date? {
        if let data = try? Data(contentsOf: archive.appending(path: "Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let date = plist["CreationDate"] as? Date {
            return date
        }
        return (try? FileManager.default.attributesOfItem(atPath: archive.path))?[.modificationDate] as? Date
    }

    private static func total(_ items: [FindingItem]) -> Int64 {
        items.reduce(0) { $0 + ($1.size ?? 0) }
    }

    private func baseURL(_ ctx: ScanContext) -> URL {
        switch rule.base {
        case .home: ctx.home
        case .userCache: ctx.userCacheDir
        case .absolute: ctx.rootPrefix
        }
    }

    // MARK: - Dateisystem

    private static func entryType(_ url: URL) -> FileAttributeType? {
        // attributesOfItem folgt Symlinks nicht (lstat).
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    /// Löst ein Muster relativ zu `base` auf. `*` gilt nur innerhalb einer Komponente.
    static func resolve(_ pattern: String, base: URL, exclude: Set<String>) throws -> [URL] {
        let components = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return [] }
        var current = [base]
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            let isLast = index == components.count - 1
            var next: [URL] = []
            for dir in current {
                let names: [String]
                if component.contains("*") {
                    guard let all = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
                    names = all.sorted().filter { name in
                        (!name.hasPrefix(".") || component.hasPrefix(".")) && fnmatch(component, name, 0) == 0
                    }
                } else {
                    names = [component]
                }
                for name in names where !exclude.contains(name) {
                    let url = dir.appending(path: name)
                    guard let type = entryType(url), type != .typeSymbolicLink else { continue }
                    if !isLast && type != .typeDirectory { continue }
                    next.append(url)
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    /// Reguläre Dateien unter `root` (rekursiv, ohne Symlinks), deren Änderungsdatum vor `cutoff` liegt.
    /// Die URLs werden aus `root` und dem relativen Pfad gebildet (nicht aus dem Realpfad des Enumerators),
    /// damit Einträge dieselbe Schreibweise wie der getroffene Pfad haben.
    static func files(under root: URL, olderThan cutoff: Date, exclude: Set<String>) throws -> [URL] {
        func isOld(_ attrs: [FileAttributeKey: Any]?) -> Bool {
            // Attribute sind lstat-artig: Symlinks haben den Typ `.typeSymbolicLink` und fallen raus.
            guard let attrs, attrs[.type] as? FileAttributeType == .typeRegular,
                  let date = attrs[.modificationDate] as? Date else { return false }
            return date < cutoff
        }
        let fm = FileManager.default
        guard let rootAttrs = try? fm.attributesOfItem(atPath: root.path),
              let type = rootAttrs[.type] as? FileAttributeType else { return [] }
        if type != .typeDirectory { return isOld(rootAttrs) ? [root] : [] }
        guard let en = fm.enumerator(atPath: root.path) else { return [] }
        var result: [URL] = []
        var count = 0
        while let rel = en.nextObject() as? String {
            count += 1
            if count % 500 == 0 { try Task.checkCancellation() }
            if exclude.contains((rel as NSString).lastPathComponent) {
                en.skipDescendants()
                continue
            }
            if isOld(en.fileAttributes) { result.append(root.appending(path: rel)) }
        }
        return result
    }
}
