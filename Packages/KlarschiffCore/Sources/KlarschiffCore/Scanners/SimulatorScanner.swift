import Foundation

private let simulatorApp = [AppRef(bundleID: "com.apple.iphonesimulator", processName: nil, displayName: "Simulator")]

private func runSimctl(_ ctx: ScanContext, _ args: [String]) async throws -> Data {
    let result = try await ctx.runner.run("/usr/bin/xcrun", ["simctl"] + args, timeout: .seconds(60))
    guard result.succeeded else { throw CommandError.launchFailed("simctl: Exit \(result.exitCode)") }
    return Data(result.stdout.utf8)
}

/// Installierte Simulator-Runtimes (`xcrun simctl runtime list -j`), je Runtime ein Fund.
public struct SimulatorRuntimeScanner: Scanner {
    public let id = "sim.runtimes"
    public init() {}

    private struct Runtime: Decodable {
        var identifier: String
        var version: String
        var build: String?
        var platformIdentifier: String?
        var sizeBytes: Int64?
        var state: String?
        var deletable: Bool?
    }

    static func platformName(_ identifier: String?) -> String {
        let suffix = identifier?.split(separator: ".").last.map(String.init) ?? "Simulator"
        switch suffix {
        case "iphonesimulator": return "iOS"
        case "xrsimulator": return "visionOS"
        case "watchsimulator": return "watchOS"
        case "appletvsimulator": return "tvOS"
        default: return suffix
        }
    }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        guard await ToolLocator.xcrunAvailable(runner: ctx.runner) else { return [] }
        let data = try await runSimctl(ctx, ["runtime", "list", "-j"])
        let all = try JSONDecoder().decode([String: Runtime].self, from: data).values
        let runtimes = all
            .filter { $0.state != "Deleting" && $0.deletable != false }
            .sorted { $0.identifier < $1.identifier }
        let blocking = ctx.runningApps.running(simulatorApp)

        // Höchste Version je Plattform
        var newest: [String: Runtime] = [:]
        for r in runtimes {
            let p = Self.platformName(r.platformIdentifier)
            if let cur = newest[p], !VersionCompare.isNewer(r.version, than: cur.version) { continue }
            newest[p] = r
        }

        return runtimes.map { r in
            let platform = Self.platformName(r.platformIdentifier)
            let title = "\(platform) \(r.version) Simulator"
            let cmd = ToolCommand(tool: "xcrun", arguments: ["simctl", "runtime", "delete", r.identifier], timeout: .seconds(600))
            return Finding(
                id: FindingID(scannerID: id, key: r.identifier), category: .simulators,
                title: title,
                summary: "Eine installierte Simulator-Umgebung für \(platform) \(r.version). Sie wird nur zum Testen von Apps gebraucht; bei Bedarf lädt Xcode sie erneut herunter.",
                risk: .review, method: .tool([cmd], fallback: nil),
                items: [FindingItem(id: r.identifier, name: title, size: r.sizeBytes, detail: r.build.map { "Build \($0)" })],
                size: r.sizeBytes, blockingApps: blocking,
                keepSuggested: newest[platform]?.identifier == r.identifier,
                commandPreview: [cmd.display], needsFullDiskAccess: false,
                watchedApps: simulatorApp)
        }
    }
}

/// Simulatoren, deren Runtime fehlt (`xcrun simctl list devices unavailable -j`).
public struct UnavailableSimulatorsScanner: Scanner {
    public let id = "sim.unavailable"
    public init() {}

    private struct DeviceList: Decodable {
        var devices: [String: [Device]]
    }
    private struct Device: Decodable {
        var udid: String
        var name: String
        var dataPath: String?
    }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        guard await ToolLocator.xcrunAvailable(runner: ctx.runner) else { return [] }
        let data = try await runSimctl(ctx, ["list", "devices", "unavailable", "-j"])
        let devices = try JSONDecoder().decode(DeviceList.self, from: data).devices.values
            .flatMap { $0 }.sorted { $0.udid < $1.udid }
        guard !devices.isEmpty else { return [] }

        let urls = devices.compactMap { $0.dataPath.map { URL(fileURLWithPath: $0) } }
        let sizes = (try? await ctx.sizer.sizes(of: urls)) ?? [:]
        let items = devices.map { d -> FindingItem in
            let url = d.dataPath.map { URL(fileURLWithPath: $0) }
            return FindingItem(id: d.udid, url: url, name: d.name, size: url.flatMap { sizes[$0] })
        }
        let cmd = ToolCommand(tool: "xcrun", arguments: ["simctl", "delete", "unavailable"], timeout: .seconds(120))
        return [Finding(
            id: FindingID(scannerID: id, key: "all"), category: .simulators,
            title: "Nicht verfügbare Simulatoren",
            summary: "Simulatoren, deren Runtime nicht mehr installiert ist. Sie lassen sich nicht mehr starten und belegen nur Platz.",
            risk: .safe, method: .tool([cmd], fallback: nil), items: items,
            size: items.compactMap(\.size).reduce(0, +), blockingApps: ctx.runningApps.running(simulatorApp),
            keepSuggested: false, commandPreview: [cmd.display], needsFullDiskAccess: false,
            watchedApps: simulatorApp)]
    }
}
