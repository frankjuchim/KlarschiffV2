import Foundation
import Testing
import KlarschiffCore
@testable import Klarschiff

private let gb: Int64 = 1_000_000_000

private func report(inventory: VolumeInventoryResult?, unaccounted: Int64 = 0, upper: Bool = false,
                    userLower: Bool = false, snapshots: [Finding] = []) -> SystemDataReport {
    SystemDataReport(measuredAt: Date(), inventory: inventory, areas: [], userData: 248 * gb, userDataIsLowerBound: userLower,
                     systemAreasTotal: 70 * gb, unaccounted: unaccounted, unaccountedIsUpperBound: upper,
                     snapshotFindings: snapshots, cleanupFindings: [], failures: [])
}

@MainActor @Test func barSegmentsFollowSpecOrderAndSums() {
    let inv = VolumeInventoryResult(
        containerSize: 494 * gb, containerFree: 80 * gb,
        volumes: [APFSVolume(name: "S", role: .system, consumed: 11 * gb), APFSVolume(name: "P", role: .preboot, consumed: 7 * gb),
                  APFSVolume(name: "R", role: .recovery, consumed: 1 * gb), APFSVolume(name: "VM", role: .vm, consumed: 4 * gb),
                  APFSVolume(name: "D", role: .data, consumed: 390 * gb)],
        simulatorVolumes: [APFSVolume(name: "iOS Simulator", role: .simulator, consumed: 18 * gb)])
    let r = report(inventory: inv, unaccounted: 72 * gb, upper: true, userLower: true)
    let s = VolumeBarCard.segments(r)
    #expect(s.map(\.title) == ["macOS-System", "Auslagerung (VM)", "Deine Daten", "Systembereiche",
                               "Schnappschüsse & nicht zuordenbar", "Frei"])
    #expect(s.map(\.bytes) == [19 * gb, 4 * gb, 248 * gb, 70 * gb, 72 * gb, 80 * gb])
    // Simulator-Volumes nur als Hinweis (stecken schon in Systembereichen).
    #expect(VolumeBarCard.simulatorNote(r) == "Simulator-Volumes: \(ByteFormat.string(18 * gb)) (bereits in Systembereichen enthalten)")
    let noSims = VolumeInventoryResult(containerSize: 494 * gb, containerFree: 80 * gb, volumes: inv.volumes, simulatorVolumes: [])
    #expect(VolumeBarCard.simulatorNote(report(inventory: noSims)) == nil)
    #expect(s[2].sizeText.hasPrefix("mindestens "))
    #expect(s[4].sizeText.hasPrefix("höchstens "))
    #expect(s[0].prefix == nil)
}

@MainActor @Test func barWithoutInventoryShowsOnlyMeasuredAreas() {
    let s = VolumeBarCard.segments(report(inventory: nil))
    #expect(s.map(\.title) == ["Deine Daten", "Systembereiche"])
}

@MainActor @Test func snapshotCardVisibility() {
    #expect(!SnapshotCard.isVisible(report(inventory: nil, unaccounted: 5_000_000_000)))
    #expect(SnapshotCard.isVisible(report(inventory: nil, unaccounted: 5_000_000_001)))
    let tm = Finding(id: FindingID(scannerID: "system.snapshots", key: "timeMachine"), category: .system, title: "TM", summary: "",
                     risk: .review, method: .admin([]), items: [], size: nil, blockingApps: [], keepSuggested: false,
                     commandPreview: [], needsFullDiskAccess: false)
    #expect(SnapshotCard.isVisible(report(inventory: nil, snapshots: [tm])))
}

@MainActor @Test func cleanupSummaryLosesOnlyTheWarningPrefix() {
    let warning = SystemCleanup.warning(for: "sysdata.libraryLogs")!
    let f = Finding(id: FindingID(scannerID: "sysdata.libraryLogs", key: "all"), category: .systemData, title: "Logs",
                    summary: "Achtung: \(warning) Nur alte Dateien.", risk: .review, method: .admin([]), items: [], size: 1,
                    blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false)
    #expect(SystemAreaFindings.summaryWithoutWarning(f) == "Nur alte Dateien.")
    #expect(SystemAreaFindings.byArea([f])["library.logs"]?.count == 1)
}

