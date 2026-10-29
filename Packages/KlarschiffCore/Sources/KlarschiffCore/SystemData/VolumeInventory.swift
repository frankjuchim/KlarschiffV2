import Foundation

/// Rolle eines APFS-Volumes (aus `diskutil apfs list`).
public enum VolumeRole: String, Sendable {
    case system, preboot, recovery, vm, data, simulator, other
}

public struct APFSVolume: Sendable, Equatable {
    public var name: String
    public var role: VolumeRole
    public var consumed: Int64

    public init(name: String, role: VolumeRole, consumed: Int64) {
        self.name = name
        self.role = role
        self.consumed = consumed
    }
}

public struct VolumeInventoryResult: Sendable {
    public var containerSize: Int64
    public var containerFree: Int64
    /// Volumes des Startcontainers.
    public var volumes: [APFSVolume]
    /// Volumes aus anderen Containern, deren Name auf „Simulator“ endet.
    public var simulatorVolumes: [APFSVolume]

    public init(containerSize: Int64, containerFree: Int64, volumes: [APFSVolume], simulatorVolumes: [APFSVolume]) {
        self.containerSize = containerSize
        self.containerFree = containerFree
        self.volumes = volumes
        self.simulatorVolumes = simulatorVolumes
    }
}

public enum VolumeInventoryError: Error, Equatable, Sendable {
    case commandFailed(Int32)
    case invalidPlist
    case noStartContainer
}

public enum VolumeInventory {
    public static func read(runner: CommandRunner) async throws -> VolumeInventoryResult {
        let result = try await runner.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: .seconds(30))
        guard result.succeeded else { throw VolumeInventoryError.commandFailed(result.exitCode) }
        return try parse(Data(result.stdout.utf8))
    }

    /// `dataVolumeHint`: Rollenname, an dem der Startcontainer erkannt wird (Standard „Data“).
    public static func parse(_ plist: Data, dataVolumeHint: String = "Data") throws -> VolumeInventoryResult {
        guard let root = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]]
        else { throw VolumeInventoryError.invalidPlist }

        func number(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
        func volumes(of c: [String: Any]) -> [[String: Any]] { c["Volumes"] as? [[String: Any]] ?? [] }
        func roles(of v: [String: Any]) -> [String] { v["Roles"] as? [String] ?? [] }
        func volume(_ v: [String: Any]) -> APFSVolume {
            let name = v["Name"] as? String ?? ""
            let r = roles(of: v)
            let role: VolumeRole
            if r.contains("System") { role = .system }
            else if r.contains("Preboot") { role = .preboot }
            else if r.contains("Recovery") { role = .recovery }
            else if r.contains("VM") { role = .vm }
            else if r.contains("Data") { role = .data }
            else if name.hasSuffix("Simulator") { role = .simulator }
            else { role = .other }
            return APFSVolume(name: name, role: role, consumed: number(v["CapacityInUse"]))
        }

        guard let start = containers.first(where: { volumes(of: $0).contains { roles(of: $0).contains(dataVolumeHint) } })
        else { throw VolumeInventoryError.noStartContainer }

        let sims = containers
            .filter { ($0["ContainerReference"] as? String) != (start["ContainerReference"] as? String) }
            .flatMap(volumes(of:))
            .map(volume)
            .filter { $0.name.hasSuffix("Simulator") }
            .map { APFSVolume(name: $0.name, role: .simulator, consumed: $0.consumed) }

        return VolumeInventoryResult(
            containerSize: number(start["CapacityCeiling"]),
            containerFree: number(start["CapacityFree"]),
            volumes: volumes(of: start).map(volume),
            simulatorVolumes: sims)
    }
}
