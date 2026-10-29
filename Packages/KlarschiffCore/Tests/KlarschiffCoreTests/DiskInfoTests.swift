import Testing
import Foundation
@testable import KlarschiffCore

struct DiskInfoTests {
    @Test func diskInfoReportsPlausibleValues() throws {
        let d = try DiskInfo.current(volume: URL(filePath: "/"))
        #expect(d.total > 0 && d.free > 0 && d.free <= d.total)
    }

    @Test func missingVolumeThrows() {
        #expect(throws: (any Error).self) {
            try DiskInfo.current(volume: URL(filePath: "/nonexistent/klarschiff-volume"))
        }
    }

    @Test func fullDiskAccessDeniedWhenNoProtectedPathExists() throws {
        let t = try FixtureTree()
        #expect(FullDiskAccess.isGranted(home: t.root) == false)
    }

    @Test func fullDiskAccessGrantedWhenSafariReadable() throws {
        let t = try FixtureTree()
        try t.dir("Library/Safari")
        #expect(FullDiskAccess.isGranted(home: t.root) == true)
    }

    @Test func fullDiskAccessGrantedWhenStocksReadable() throws {
        let t = try FixtureTree()
        try t.dir("Library/Containers/com.apple.stocks")
        #expect(FullDiskAccess.isGranted(home: t.root) == true)
    }

    @Test func settingsURLOpensPrivacyAllFiles() {
        #expect(FullDiskAccess.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }
}
