import Testing
import Foundation
@testable import KlarschiffCore

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
}
