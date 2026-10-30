import AppKit
import Foundation

/// Liest LaunchAgents/-Daemons (nur lesend), erkennt verwaiste und fragt den Laufstatus per `launchctl print`.
public struct LaunchItemScanner: Sendable {
    public static let ownPrefix = "de.frankjuchim.klarschiff2."
    static let launchctl = "/bin/launchctl"
    static let maxParallel = 8

    private let isInstalledOverride: (@Sendable (String) -> URL?)?

    /// `isInstalled` liefert zur Bundle-ID den App-Ort; `nil` → `NSWorkspace`.
    public init(isInstalled: (@Sendable (String) -> URL?)? = nil) {
        self.isInstalledOverride = isInstalled
    }

    private func installedApp(_ bundleID: String) -> URL? {
        if let f = isInstalledOverride { return f(bundleID) }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    public func scan(_ ctx: ScanContext, uid: uid_t = getuid()) async -> [LaunchItem] {
        let sources: [(LaunchScope, URL)] = [
            (.user, ctx.homePath("Library/LaunchAgents")),
            (.allUsers, ctx.absolute("/Library/LaunchAgents")),
            (.system, ctx.absolute("/Library/LaunchDaemons")),
        ]
        var items: [LaunchItem] = []
        for (scope, dir) in sources {
            items += read(directory: dir, scope: scope, ctx: ctx)
        }
        let counts = Dictionary(grouping: items, by: \.id).mapValues(\.count)
        for i in items.indices where counts[items[i].id, default: 0] > 1 {
            items[i].id += "#" + (items[i].plistURL?.lastPathComponent ?? "")
        }
        let running = await runningLabels(items, runner: ctx.runner, uid: uid)
        for i in items.indices { items[i].isRunning = running.contains(items[i].id) }
        items = ServiceRemoval.markSharedLabels(items, home: ctx.home)
        return items.sorted { a, b in
            if a.scope != b.scope { return a.scope.sortIndex < b.scope.sortIndex }
            let c = a.displayName.localizedStandardCompare(b.displayName)
            if c != .orderedSame { return c == .orderedAscending }
            return (a.label, a.id) < (b.label, b.id)
        }
    }

    // MARK: Lesen

    private func read(directory: URL, scope: LaunchScope, ctx: ScanContext) -> [LaunchItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var items: [LaunchItem] = []
        for name in names.sorted() where name.lowercased().hasSuffix(".plist") {
            let url = directory.appending(path: name)
            let fileLabel = String(name.dropLast(".plist".count))
            let type = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            guard type == .typeRegular else { continue }  // Symlinks und Sonstiges nie anfassen
            if Self.isApple(fileLabel) { continue }

            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else {
                items.append(LaunchItem(
                    id: "\(scope.rawValue)/\(fileLabel)", label: fileLabel, scope: scope, plistURL: url,
                    displayName: Self.prettyName(fromLabel: fileLabel),
                    explanation: "Die Datei konnte nicht gelesen werden. Klarschiff 2 fasst sie nicht an."))
                continue
            }
            let label = (plist["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fileLabel
            if Self.isApple(label) { continue }
            items.append(makeItem(plist: plist, label: label, scope: scope, url: url, ctx: ctx))
        }
        return items
    }

    static func isApple(_ label: String) -> Bool { label.lowercased().hasPrefix("com.apple.") }

    private func makeItem(plist: [String: Any], label: String, scope: LaunchScope, url: URL, ctx: ScanContext) -> LaunchItem {
        let args = plist["ProgramArguments"] as? [String]
        let program = (plist["Program"] as? String) ?? args?.first
        let hasBundleProgram = plist["BundleProgram"] != nil
        let bundleIDs = (plist["AssociatedBundleIdentifiers"] as? [String])
            ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        let isOwn = label.hasPrefix(Self.ownPrefix)
        let startKind = Self.startKind(plist)

        var appURL: URL?
        var orphaned = false
        var missingProgram: String?
        var programInApp = false
        var appMovedButInstalled = false
        var programMissingInApp = false
        var offlineVolume = false
        var appGone = false

        if let program, program.hasPrefix("/"), !Self.isSystemPath(program) {
            if let volume = Self.volumePath(of: program), Self.presence(ctx.absolute(volume)) != .present {
                offlineVolume = true  // Laufwerk nicht verbunden → unklar, nie verwaist
            } else {
                let programPresence = Self.presence(ctx.absolute(program))
                var appPresence = Presence.present
                if let appPath = Self.appBundlePath(in: program) {
                    programInApp = true
                    let appReal = ctx.absolute(appPath)
                    appPresence = Self.presence(appReal)
                    if appPresence == .present { appURL = appReal }
                }
                // Nur sicher fehlend (ENOENT/ENOTDIR), nie bei unklaren Fehlern wie fehlender Berechtigung.
                if programPresence != .unknown, appPresence != .unknown,
                   programPresence == .missing || appPresence == .missing {
                    orphaned = true
                    missingProgram = program
                }
                // App ist da, nur das Programm darin fehlt: beschädigte Installation, nicht verwaist.
                if programInApp, appPresence == .present, programPresence == .missing {
                    orphaned = false
                    programMissingInApp = true
                }
            }
        }
        if appURL == nil {
            appURL = bundleIDs.lazy.compactMap { installedApp($0) }.first
        }
        if orphaned, appURL != nil {
            // z. B. App umbenannt/verschoben: die App ist über ihre Bundle-ID noch da.
            orphaned = false
            appMovedButInstalled = true
        }
        // Grenze: Bei BundleProgram ohne Program gibt es nur die Bundle-IDs als Hinweis; verwaist nur, wenn
        // mindestens eine ID angegeben ist und keine davon eine installierte App ergibt.
        if hasBundleProgram, program == nil, !bundleIDs.isEmpty, appURL == nil {
            orphaned = true
            appGone = true
        }
        if isOwn { orphaned = false }

        let name: String
        if isOwn {
            name = "Klarschiff 2 – automatischer Check"
        } else if let appURL {
            name = Self.appName(appURL)
        } else {
            name = Self.prettyName(fromLabel: label)
        }

        let explanation: String
        if isOwn {
            explanation = "Das ist der automatische Check von Klarschiff 2. Er bleibt immer erhalten."
        } else if orphaned, let missingProgram {
            explanation = "Das Programm fehlt: \(missingProgram). "
                + (programInApp ? "Die App wurde vermutlich gelöscht." : "Es wurde vermutlich deinstalliert.")
        } else if programMissingInApp {
            explanation = "Das Programm fehlt in der installierten App. Nicht entfernbar – bitte die App neu installieren."
        } else if orphaned, appGone {
            explanation = "Die zugehörige App ist nicht mehr installiert. Die App wurde vermutlich gelöscht."
        } else if appMovedButInstalled {
            explanation = "Das Programm liegt nicht mehr am erwarteten Ort, die App ist aber installiert."
        } else if offlineVolume {
            explanation = "Das Programm liegt auf einem nicht verbundenen Laufwerk."
        } else if appURL != nil {
            explanation = "Gehört zu \(name)."
        } else {
            explanation = "Gehört zu keiner erkennbaren App."
        }

        return LaunchItem(
            id: "\(scope.rawValue)/\(label)", label: label, scope: scope, plistURL: url, programPath: program,
            associatedBundleIDs: bundleIDs, appURL: appURL, startKind: startKind, isRunning: false,
            isOrphaned: orphaned, isOwnAgent: isOwn, displayName: name, explanation: explanation,
            hasNoKnownApp: !isOwn && appURL == nil && !orphaned && !appMovedButInstalled && !offlineVolume
                && !programMissingInApp)
    }

    enum Presence { case present, missing, unknown }

    /// `stat`-Semantik: nur ENOENT/ENOTDIR gelten als „fehlt“, jeder andere Fehler als „unklar“.
    static func presence(_ url: URL) -> Presence {
        var st = stat()
        if stat(url.path, &st) == 0 { return .present }
        return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown
    }

    /// `/Volumes/<name>` für Pfade auf externen Laufwerken, sonst nil.
    static func volumePath(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }

    /// Systemeigene Programme (/bin, /usr/bin …) gelten nie als fehlend.
    static func isSystemPath(_ path: String) -> Bool {
        ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/System/"].contains { path.hasPrefix($0) }
    }

    /// Erster Pfadanteil, der auf `.app` endet (inkl.), sonst nil.
    static func appBundlePath(in path: String) -> String? {
        var parts: [Substring] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            parts.append(comp)
            if comp.lowercased().hasSuffix(".app") { return "/" + parts.joined(separator: "/") }
        }
        return nil
    }

    static func startKind(_ plist: [String: Any]) -> StartKind {
        if plist["RunAtLoad"] as? Bool == true { return .atLogin }
        switch plist["KeepAlive"] {
        case let b as Bool where b: return .atLogin
        case let d as [String: Any] where !d.isEmpty: return .atLogin
        default: break
        }
        if plist["StartInterval"] != nil || plist["StartCalendarInterval"] != nil { return .scheduled }
        return .onDemand
    }

    static func appName(_ url: URL) -> String {
        let shown = FileManager.default.displayName(atPath: url.path)
        return shown.lowercased().hasSuffix(".app") ? String(shown.dropLast(4)) : shown
    }

    /// `com.elgato.StreamDeck` → „Stream Deck“ (Reverse-DNS-Präfix weg, Großschreibung getrennt).
    static func prettyName(fromLabel label: String) -> String {
        var comps = label.split(separator: ".").map(String.init)
        if comps.count > 2 { comps.removeFirst(2) }
        let joined = comps.joined(separator: " ")
        var out = ""
        var prev: Character?
        for ch in joined {
            if let p = prev, ch.isUppercase, p.isLowercase || p.isNumber { out.append(" ") }
            out.append(ch)
            prev = ch
        }
        let words = out.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).map { w -> String in
            w.first.map { $0.uppercased() + w.dropFirst() } ?? String(w)
        }
        return words.isEmpty ? label : words.joined(separator: " ")
    }

    // MARK: Laufstatus

    private func runningLabels(_ items: [LaunchItem], runner: CommandRunner, uid: uid_t) async -> Set<String> {
        let queries: [(id: String, target: String)] = items.compactMap { item in
            guard item.scope != .loginItem, Self.safeLabel(item.label) else { return nil }
            return (item.id, item.scope == .system ? "system/\(item.label)" : "gui/\(uid)/\(item.label)")
        }
        return await withTaskGroup(of: String?.self) { group in
            var running: Set<String> = []
            var next = 0
            func addNext() {
                guard next < queries.count else { return }
                let q = queries[next]
                next += 1
                group.addTask {
                    guard let r = try? await runner.run(Self.launchctl, ["print", q.target], timeout: .seconds(5)),
                          r.succeeded, r.stdout.contains("state = running") else { return nil }
                    return q.id
                }
            }
            for _ in 0..<Self.maxParallel { addNext() }
            while let done = await group.next() {
                if let id = done { running.insert(id) }
                addNext()
            }
            return running
        }
    }

    /// Labels, die als `launchctl`-Ziel unbedenklich sind (kein Leerraum/Zeilenumbruch).
    static func safeLabel(_ label: String) -> Bool {
        !label.isEmpty && !label.contains(where: { $0.isWhitespace || $0 == "\n" })
    }
}

extension LaunchScope {
    fileprivate var sortIndex: Int {
        switch self {
        case .user: 0
        case .allUsers: 1
        case .system: 2
        case .loginItem: 3
        }
    }
}
