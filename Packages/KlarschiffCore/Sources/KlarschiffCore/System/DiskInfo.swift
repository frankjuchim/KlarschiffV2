import Foundation

/// Freier und gesamter Speicher eines Volumes in Bytes.
public struct DiskSpace: Sendable, Equatable {
    public var free: Int64
    public var total: Int64

    public init(free: Int64, total: Int64) {
        self.free = free
        self.total = total
    }
}

/// Fehlt ein Kapazitätswert, meldet das Volume keinen verwertbaren Speicher.
public enum DiskInfoError: Error, Equatable {
    case capacityUnavailable
}

/// Liest Kapazität und freien Platz über die Volume-Ressourcenwerte.
public enum DiskInfo {
    public static func current(volume: URL = URL(filePath: "/System/Volumes/Data")) throws -> DiskSpace {
        let values = try volume.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ])
        guard let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else {
            throw DiskInfoError.capacityUnavailable
        }
        return DiskSpace(free: free, total: Int64(total))
    }
}
