import Foundation
import CoreServices
import AppKit

private func bundleID(of app: URL) -> String? {
    guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
    return id
}

private func isXcodeApp(_ name: String) -> Bool {
    name.hasPrefix("Xcode") && name.hasSuffix(".app")
}

private func isRealDirectory(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
}

// MARK: - Lange nicht genutzte Apps

public struct UnusedAppsScanner: Scanner {
    public let id = "apps.unused"
    let lastUsed: @Sendable (URL) -> Date?

    /// `lastUsed` nil: Produktion über Spotlight (`kMDItemLastUsedDate`).
    public init(lastUsed: (@Sendable (URL) -> Date?)? = nil) {
        self.lastUsed = lastUsed ?? { url in
            guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
            return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        }
    }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let dir = ctx.absolute("/Applications")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let cutoff = ctx.now.addingTimeInterval(-180 * 86_400)
        var items: [FindingItem] = []
        // Xcode-Versionen deckt `ExtraXcodeScanner` ab.
        for name in names.sorted() where name.hasSuffix(".app") && !name.hasPrefix(".") && !isXcodeApp(name) {
            try Task.checkCancellation()
            let url = dir.appending(path: name)
            guard isRealDirectory(url), let bid = bundleID(of: url),
                  !bid.lowercased().hasPrefix("com.apple."), bid != "de.frankjuchim.klarschiff2" else { continue }
            let used = lastUsed(url)
            let reference = used ?? (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            guard let reference, reference < cutoff else { continue }
            let size = try? await ctx.sizer.size(of: url)
            items.append(FindingItem(
                id: url.path, url: url, name: name, size: size, date: used,
                detail: used.map { "zuletzt geöffnet am \(GermanDate.string($0))" } ?? "nie geöffnet"))
        }
        guard !items.isEmpty else { return [] }
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .apps,
            title: "Lange nicht genutzte Apps",
            summary: "Apps, die du seit über 180 Tagen nicht geöffnet hast. Per Homebrew installierte Apps entfernst du besser im Entwickler-Tab beim Homebrew-Fund.",
            risk: .review, method: .trash, items: items,
            size: items.compactMap(\.size).reduce(0, +), blockingApps: [], keepSuggested: false,
            commandPreview: PathScanner.preview(.trash, items: items), needsFullDiskAccess: false)]
    }
}

// MARK: - Reste gelöschter Apps

public struct LeftoverAppDataScanner: Scanner {
    public let id = "apps.leftovers"
    public var phase: ScannerPhase { .collector }
    let isInstalled: @Sendable (String) -> Bool

    /// `isInstalled` nil: Produktion über `NSWorkspace`.
    public init(isInstalled: (@Sendable (String) -> Bool)? = nil) {
        self.isInstalled = isInstalled ?? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    static let locations = ["Containers", "Application Support", "Caches", "HTTPStorages", "WebKit"]
    static let minSize: Int64 = 10_000_000

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        struct Entry { let bundleID: String; let location: String; let item: FindingItem }
        var byID: [String: [Entry]] = [:]
        for location in Self.locations {
            let dir = ctx.homePath("Library/\(location)")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() {
                try Task.checkCancellation()
                guard name.range(of: #"^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+){2,}$"#, options: .regularExpression) != nil,
                      !name.lowercased().hasPrefix("com.apple.") else { continue }
                let url = dir.appending(path: name)
                guard isRealDirectory(url), !(await ctx.claims.isClaimed(url)), !isInstalled(name) else { continue }
                let size = try? await ctx.sizer.size(of: url)
                byID[name, default: []].append(Entry(
                    bundleID: name, location: location,
                    item: FindingItem(id: url.path, url: url, name: "\(name) (\(location))", size: size)))
            }
        }
        var items: [FindingItem] = []
        for bid in byID.keys.sorted() {
            let entries = byID[bid]!
            guard entries.compactMap(\.item.size).reduce(0, +) >= Self.minSize else { continue }
            items += entries.sorted { $0.location < $1.location }.map(\.item)
        }
        guard !items.isEmpty else { return [] }
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .apps,
            title: "Reste gelöschter Apps",
            summary: "Daten, Caches und Container von Apps, die nicht mehr installiert sind. Prüfe die Liste: Gehört ein Eintrag zu einer App, die du später wieder installieren willst, lass ihn stehen.",
            risk: .review, method: .trash, items: items,
            size: items.compactMap(\.size).reduce(0, +), blockingApps: [], keepSuggested: false,
            commandPreview: PathScanner.preview(.trash, items: items), needsFullDiskAccess: false)]
    }
}

// MARK: - Zusätzliche Xcode-Versionen

/// Hinweis: Laufende Xcode-Instanzen lassen sich nicht je Version unterscheiden, daher keine `blockingApps`.
public struct ExtraXcodeScanner: Scanner {
    public let id = "xcode.extraVersions"
    public init() {}

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        var activeApp: String?
        if let result = try? await ctx.runner.run("/usr/bin/xcode-select", ["-p"], timeout: .seconds(10), environment: [:]),
           result.succeeded {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            activeApp = URL(fileURLWithPath: path).pathComponents.first { $0.hasSuffix(".app") }
        }
        let dir = ctx.absolute("/Applications")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let xcodes = names.sorted().filter { isXcodeApp($0) && isRealDirectory(dir.appending(path: $0)) }
        // Ohne gewähltes Xcode (Command Line Tools oder Fehler): Xcode.app gilt als aktiv, sonst eine einzige Version.
        if activeApp == nil {
            activeApp = xcodes.contains("Xcode.app") ? "Xcode.app" : (xcodes.count == 1 ? xcodes[0] : nil)
        }
        var findings: [Finding] = []
        for name in xcodes where name != activeApp {
            try Task.checkCancellation()
            let url = dir.appending(path: name)
            let size = try? await ctx.sizer.size(of: url)
            let items = [FindingItem(id: url.path, url: url, name: name, size: size)]
            findings.append(Finding(
                id: FindingID(scannerID: id, key: name), category: .xcode,
                title: "\(name.dropLast(4)) (zusätzliche Version)",
                summary: "Eine weitere Xcode-Version neben der aktiven. Beta- und ältere Versionen belegen oft über 10 GB; beende Xcode vor dem Entfernen und prüfe, ob du die Version noch brauchst.",
                risk: .review, method: .trash, items: items, size: size, blockingApps: [],
                keepSuggested: false, commandPreview: PathScanner.preview(.trash, items: items), needsFullDiskAccess: false))
        }
        return findings
    }
}