@MainActor @Test func revealURLStopsBeforeWildcard() {
    #expect(SystemAreaFindings.revealURL(URL(filePath: "/private/var/folders/*/*/C"))?.path == "/private/var/folders")
    #expect(SystemAreaFindings.revealURL(URL(filePath: "/Library/Caches"))?.path == "/Library/Caches")
}

@MainActor @Test func seeFindingTargetsTab() {
    func area(_ id: String, _ v: AreaVerdict) -> SystemArea {
        SystemArea(id: id, url: URL(filePath: "/x"), title: "", summary: "", verdict: v, size: 1, isLowerBound: false)
    }
    #expect(SystemAreaFindings.targetTab(area("opt", .seeFinding(scannerID: "brew.cleanup", tab: .developer))) == .developer)
    #expect(SystemAreaFindings.targetTab(area("var.folders.caches", .keep)) == .developer)
    #expect(SystemAreaFindings.targetTab(area("var.vm", .keep)) == nil)
}

private let sampleInventory = VolumeInventoryResult(
    containerSize: 494 * gb, containerFree: 80 * gb,
    volumes: [APFSVolume(name: "D", role: .data, consumed: 390 * gb)], simulatorVolumes: [])

@MainActor @Test func snapshotIntroNamesSegmentOnlyWhenShown() {
    let base = "Lokale Schnappschüsse belegen Platz, den macOS nicht einzeln ausweist."
    #expect(SnapshotCard.intro(report(inventory: nil, unaccounted: 0)) == base)
    #expect(SnapshotCard.intro(report(inventory: sampleInventory, unaccounted: 0)) == base)
    let shown = SnapshotCard.intro(report(inventory: sampleInventory, unaccounted: 72 * gb, upper: true))
    #expect(shown.contains("„Schnappschüsse & nicht zuordenbar“ (höchstens \(ByteFormat.string(72 * gb)))"))
}

@MainActor @Test func legendDropsEmptySegmentsButKeepsFree() {
    let segs = [BarSegment(title: "Auslagerung (VM)", bytes: 0, color: .gray, prefix: nil),
                BarSegment(title: "Deine Daten", bytes: 1, color: .gray, prefix: nil),
                BarSegment(title: "Frei", bytes: 0, color: .gray, prefix: nil)]
    #expect(VolumeBarCard.legendSegments(segs).map(\.title) == ["Deine Daten", "Frei"])
}

@MainActor @Test func unaccountedNoteHiddenWithoutInventory() {
    var r = report(inventory: nil)
    r.failures = [ScanFailure(scannerID: "systemdata.unaccounted", message: "zu hoch")]
    #expect(VolumeBarCard.notes(r).isEmpty)
    r.inventory = sampleInventory
    #expect(VolumeBarCard.notes(r) == ["zu hoch"])
}

@MainActor @Test func macUpdateHintSitsAtMatchingAssetChild() {
    let f = Finding(id: FindingID(scannerID: "sysdata.macUpdate", key: "all"), category: .systemData, title: "U", summary: "",
                    risk: .hintOnly, method: .hint(nil), items: [], size: 1, blockingApps: [], keepSuggested: false,
                    commandPreview: [], needsFullDiskAccess: false)
    func area(_ id: String, _ children: [SystemArea] = []) -> SystemArea {
        SystemArea(id: id, url: URL(filePath: "/x"), title: "", summary: "", verdict: .keep, size: 1, isLowerBound: false, children: children)
    }
    let withChild = [area("assets", [area("assets.com_apple_MobileAsset_MacSoftwareUpdate")])]
    #expect(SystemAreaFindings.byArea([f], areas: withChild)["assets.com_apple_MobileAsset_MacSoftwareUpdate"]?.count == 1)
    #expect(SystemAreaFindings.byArea([f], areas: [area("assets")])["assets"]?.count == 1)
}
