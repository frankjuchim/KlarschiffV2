import Testing
import Foundation
@testable import KlarschiffCore

private func blockThread(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

private let GB: Int64 = 1_000_000_000

private func diskutilOK() -> FakeCommandRunner {
    let fake = FakeCommandRunner()
    let text = try! String(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/diskutil-apfs-list.plist"), encoding: .utf8)
    fake.stub("/usr/sbin/diskutil", ["apfs", "list", "-plist"], result: CommandResult(exitCode: 0, stdout: text, stderr: ""))
    fake.stub("/usr/bin/tmutil", ["listlocalsnapshots", "/"], result: .fixture("tmutil-listlocalsnapshots.txt"))
    return fake
}

/// Stub: Größe nach Pfad relativ zur Fixture-Wurzel; Standard 0.
private func sizer(_ root: URL, _ sizes: [String: Int64], incomplete: Set<String> = [], hang: Set<String> = [])
    -> @Sendable (URL) async throws -> (size: Int64, complete: Bool) {
    let prefix = root.path
    return { url in
        var rel = url.path
        if rel.hasPrefix(prefix) { rel = String(rel.dropFirst(prefix.count)) }
        if hang.contains(rel) { try await Task.sleep(for: .seconds(600)) }
        return (sizes[rel] ?? 0, !incomplete.contains(rel))
    }
}

private func find(_ id: String, in areas: [SystemArea]) -> SystemArea? {
    for a in areas {
        if a.id == id { return a }
        if let c = find(id, in: a.children) { return c }
    }
    return nil
}

@Suite struct SystemDataScannerTests {
    @Test func sumsAreasAndRest() async throws {
        let tree = try FixtureTree()
        let ctx = ScanContext.test(root: tree.root, runner: diskutilOK())
        let scanner = SystemDataScanner(sizeOf: sizer(tree.root, [
            "/Library": 10 * GB, "/Library/Caches": 3 * GB, "/Library/Logs": 1 * GB,
            "/private/var/db": 5 * GB, "/private/var/db/diagnostics": 1 * GB, "/private/var/db/uuidtext": 1 * GB,
            "/private/var/vm": 2 * GB,
        ]))
        let report = await scanner.scan(ctx) { _, _ in }
        let lib = try #require(find("library", in: report.areas))
        #expect(lib.size == 10 * GB)
        #expect(find("library.other", in: report.areas)?.size == 6 * GB)
        #expect(find("library.caches", in: report.areas)?.size == 3 * GB)
        // extraPaths zählen zur Größe des Kinds und gegen den Rest des Elternbereichs
        #expect(find("var.db.diagnostics", in: report.areas)?.size == 2 * GB)
        #expect(find("var.db.other", in: report.areas)?.size == 3 * GB)
        #expect(report.systemAreasTotal == 17 * GB)
        #expect(report.inventory != nil)
        #expect(report.snapshotFindings.contains { $0.id.key == "update" })
        #expect(report.cleanupFindings.isEmpty)
    }

    @Test func globPathsAreSummed() async throws {
        let tree = try FixtureTree()
        try tree.dir("private/var/folders/aa/bb/C")
        try tree.dir("private/var/folders/cc/dd/C")
        try tree.dir("private/var/folders/cc/dd/T")
        let ctx = ScanContext.test(root: tree.root, runner: diskutilOK())
        let scanner = SystemDataScanner(sizeOf: sizer(tree.root, [
            "/private/var/folders": 10 * GB,
            "/private/var/folders/aa/bb/C": 2 * GB, "/private/var/folders/cc/dd/C": 3 * GB,
            "/private/var/folders/cc/dd/T": 1 * GB,
        ]))
        let report = await scanner.scan(ctx) { _, _ in }
        #expect(find("var.folders.caches", in: report.areas)?.size == 5 * GB)
        #expect(find("var.folders.temp", in: report.areas)?.size == 1 * GB)
        #expect(find("var.folders.other", in: report.areas)?.size == 4 * GB)
    }

    @Test func unaccountedNeverNegative() async throws {
        let tree = try FixtureTree()
        let ctx = ScanContext.test(root: tree.root, runner: diskutilOK())
        let scanner = SystemDataScanner(sizeOf: sizer(tree.root, ["/opt": 100_000 * GB]))
        let report = await scanner.scan(ctx) { _, _ in }
        #expect(report.unaccounted == 0)
    }

    @Test func unaccountedIsRemainder() async throws {
        let tree = try FixtureTree()
        let ctx = ScanContext.test(root: tree.root, runner: diskutilOK())
        let scanner = SystemDataScanner(sizeOf: sizer(tree.root, ["/opt": 2 * GB, "/Applications": 1 * GB]))
        let report = await scanner.scan(ctx) { _, _ in }
        let consumed = try #require(report.inventory?.volumes.first { $0.role == .data }).consumed
        #expect(report.userData == 1 * GB)
        #expect(report.systemAreasTotal == 2 * GB)
        #expect(report.unaccounted == consumed - 3 * GB)
    }

    @Test func lockedSubfolderMarksLowerBound() async throws {
        let tree = try FixtureTree()
        let ctx = ScanContext.test(root: tree.root, runner: diskutilOK())
        let scanner = SystemDataScanner(sizeOf: sizer(tree.root, [:], incomplete: ["/private/var/db/diagnostics"]))
        let report = await scanner.scan(ctx) { _, _ in }
        #expect(find("var.db.diagnostics", in: report.areas)?.isLowerBound == true)
        #expect(find("var.db", in: report.areas)?.isLowerBound == true)
        #expect(find("opt", in: report.areas)?.isLowerBound == false)
    }

    @Test func assetsGroupedWithNames() async throws {
        let tree = try FixtureTree()
        let base = "System/Volumes/Data/System/Library/AssetsV2"
        try tree.dir("\(base)/com_apple_MobileAsset_iOSSimulatorRuntime")
        try tree.dir("\(base)/com_apple_MobileAsset_Zzz")
        let ctx = ScanContext.test(root: tree.root, runner: diskutilOK())
        let scanner = SystemDataScanner(sizeOf: sizer(tree.root, [
            "/\(base)": 9 * GB,
            "/\(base)/com_apple_MobileAsset_iOSSimulatorRuntime": 7 * GB,
            "/\(base)/com_apple_MobileAsset_Zzz": 1 * GB,
        ]))
        let report = await scanner.scan(ctx) { _, _ in }
        let assets = try #require(find("assets", in: report.areas))
        #expect(assets.children.count == 2)
        let first = try #require(assets.children.first)
        #expect(first.title == "iOS-Simulator" && first.size == 7 * GB)
        #expect(first.verdict == .seeFinding(scannerID: "sim.runtimes", tab: .developer))
        #expect(!first.summary.isEmpty)
        #expect(assets.children[1].size == 1 * GB)
    }

    @Test func diskutilFailureStillMeasuresAreas() async throws {
        let tree = try FixtureTree()
        let fake = FakeCommandRunner()
        fake.stub("/usr/sbin/diskutil", ["apfs", "list", "-plist"], result: CommandResult(exitCode: 1, stdout: "", stderr: "boom"))
        let ctx = ScanContext.test(root: tree.root, runner: fake)
        let scanner = SystemDataScanner(sizeOf: sizer(tree.root, ["/opt": 2 * GB]))
        let report = await scanner.scan(ctx) { _, _ in }
        #expect(report.inventory == nil)
        #expect(!report.areas.isEmpty)
        #expect(report.unaccounted == 0)
        #expect(report.failures.contains { $0.scannerID.contains("volumes") })
    }

    @Test func areaTimeoutIsolated() async throws {
        let tree = try FixtureTree()
        let ctx = ScanContext.test(root: tree.root, runner: diskutilOK())
        let scanner = SystemDataScanner(areaTimeout: .milliseconds(200), sizeOf: sizer(tree.root, ["/private/var/vm": 2 * GB], hang: ["/opt"]))
        let report = await scanner.scan(ctx) { _, _ in }
        #expect(find("opt", in: report.areas)?.size == nil)
        #expect(find("var.vm", in: report.areas)?.size == 2 * GB)
        #expect(report.failures.contains { $0.scannerID.contains("opt") })
    }

    @Test func usrLocalWithoutTexLiveIsKeep() async throws {
        let tree = try FixtureTree()
        let scanner = SystemDataScanner(sizeOf: sizer(tree.root, [:]))
        var report = await scanner.scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(find("usrlocal", in: report.areas)?.verdict == .keep)
        try tree.dir("usr/local/texlive")
        report = await scanner.scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(find("usrlocal", in: report.areas)?.verdict == .seeFinding(scannerID: "toolchains.texlive", tab: .developer))
    }

    @Test func cleanupScannersFeedFindings() async throws {
        struct Stub: KlarschiffCore.Scanner {
            let id = "stub"
            func scan(_ ctx: ScanContext) async throws -> [Finding] { [.sample(size: 5)] }
        }
        let tree = try FixtureTree()
        let scanner = SystemDataScanner(sizeOf: sizer(tree.root, [:]), cleanupScanners: [Stub()])
        let report = await scanner.scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(report.cleanupFindings.count == 1)
    }

    @Test func unaccountedUpperBoundTriggers() async throws {
        let tree = try FixtureTree()
        let fast = Duration.milliseconds(200)
        // sauber
        var r = await SystemDataScanner(sizeOf: sizer(tree.root, [:])).scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(!r.unaccountedIsUpperBound && !r.userDataIsLowerBound)
        #expect(!r.failures.contains { $0.scannerID == "systemdata.unaccounted" })
        // Home-Unterordner unvollständig
        _ = try tree.dir("home/a")
        r = await SystemDataScanner(sizeOf: sizer(tree.root, [:], incomplete: ["/home/a"])).scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(r.userDataIsLowerBound && r.unaccountedIsUpperBound)
        #expect(r.failures.contains { $0.scannerID == "systemdata.unaccounted" })
        // /Applications Timeout
        r = await SystemDataScanner(areaTimeout: fast, sizeOf: sizer(tree.root, [:], hang: ["/Applications"])).scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(r.userDataIsLowerBound && r.unaccountedIsUpperBound)
        // Bereich unvollständig
        r = await SystemDataScanner(sizeOf: sizer(tree.root, [:], incomplete: ["/opt"])).scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(!r.userDataIsLowerBound && r.unaccountedIsUpperBound)
        // Bereich Timeout
        r = await SystemDataScanner(areaTimeout: fast, sizeOf: sizer(tree.root, [:], hang: ["/opt"])).scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(r.unaccountedIsUpperBound)
    }

    @Test func homeMeasuredPerChildWithOneHanging() async throws {
        let tree = try FixtureTree()
        for n in ["a", "b", ".hidden", "slow/x"] { _ = try tree.dir("home/\(n)") }
        let scanner = SystemDataScanner(areaTimeout: .milliseconds(300), sizeOf: sizer(tree.root, [
            "/home/a": 2 * GB, "/home/.hidden": 1 * GB, "/home/b": GB / 2, "/Applications": 3 * GB], hang: ["/home/slow", "/home/slow/x"]))
        let r = await scanner.scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(r.userData == 2 * GB + 1 * GB + GB / 2 + 3 * GB)
        #expect(r.userDataIsLowerBound && r.unaccountedIsUpperBound)
        #expect(r.failures.contains { $0.scannerID == "systemdata.userdata.home.slow.x" })
    }

    @Test func homeChildTimeoutFallsBackToGrandchildren() async throws {
        let tree = try FixtureTree()
        for n in ["home/Library/A", "home/Library/B", "home/Pictures"] { _ = try tree.dir(n) }
        let sizes: [String: Int64] = ["/home/Library/A": 2 * GB, "/home/Library/B": 1 * GB, "/home/Pictures": 4 * GB]
        let scanner = SystemDataScanner(areaTimeout: .milliseconds(300), sizeOf: sizer(tree.root, sizes, hang: ["/home/Library"]))
        var r = await scanner.scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(r.userData == 7 * GB)
        #expect(!r.userDataIsLowerBound)
        // Ein Enkel hängt zusätzlich: zählt 0, Flag gesetzt, keine tiefere Rekursion.
        r = await SystemDataScanner(areaTimeout: .milliseconds(300), sizeOf: sizer(tree.root, sizes, hang: ["/home/Library", "/home/Library/B"]))
            .scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(r.userData == 6 * GB)
        #expect(r.userDataIsLowerBound)
        // Ein Enkel unvollständig
        r = await SystemDataScanner(areaTimeout: .milliseconds(300), sizeOf: sizer(tree.root, sizes, incomplete: ["/home/Library/A"], hang: ["/home/Library"]))
            .scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(r.userDataIsLowerBound)
    }

    @Test func fallbackCountsDirectFiles() async throws {
        let tree = try FixtureTree()
        _ = try tree.dir("home/Library/A")
        _ = try tree.file("home/Library/loose.bin", bytes: 100_000)
        let scanner = SystemDataScanner(areaTimeout: .milliseconds(300), sizeOf: sizer(tree.root, ["/home/Library/A": GB], hang: ["/home/Library"]))
        let r = await scanner.scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(r.userData >= GB + 100_000)
        #expect(r.userData < GB + 1_000_000)
        #expect(!r.userDataIsLowerBound)
        #expect(r.failures.contains { $0.message.contains("in Unterordnern gemessen") })
    }

    @Test func fallbackListingFailureSetsLowerBound() async throws {
        let tree = try FixtureTree()
        let lib = try tree.dir("home/Library")
        _ = try tree.dir("home/Library/A")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lib.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lib.path) }
        let scanner = SystemDataScanner(areaTimeout: .milliseconds(300), sizeOf: sizer(tree.root, [:], hang: ["/home/Library"]))
        let r = await scanner.scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(r.userDataIsLowerBound)
    }

    @Test func unreadableHomeSetsLowerBound() async throws {
        let tree = try FixtureTree()
        let home = try tree.dir("home")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path) }
        let r = await SystemDataScanner(sizeOf: sizer(tree.root, [:])).scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(r.userDataIsLowerBound)
    }

    @Test func homeSymlinkedChildSkipped() async throws {
        let tree = try FixtureTree()
        _ = try tree.dir("home/real")
        try FileManager.default.createSymbolicLink(at: tree.root.appending(path: "home/link"), withDestinationURL: tree.root.appending(path: "home/real"))
        let scanner = SystemDataScanner(sizeOf: sizer(tree.root, ["/home/real": GB, "/home/link": 5 * GB]))
        let r = await scanner.scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(r.userData == GB)
        #expect(!r.userDataIsLowerBound)
    }

    @Test func restOmittedWhenNamedChildMissing() async throws {
        let tree = try FixtureTree()
        let scanner = SystemDataScanner(areaTimeout: .milliseconds(200), sizeOf: sizer(tree.root, ["/Library": 10 * GB, "/Library/Logs": 1 * GB], hang: ["/Library/Caches"]))
        let r = await scanner.scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(find("library.caches", in: r.areas)?.size == nil)
        #expect(find("library.other", in: r.areas) == nil)
        #expect(find("library", in: r.areas)?.size == 10 * GB)
    }

    @Test func restLowerBoundOnlyFromParent() async throws {
        let tree = try FixtureTree()
        let scanner = SystemDataScanner(sizeOf: sizer(tree.root, ["/Library": 10 * GB, "/Library/Caches": 3 * GB], incomplete: ["/Library/Caches"]))
        let r = await scanner.scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(find("library.other", in: r.areas)?.isLowerBound == false)
        #expect(find("library", in: r.areas)?.isLowerBound == true)
    }

    @Test func timedOutParentUsesChildrenSum() async throws {
        let tree = try FixtureTree()
        let scanner = SystemDataScanner(areaTimeout: .milliseconds(200), sizeOf: sizer(tree.root, ["/Library/Caches": 3 * GB, "/Library/Logs": 1 * GB], hang: ["/Library"]))
        let r = await scanner.scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        let lib = try #require(find("library", in: r.areas))
        #expect(lib.size == 4 * GB && lib.isLowerBound)
        #expect(find("library.other", in: r.areas) == nil)
        #expect(r.systemAreasTotal == 4 * GB)
        #expect(r.failures.contains { $0.scannerID == "systemdata.library" })
    }

    @Test func inventoryWithoutDataVolumeGivesHint() async throws {
        let tree = try FixtureTree()
        let fake = FakeCommandRunner()
        let plist = try String(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/diskutil-apfs-list.plist"), encoding: .utf8)
            .replacingOccurrences(of: "<string>Data</string>", with: "<string>Other</string>")
        fake.stub("/usr/sbin/diskutil", ["apfs", "list", "-plist"], result: CommandResult(exitCode: 0, stdout: plist, stderr: ""))
        let r = await SystemDataScanner(sizeOf: sizer(tree.root, [:])).scan(.test(root: tree.root, runner: fake)) { _, _ in }
        // ohne Data-Rolle schlägt parse mit noStartContainer fehl -> inventory nil, Hinweis vorhanden
        #expect(r.unaccounted == 0)
        #expect(r.failures.contains { $0.scannerID == "systemdata.volumes" })
    }

    @Test func unreadableGlobLevelMarksLowerBound() async throws {
        let tree = try FixtureTree()
        let locked = try tree.dir("private/var/folders/aa")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let r = await SystemDataScanner(sizeOf: sizer(tree.root, [:])).scan(.test(root: tree.root, runner: diskutilOK())) { _, _ in }
        #expect(find("var.folders.caches", in: r.areas)?.isLowerBound == true)
        #expect(find("var.folders", in: r.areas)?.isLowerBound == true)
    }

    @Test func deadlineFiresEvenIfOperationIgnoresCancellation() async throws {
        let start = ContinuousClock.now
        let result = await Deadline.run(.milliseconds(200)) { () async throws -> Int in
            // kooperationslos: blockiert den Thread ohne Cancellation-Prüfung
            blockThread(seconds: 3)
            return 1
        }
        guard case .failure(.timeout) = result else { Issue.record("kein Timeout"); return }
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
