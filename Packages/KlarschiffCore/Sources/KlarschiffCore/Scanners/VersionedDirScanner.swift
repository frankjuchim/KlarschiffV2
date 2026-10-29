import Foundation

/// Ein Fund je Versionsordner (Device Support, nvm, pyenv, rbenv); je Gruppe wird die neueste Version zum Behalten vorgeschlagen.
public struct VersionedDirScanner: Scanner {
    public let id: String
    let category: Category
    let titlePrefix: String
    let summary: String
    let base: PathBase
    let parent: String
    let risk: Risk
    let method: RemovalMethod
    let blockingApps: [AppRef]
    let groupBy: @Sendable (String) -> String
    let versionOf: @Sendable (String) -> String
    let titleFor: (@Sendable (_ parentName: String, _ childName: String) -> String)?

    /// `groupBy` bekommt den Pfad des Unterordners und liefert den Gruppenschlüssel.
    /// `titleFor` ersetzt den Standardtitel „<titlePrefix> <Ordnername>“.
    public init(
        id: String, category: Category, titlePrefix: String, summary: String, base: PathBase, parent: String,
        risk: Risk, method: RemovalMethod, blockingApps: [AppRef] = [],
        groupBy: @escaping @Sendable (String) -> String = { _ in "" },
        versionOf: @escaping @Sendable (String) -> String = { $0 },
        titleFor: (@Sendable (_ parentName: String, _ childName: String) -> String)? = nil
    ) {
        self.id = id
        self.category = category
        self.titlePrefix = titlePrefix
        self.summary = summary
        self.base = base
        self.parent = parent
        self.risk = risk
        self.method = method
        self.blockingApps = blockingApps
        self.groupBy = groupBy
        self.versionOf = versionOf
        self.titleFor = titleFor
    }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let root: URL
        switch base {
        case .home: root = ctx.home
        case .userCache: root = ctx.userCacheDir
        case .absolute: root = ctx.rootPrefix
        }
        let parents = try PathScanner.resolve(parent, base: root, exclude: [])
        var children: [(url: URL, parentName: String)] = []
        for p in parents {
            try Task.checkCancellation()
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: p.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = p.appending(path: name)
                guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType,
                      type == .typeDirectory else { continue }
                children.append((url, p.lastPathComponent))
            }
        }

        // Neueste Version je Gruppe (bei Gleichstand der erste).
        var newest: [String: Int] = [:]
        let groups = children.map { groupBy($0.url.path) }
        for (i, child) in children.enumerated() {
            let g = groups[i]
            if let j = newest[g] {
                if VersionCompare.isNewer(versionOf(child.url.lastPathComponent), than: versionOf(children[j].url.lastPathComponent)) { newest[g] = i }
            } else {
                newest[g] = i
            }
        }

        let blocking = ctx.runningApps.running(blockingApps)
        var findings: [Finding] = []
        for (i, child) in children.enumerated() {
            try Task.checkCancellation()
            let name = child.url.lastPathComponent
            let size = try? await ctx.sizer.size(of: child.url)
            let item = FindingItem(id: child.url.path, url: child.url, name: name, size: size)
            findings.append(Finding(
                id: FindingID(scannerID: id, key: child.url.path), category: category,
                title: titleFor?(child.parentName, name) ?? "\(titlePrefix) \(name)",
                summary: summary, risk: risk, method: method, items: [item], size: size,
                blockingApps: blocking, keepSuggested: newest[groups[i]] == i,
                commandPreview: PathScanner.preview(method, items: [item]), needsFullDiskAccess: false))
        }
        return findings
    }
}

extension VersionedDirScanner {
    /// Entfernt ein führendes Gerätemodell wie „iPhone15,2 “ aus „iPhone15,2 18.2 (22C150)“.
    static func stripDeviceModel(_ name: String) -> String {
        guard let r = name.range(of: #"^[A-Za-z]+\d+,\d+ "#, options: .regularExpression) else { return name }
        return String(name[r.upperBound...])
    }

    /// Device-Support-Ordner: Plattform aus dem Elternordner („iOS DeviceSupport“ → „iOS“).
    static let deviceSupport = VersionedDirScanner(
        id: "xcode.deviceSupport", category: .xcode, titlePrefix: "Gerätesupport",
        summary: "Symbole und Debug-Daten, die Xcode beim ersten Anschließen eines Geräts mit dieser Systemversion anlegt. Xcode erstellt sie beim nächsten Anschließen neu; die neueste Version je Plattform behältst du am besten.",
        base: .home, parent: "Library/Developer/Xcode/*DeviceSupport", risk: .safe, method: .trash,
        blockingApps: Catalog.xcodeApps,
        groupBy: { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent },
        versionOf: stripDeviceModel,
        titleFor: { parentName, child in
            var platform = parentName
            if platform.hasSuffix(" DeviceSupport") { platform.removeLast(" DeviceSupport".count) }
            else if platform.hasSuffix("DeviceSupport") { platform.removeLast("DeviceSupport".count) }
            platform = platform.trimmingCharacters(in: .whitespaces)
            let model = stripDeviceModel(child) == child ? "" : " · \(child.prefix(while: { $0 != " " }))"
            return "\(platform.isEmpty ? "" : platform + "-")Gerätesupport \(stripDeviceModel(child))\(model)"
        })

    private static func manager(id: String, name: String, parent: String, what: String) -> VersionedDirScanner {
        VersionedDirScanner(
            id: id, category: .languages, titlePrefix: name,
            summary: "Eine mit \(what) installierte Version. Nur entfernen, wenn kein Projekt sie mehr braucht; neu installieren lässt sie sich jederzeit.",
            base: .home, parent: parent, risk: .review, method: .trash)
    }

    static let nvm = manager(id: "languages.nvm", name: "Node.js", parent: ".nvm/versions/node", what: "nvm")
    static let pyenv = manager(id: "languages.pyenv", name: "Python", parent: ".pyenv/versions", what: "pyenv")
    static let rbenv = manager(id: "languages.rbenv", name: "Ruby", parent: ".rbenv/versions", what: "rbenv")
}
