import Testing
import Foundation
@testable import KlarschiffCore

private func run(_ scanner: any KlarschiffCore.Scanner, _ ctx: ScanContext) async throws -> [Finding] {
    try await scanner.scan(ctx)
}

@Suite struct SystemCleanupScannerTests {
    // MARK: Temp

    @Test func tempOnlyOlderThan3Days() async throws {
        let tree = try FixtureTree()
        try tree.file("T/old", bytes: 100)
        try tree.file("T/new", bytes: 100)
        try tree.file("T/dir/inner", bytes: 100)
        try tree.file("T/olddir/inner", bytes: 100)
        try tree.setModified("T/old", daysAgo: 4)
        try tree.setModified("T/new", daysAgo: 1)
        try tree.setModified("T/dir/inner", daysAgo: 1)
        try tree.setModified("T/dir", daysAgo: 5)
        try tree.setModified("T/olddir/inner", daysAgo: 6)
        try tree.setModified("T/olddir", daysAgo: 6)
        let ctx = ScanContext.test(root: tree.root)
        let f = try #require(try await run(TempScanner(), ctx).first)
        #expect(f.id.scannerID == "sysdata.temp")
        #expect(Set(f.items.map(\.name)) == ["old", "olddir"])
        #expect(f.method == .delete)
        #expect(f.commandPreview.allSatisfy { $0.hasPrefix("rm -rf ") })
    }

    @Test func tempSkipsSymlinks() async throws {
        let tree = try FixtureTree()
        let docs = try tree.dir("home/Documents")
        try tree.file("home/Documents/keep.txt", bytes: 10)
        try tree.symlink("T/evil", to: docs)
        try tree.file("T/real", bytes: 10)
        try tree.setModified("T/real", daysAgo: 10)
        let ctx = ScanContext.test(root: tree.root)
        let f = try #require(try await run(TempScanner(), ctx).first)
        #expect(f.items.map(\.name) == ["real"])
    }

    @Test func tempNoFindingWhenNothingOld() async throws {
        let tree = try FixtureTree()
        try tree.file("T/new", bytes: 10)
        #expect(try await run(TempScanner(), ScanContext.test(root: tree.root)).isEmpty)
    }

    // MARK: Library/Caches

