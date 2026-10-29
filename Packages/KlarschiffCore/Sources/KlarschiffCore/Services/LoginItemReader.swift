import Foundation

/// Liest die Anmeldeobjekte der aktuellen Benutzerkennung aus `sfltool dumpbtm` (nur lesend).
/// Nur Einträge vom Typ „login item“ werden gelistet; „app“-Einträge sind in der BTM-Datenbank
/// lediglich Elterncontainer und dienen nur zur Namensauflösung.
public enum LoginItemReader {
    static let sfltool = "/usr/bin/sfltool"

    public static func read(runner: CommandRunner, uid: uid_t = getuid()) async -> (items: [LaunchItem], failed: Bool) {
        do {
            let r = try await runner.run(sfltool, ["dumpbtm"], timeout: .seconds(20))
            guard r.succeeded else { return ([], true) }
            return (parse(r.stdout, uid: uid), false)
        } catch {
            return ([], true)
        }
    }

    private struct Entry {
        var fields: [String: String] = [:]
        subscript(key: String) -> String? {
            guard let v = fields[key], !v.isEmpty, v != "(null)" else { return nil }
            return v
        }
    }

    public static func parse(_ text: String, uid: uid_t) -> [LaunchItem] {
        var entries: [Entry] = []
        var inSection = false
        var current: Entry?
        func flush() { if let c = current { entries.append(c) }; current = nil }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let sectionUID = sectionUID(trimmed) {
                flush()
                inSection = sectionUID == Int64(uid)
                continue
            }
            guard inSection else { continue }
            if isItemHeader(trimmed) {
                flush()
                current = Entry()
                continue
            }
            guard current != nil, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.hasPrefix("#") else { continue }
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if current?.fields[key] == nil { current?.fields[key] = value }
        }
        flush()

        let namesByIdentifier = Dictionary(
            entries.compactMap { e in e["Identifier"].flatMap { id in e["Name"].map { (id, $0) } } },
            uniquingKeysWith: { first, _ in first })

        var seen = Set<String>()
        var result: [LaunchItem] = []
        for e in entries {
            guard (e["Type"] ?? "").hasPrefix("login item"), let identifier = e["Identifier"] else { continue }
            guard seen.insert(identifier).inserted else { continue }
            let url = e["URL"]
            let name = e["Name"]
                ?? e["Parent Identifier"].flatMap { namesByIdentifier[$0] }
                ?? url.map(lastComponent) ?? identifier
            // „disallowed“ = Schalter „Im Hintergrund erlauben“ aus → startet nicht.
            let flags = Set((e["Disposition"] ?? "").split(whereSeparator: { "[], ".contains($0) }).map(String.init).filter { !$0.hasPrefix("0x") })
            let enabled = flags.contains("enabled") && flags.contains("allowed") && !flags.contains("disallowed")
            var bundleIDs: [String] = []
            if let b = e["Bundle Identifier"] { bundleIDs.append(b) }
            let explanation = enabled
                ? "Startet bei jeder Anmeldung."
                : "Ist in den Systemeinstellungen ausgeschaltet."
            result.append(LaunchItem(
                id: "loginItem/\(identifier)", label: identifier, scope: .loginItem,
                associatedBundleIDs: bundleIDs, startKind: enabled ? .atLogin : .onDemand,
                displayName: name, explanation: explanation))
        }
        return result
    }

    private static func sectionUID(_ line: String) -> Int64? {
        let prefix = "Records for UID "
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        return Int64(rest.prefix { $0 == "-" || $0.isNumber })
    }

    private static func isItemHeader(_ line: String) -> Bool {
        guard line.hasPrefix("#"), line.hasSuffix(":") else { return false }
        let digits = line.dropFirst().dropLast()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    private static func lastComponent(_ url: String) -> String {
        var name = url.split(separator: "/").last.map(String.init) ?? url
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name
    }
}
