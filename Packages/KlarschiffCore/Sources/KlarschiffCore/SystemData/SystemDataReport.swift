import Foundation

/// Ergebnis einer Systemdaten-Messung (Spec §3.4).
public struct SystemDataReport: Sendable {
    public var measuredAt: Date
    /// nil, wenn `diskutil` scheiterte.
    public var inventory: VolumeInventoryResult?
    /// Wurzelbereiche des Katalogs samt Unterbereichen.
    public var areas: [SystemArea]
    /// Home-Ordner + `/Applications`.
    public var userData: Int64
    public var systemAreasTotal: Int64
    public var unaccounted: Int64
    public var snapshotFindings: [Finding]
    public var cleanupFindings: [Finding]
    public var failures: [ScanFailure]

    public init(measuredAt: Date, inventory: VolumeInventoryResult?, areas: [SystemArea], userData: Int64,
                systemAreasTotal: Int64, unaccounted: Int64, snapshotFindings: [Finding],
                cleanupFindings: [Finding], failures: [ScanFailure]) {
        self.measuredAt = measuredAt
        self.inventory = inventory
        self.areas = areas
        self.userData = userData
        self.systemAreasTotal = systemAreasTotal
        self.unaccounted = unaccounted
        self.snapshotFindings = snapshotFindings
        self.cleanupFindings = cleanupFindings
        self.failures = failures
    }
}
