import Foundation
import AppKit

private func isSymlink(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
}

// MARK: - Caches von App-Store-Apps

public struct AppStoreCachesScanner: Scanner {
    public let id = "appCaches.appStore"
    public var phase: ScannerPhase { .collector }
    let appName: @Sendable (String) -> String?

    /// `appName` nil: Produktion über `NSWorkspace` + `FileManager.displayName`.
    public init(appName: (@Sendable (String) -> String?)? = nil) {
        self.appName = appName ?? { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return FileManager.default.displayName(atPath: url.path)
        }
    }

    private static let title = "Caches von App-Store-Apps"

    private func noAccess() -> Finding {
        Finding(
            id: FindingID(scannerID: id, key: "noAccess"), category: .appCaches, title: Self.title,
            summary: "Braucht Vollzugriff auf die Festplatte. Erlaube Klarschiff den Zugriff in den Systemeinstellungen unter Datenschutz & Sicherheit, dann kann ich diese Caches auflisten.",
            risk: .safe, method: .trash, items: [], size: nil, blockingApps: [],
            keepSuggested: false, commandPreview: [], needsFullDiskAccess: true)
    }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        guard ctx.hasFullDiskAccess else { return [noAccess()] }
        let base = ctx.homePath("Library/Containers")
        guard let containers = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return [] }
        var items: [FindingItem] = []
        for container in containers.sorted() where !container.hasPrefix(".") {
            let caches = base.appending(path: "\(container)/Data/Library/Caches")
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: caches.path) else { continue }
            let app = appName(container) ?? container
            for child in children.sorted() where !child.hasPrefix(".") {
                try Task.checkCancellation()
                let url = caches.appending(path: child)
                guard !isSymlink(url), !(await ctx.claims.isClaimed(url)) else { continue }
                let size = try? await ctx.sizer.size(of: url)
                items.append(FindingItem(id: url.path, url: url, name: "\(app) – \(child)", size: size))
            }
        }
        guard !items.isEmpty else { return [] }
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .appCaches, title: Self.title,
            summary: "Zwischenspeicher von Apps aus dem App Store. Sie bauen sich beim nächsten Start von selbst wieder auf.",
            risk: .safe, method: .trash, items: items,
            size: items.compactMap(\.size).reduce(0, +), blockingApps: [], keepSuggested: false,
            commandPreview: PathScanner.preview(.trash, items: items), needsFullDiskAccess: true)]
    }
}

// MARK: - Sonstige App-Caches

public struct OtherCachesScanner: Scanner {
    public let id = "appCaches.other"
    public var phase: ScannerPhase { .collector }
    public init() {}

    static let excluded: Set<String> = [
        "com.apple.bird", "CloudKit", "com.apple.Safari.SafeBrowsing", "com.apple.akd",
        "com.apple.ap.adprivacyd", "FamilyCircle",
    ]

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let dir = ctx.homePath("Library/Caches")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var items: [FindingItem] = []
        for name in names.sorted() where !name.hasPrefix(".") && !Self.excluded.contains(name) {
            try Task.checkCancellation()
            let url = dir.appending(path: name)
            guard !isSymlink(url), !(await ctx.claims.isClaimed(url)) else { continue }
            let size = try? await ctx.sizer.size(of: url)
            let ref = AppRef(bundleID: name, processName: nil, displayName: name)
            items.append(FindingItem(
                id: url.path, url: url, name: name, size: size,
                blockingApp: ctx.runningApps.running([ref]).first, watchedApp: ref))
        }
        guard !items.isEmpty else { return [] }
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .appCaches, title: "Sonstige App-Caches",
            summary: "Zwischenspeicher weiterer Apps, die kein anderer Fund abdeckt. Apps bauen ihn bei Bedarf neu auf; Einträge laufender Apps bleiben abgewählt, bis du sie beendest.",
            risk: .safe, method: .trash, items: items,
            size: items.compactMap(\.size).reduce(0, +), blockingApps: [], keepSuggested: false,
            commandPreview: PathScanner.preview(.trash, items: items), needsFullDiskAccess: false)]
    }
}
