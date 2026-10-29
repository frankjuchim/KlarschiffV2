import Testing
import Foundation
@testable import KlarschiffCore

struct PersonalDataScannerTests {
    @Test func installersOlderThan30Days() async throws {
        let t = try FixtureTree()
        try t.file("home/Downloads/a.dmg", bytes: 100); try t.setModified("home/Downloads/a.dmg", daysAgo: 40)
        try t.file("home/Downloads/b.pkg", bytes: 100); try t.setModified("home/Downloads/b.pkg", daysAgo: 5)
        try t.file("home/Downloads/c.txt", bytes: 100); try t.setModified("home/Downloads/c.txt", daysAgo: 90)
        try t.file("home/Downloads/sub/d.zip", bytes: 100); try t.setModified("home/Downloads/sub/d.zip", daysAgo: 90)
        let fs = try await OldInstallerScanner().scan(.test(root: t.root))
        #expect(fs.count == 1)
        let f = fs[0]
        #expect(f.items.map(\.name) == ["a.dmg"])
        #expect(f.items[0].detail?.hasPrefix("vom ") == true)
        #expect(f.method == .trash && f.risk == .review)
        #expect(f.commandPreview.allSatisfy { $0.hasPrefix("In den Papierkorb: ") })
    }

    @Test func installersNoneMeansNoFinding() async throws {
        let t = try FixtureTree()
        try t.file("home/Downloads/b.pkg", bytes: 100)
        #expect(try await OldInstallerScanner().scan(.test(root: t.root)).isEmpty)
    }

    private func makeBackup(_ t: FixtureTree, id: String, device: String) throws {
        try t.file("home/Library/Application Support/MobileSync/Backup/\(id)/Manifest.db", bytes: 2000)
        let plist: [String: Any] = ["Device Name": device, "Last Backup Date": Date(timeIntervalSince1970: 1_700_000_000)]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: t.root.appending(path: "home/Library/Application Support/MobileSync/Backup/\(id)/Info.plist"))
    }

    @Test func backupShowsDeviceAndNeedsFDA() async throws {
        let t = try FixtureTree()
        try makeBackup(t, id: "abc123", device: "Franks iPhone")
        let fs = try await MobileBackupScanner().scan(.test(root: t.root, hasFullDiskAccess: true))
        #expect(fs.count == 1)
        #expect(fs[0].title == "Backup von Franks iPhone")
        #expect(fs[0].items[0].detail?.hasPrefix("vom ") == true)
        #expect(fs[0].needsFullDiskAccess && fs[0].method == .trash && fs[0].risk == .review)
        #expect(fs[0].size ?? 0 >= 2000)

        let no = try await MobileBackupScanner().scan(.test(root: t.root, hasFullDiskAccess: false))
        #expect(no.count == 1)
        #expect(no[0].id.key == "noAccess" && no[0].size == nil && no[0].items.isEmpty)
        #expect(no[0].summary.contains("Braucht Vollzugriff auf die Festplatte"))
    }

    @Test func backupMissingFolderIsEmpty() async throws {
        let t = try FixtureTree()
        #expect(try await MobileBackupScanner().scan(.test(root: t.root)).isEmpty)
    }

    @Test func messagesHint() async throws {
        let t = try FixtureTree()
        try t.file("home/Library/Messages/Attachments/ab/x.jpg", bytes: 3000)
        let fs = try await MessagesAttachmentsScanner().scan(.test(root: t.root))
        #expect(fs.count == 1)
        #expect(fs[0].risk == .hintOnly && fs[0].method == .hint(nil))
        #expect(fs[0].size ?? 0 >= 3000)
        #expect(fs[0].summary.contains("1 Jahr"))
        let no = try await MessagesAttachmentsScanner().scan(.test(root: t.root, hasFullDiskAccess: false))
        #expect(no.count == 1 && no[0].size == nil)
        let none = try FixtureTree()
        #expect(try await MessagesAttachmentsScanner().scan(.test(root: none.root)).isEmpty)
    }

    @Test func registeredInCatalog() {
        let ids = Catalog.allScanners().map(\.id)
        #expect(["personal.backups", "personal.installers", "personal.messages"].allSatisfy(ids.contains))
    }
}