    @Test func libraryCachesAdminStepsUseRealPaths() async throws {
        let tree = try FixtureTree()
        try tree.file("Library/Caches/com.example/a", bytes: 1000)
        try tree.file("Library/Caches/com.apple.iconservices.store/a", bytes: 1000)
        try tree.file("Library/Caches/com.apple.aned/a", bytes: 1000)
        try tree.file("Library/Caches/com.apple.amsengagementd.classicdatavault/a", bytes: 1000)
        try tree.file("Library/Caches/loose.file", bytes: 10)
        try tree.dir("elsewhere")
        try tree.symlink("Library/Caches/link", to: tree.root.appending(path: "elsewhere"))
        let ctx = ScanContext.test(root: tree.root)
        let f = try #require(try await run(LibraryCachesScanner(), ctx).first)
        #expect(f.id.scannerID == "sysdata.libraryCaches")
        #expect(f.method == .admin([
            AdminStep(executable: "/bin/rm", arguments: ["-rf", "/Library/Caches/com.example"]),
            AdminStep(executable: "/bin/rm", arguments: ["-rf", "/Library/Caches/loose.file"]),
        ]))
        #expect(f.items.map(\.name) == ["com.example", "loose.file"])
        #expect(f.commandPreview.first == "sudo /bin/rm -rf /Library/Caches/com.example")
    }

    @Test func libraryCachesExclusionIsCaseInsensitive() async throws {
        let tree = try FixtureTree()
        try tree.file("Library/Caches/COM.APPLE.ICONSERVICES.STORE/a", bytes: 1000)
        #expect(try await run(LibraryCachesScanner(), ScanContext.test(root: tree.root)).isEmpty)
    }

    @Test func libraryCachesUnreadableChildHasNoExactSize() async throws {
        let tree = try FixtureTree()
        let locked = try tree.dir("Library/Caches/com.locked/sub")
        try tree.file("Library/Caches/com.locked/x", bytes: 1000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let f = try #require(try await run(LibraryCachesScanner(), ScanContext.test(root: tree.root)).first)
        #expect(f.items.first?.size == nil)
        #expect(f.items.first?.detail != nil)
    }

    // MARK: Library/Logs

    @Test func logsOlderThan30Days() async throws {
        let tree = try FixtureTree()
        try tree.file("Library/Logs/old.log", bytes: 10)
        try tree.file("Library/Logs/new.log", bytes: 10)
        try tree.file("Library/Logs/Sub/old2.log", bytes: 10)
        try tree.file("Library/Logs/Sub/new2.log", bytes: 10)
        try tree.setModified("Library/Logs/old.log", daysAgo: 31)
        try tree.setModified("Library/Logs/new.log", daysAgo: 29)
        try tree.setModified("Library/Logs/Sub/old2.log", daysAgo: 40)
        try tree.setModified("Library/Logs/Sub/new2.log", daysAgo: 2)
        let ctx = ScanContext.test(root: tree.root)
        let f = try #require(try await run(LibraryLogsScanner(isTrustedOwner: { _ in true }), ctx).first)
        #expect(f.id.scannerID == "sysdata.libraryLogs")
        #expect(f.method == .admin([
            AdminStep(executable: "/bin/rm", arguments: ["-f", "/Library/Logs/Sub/old2.log"]),
            AdminStep(executable: "/bin/rm", arguments: ["-f", "/Library/Logs/old.log"]),
        ]))
        #expect(f.items.count == 2)
    }

    @Test func logsSkipSubfoldersNotOwnedBySystem() async throws {
        let tree = try FixtureTree()
        try tree.file("Library/Logs/top.log", bytes: 10)
        try tree.file("Library/Logs/Sub/deep.log", bytes: 10)
        try tree.setModified("Library/Logs/top.log", daysAgo: 40)
        try tree.setModified("Library/Logs/Sub/deep.log", daysAgo: 40)
        let ctx = ScanContext.test(root: tree.root)
        let f = try #require(try await run(LibraryLogsScanner(isTrustedOwner: { _ in false }), ctx).first)
        #expect(f.items.map(\.name) == ["top.log"])
        // Standard: Fixture gehört dem aktuellen (Nicht-System-)Benutzer.
        if getuid() >= 500 {
            let g = try #require(try await run(LibraryLogsScanner(), ctx).first)
            #expect(g.items.map(\.name) == ["top.log"])
        }
    }

    @Test func logsSkipSymlinksAndNeverFollowThem() async throws {
        let tree = try FixtureTree()
        let target = try tree.dir("elsewhere")
        try tree.file("elsewhere/x.log", bytes: 10)
        try tree.setModified("elsewhere/x.log", daysAgo: 99)
        try tree.symlink("Library/Logs/linkdir", to: target)
        try tree.symlink("Library/Logs/link.log", to: target.appending(path: "x.log"))
        let ctx = ScanContext.test(root: tree.root)
        #expect(try await run(LibraryLogsScanner(isTrustedOwner: { _ in true }), ctx).isEmpty)
    }

    // MARK: Unified Log

    @Test func unifiedLogUsesLogErase() async throws {
        let tree = try FixtureTree()
        try tree.file("private/var/db/diagnostics/a", bytes: 4000)
        try tree.file("private/var/db/uuidtext/b", bytes: 4000)
        let f = try #require(try await run(UnifiedLogScanner(), ScanContext.test(root: tree.root)).first)
        #expect(f.id.scannerID == "sysdata.unifiedLog")
        #expect(f.method == .admin([AdminStep(executable: "/usr/bin/log", arguments: ["erase", "--all"])]))
        #expect(f.items.count == 1)
        #expect(f.commandPreview == ["sudo /usr/bin/log erase --all"])
        #expect((f.size ?? 0) > 0)
    }

    @Test func unifiedLogAbsentWhenNoDirectories() async throws {
        let tree = try FixtureTree()
        #expect(try await run(UnifiedLogScanner(), ScanContext.test(root: tree.root)).isEmpty)
    }

    // MARK: Hinweis

    @Test func macUpdateHintOnlyWhenAssetsPresent() async throws {
        let tree = try FixtureTree()
        let ctx = ScanContext.test(root: tree.root)
        #expect(try await run(MacUpdateHintScanner(), ctx).isEmpty)
        try tree.file("System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate/x/y", bytes: 5000)
        let f = try #require(try await run(MacUpdateHintScanner(), ctx).first)
        #expect(f.id.scannerID == "sysdata.macUpdate")
        #expect(f.risk == .hintOnly)
        #expect(f.category == KlarschiffCore.Category.systemData)
        if case .hint(.some(.openURL)) = f.method {} else { Issue.record("kein openURL-Hinweis") }
        #expect(!f.isPreselected(isKept: false))
    }

    // MARK: Gesamt

    @Test func allSystemFindingsNeverPreselected() async throws {
        let tree = try FixtureTree()
        try tree.file("T/old", bytes: 100); try tree.setModified("T/old", daysAgo: 9)
        try tree.file("Library/Caches/com.example/a", bytes: 100)
        try tree.file("Library/Logs/o.log", bytes: 10); try tree.setModified("Library/Logs/o.log", daysAgo: 99)
        try tree.file("private/var/db/diagnostics/a", bytes: 100)
        try tree.file("System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate/x", bytes: 5000)
        let ctx = ScanContext.test(root: tree.root)
        var all: [Finding] = []
        for s in SystemCleanup.scanners() { all += try await s.scan(ctx) }
        let ids = Set(all.map(\.id.scannerID))
        #expect(ids.isSuperset(of: ["sysdata.temp", "sysdata.libraryCaches", "sysdata.unifiedLog", "sysdata.macUpdate"]))
        #expect(Set(SystemCleanup.scanners().map(\.id)) == [
            "sysdata.temp", "sysdata.libraryCaches", "sysdata.libraryLogs", "sysdata.unifiedLog", "sysdata.macUpdate"])
        for f in all {
            #expect(f.category == KlarschiffCore.Category.systemData)
            #expect(!f.isPreselected(isKept: false))
            if f.risk == .hintOnly { continue }
            #expect(f.risk == .review)
            #expect(f.summary.hasPrefix("Achtung: "))
        }
    }

    @Test func systemDataScannerDefaultsToCleanupScanners() async throws {
        let tree = try FixtureTree()
        try tree.file("private/var/db/diagnostics/a", bytes: 100)
        let fake = FakeCommandRunner()
        let ctx = ScanContext.test(root: tree.root, runner: fake)
        let report = await SystemDataScanner().scan(ctx) { _, _ in }
        #expect(report.cleanupFindings.contains { $0.id.scannerID == "sysdata.unifiedLog" })
    }

    // MARK: Fix round 1

    @Test func logTrustSeparatesOwnerGroupAndWorld() {
        let T = LibraryLogsScanner.isTrustedDirectory
        #expect(T(0, 0, 0o755, { $0 < 500 }, LibraryLogsScanner.trustedWriteGroups))
        #expect(!T(0, 20, 0o775, { $0 < 500 }, LibraryLogsScanner.trustedWriteGroups))   // staff
        #expect(!T(0, 12, 0o775, { $0 < 500 }, LibraryLogsScanner.trustedWriteGroups))   // everyone
        #expect(!T(0, 61, 0o775, { $0 < 500 }, LibraryLogsScanner.trustedWriteGroups))   // localaccounts
        #expect(!T(0, 0, 0o757, { $0 < 500 }, LibraryLogsScanner.trustedWriteGroups))    // o+w
        #expect(T(0, 80, 0o775, { $0 < 500 }, LibraryLogsScanner.trustedWriteGroups))    // admin
        #expect(T(0, 250, 0o770, { $0 < 500 }, LibraryLogsScanner.trustedWriteGroups))   // _analyticsusers
        #expect(T(0, 20, 0o755, { $0 < 500 }, LibraryLogsScanner.trustedWriteGroups))    // staff, nicht schreibbar
        #expect(!T(501, 0, 0o755, { $0 < 500 }, LibraryLogsScanner.trustedWriteGroups))  // Benutzer als Besitzer
    }

    @Test func logWalkSkipsGroupAndWorldWritableDirs() async throws {
        let tree = try FixtureTree()
        for d in ["Grp", "Wld", "Ok"] {
            try tree.file("Library/Logs/\(d)/f.log", bytes: 10)
            try tree.setModified("Library/Logs/\(d)/f.log", daysAgo: 60)
        }
        func chmod(_ rel: String, _ m: Int) throws {
            try FileManager.default.setAttributes([.posixPermissions: m], ofItemAtPath: tree.root.appending(path: rel).path)
        }
        try chmod("Library/Logs/Grp", 0o775)   // Gruppe des Testbenutzers ist nicht in der Vertrauensliste
        try chmod("Library/Logs/Wld", 0o757)
        let ctx = ScanContext.test(root: tree.root)
        let f = try #require(try await run(LibraryLogsScanner(isTrustedOwner: { _ in true }), ctx).first)
        #expect(f.items.map { $0.url!.deletingLastPathComponent().lastPathComponent } == ["Ok"])
        // Wird die Gruppe des Ordners ausdrücklich vertraut, ist er erlaubt.
        let gid = UInt((try FileManager.default.attributesOfItem(atPath: tree.root.appending(path: "Library/Logs/Grp").path)[.groupOwnerAccountID] as? NSNumber)?.uintValue ?? 0)
        let g = try #require(try await run(LibraryLogsScanner(isTrustedOwner: { _ in true }, writableGroups: [gid]), ctx).first)
        #expect(g.items.count == 2)
    }

    @Test func logsCappedAt500Largest() async throws {
        let tree = try FixtureTree()
        for i in 0..<503 {
            try tree.file("Library/Logs/l\(String(format: "%03d", i)).log", bytes: i < 3 ? 1 : 8192)
            try tree.setModified("Library/Logs/l\(String(format: "%03d", i)).log", daysAgo: 60)
        }
        let ctx = ScanContext.test(root: tree.root)
        let f = try #require(try await run(LibraryLogsScanner(isTrustedOwner: { _ in true }), ctx).first)
        #expect(f.items.count == 500)
        guard case .admin(let steps) = f.method else { Issue.record("keine Admin-Methode"); return }
        #expect(steps.count == 500)
        #expect(!f.items.contains { $0.name == "l000.log" })
        #expect(f.summary.contains("3 weitere beim nächsten Durchgang"))
        #expect(f.summary.hasPrefix("Achtung: "))
    }

    @Test func tempDirWithUnreadableSubfolderNotOffered() async throws {
        let tree = try FixtureTree()
        let sub = try tree.dir("T/olddir/locked")
        try tree.file("T/olddir/x", bytes: 10)
        try tree.setModified("T/olddir/x", daysAgo: 9)
        try tree.setModified("T/olddir/locked", daysAgo: 9)
        try tree.setModified("T/olddir", daysAgo: 9)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sub.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path) }
        #expect(try await run(TempScanner(), ScanContext.test(root: tree.root)).isEmpty)
    }

    @Test func cachesSkipHomebrewNames() async throws {
        let tree = try FixtureTree()
        try tree.file("Library/Caches/Cellar/a", bytes: 10)
        try tree.file("Library/Caches/Caskroom/a", bytes: 10)
        #expect(try await run(LibraryCachesScanner(), ScanContext.test(root: tree.root)).isEmpty)
    }
}
