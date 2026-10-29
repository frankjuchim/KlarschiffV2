import Testing
import Foundation
@testable import KlarschiffCore

private let guardUnderTest = SafetyGuard(
    home: URL(filePath: "/Users/test"),
    userCacheDir: URL(filePath: "/private/var/folders/ab/xyz/C"),
    allowedCacheSubdirs: SafetyGuard.defaultAllowedCacheSubdirs
)

@Suite struct SafetyGuardTests {
    @Test(arguments: [
        "/", "/System/Library", "/usr/bin", "/bin/ls", "/sbin", "/private/var/folders/ab/xyz/C",
        "/private/var/folders/ab/xyz/T/foo", "/private/var/folders/ab/xyz/C/com.apple.Safari",
        "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime",
        "/opt/homebrew/Caskroom/flutter", "/opt/homebrew/Cellar/git", "/opt/homebrew/Caskroom",
        "/Users/test", "/Users/test/Library", "/Users/test/Documents", "/Users/test/Documents/x",
        "/Users/test/Desktop/x", "/Users/test/Pictures/Fotos.photoslibrary",
        "/Users/test/Pictures/Fotos.photoslibrary/originals/a.jpg",
        "/Users/test/.codex/auth.json", "/Users/test/.gemini/oauth_creds.json",
        "/Users/test/.config/gh/hosts.yml", "/Users/test/.config",
        "/Users/test/.codex", "/Users/test/.codex/config.toml", "/Users/test/.copilot/credentials.json",
        "/Users/test/.codex/sub/.env", "/Users/test/.gemini/keychain-x",
        "/Users/test/.ssh/id_ed25519", "/Users/test/.ssh", "/Users/test/.gnupg/x", "/Users/test/.aws/credentials",
        "/Users/test/.kube/config", "/Users/test/.docker/config.json", "/Users/test/Library/Keychains/login.keychain-db",
        "/Applications", "/Applications/notes.txt", "/Applications/TeX/../Utilities",
        "/usr/local/bin", "/usr/local", "/opt", "/tmp/foo", "/etc/hosts", "/var/db/x",
        "relative/path", "",
        // Traversal / Groß-Kleinschreibung
        "/Users/test/Library/Caches/../../Documents/x", "/Users/test/./Documents",
        "/users/test/documents", "/USERS/TEST/DOCUMENTS/x", "/Users/test/.SSH/id", "/Users/test/.CODEX/Auth.JSON",
        "/Users/test/Library/Developer/Xcode/../../../Documents/x",
        "/private/var/folders/ab/xyz/C/com.apple.dt.Instruments/../com.apple.Safari",
        "/var/folders/ab/xyz/C/com.apple.Safari", "/private/var/folders/ab/xyz/C/clangx",
        "/Users/test/Library/Developer/Xcode/DerivedData/Caskroom/x",
        "/usr/local/texlive/Cellar", "/Users/tester/Library/x", "/Users/testx/Library/x",
    ])
    func denies(_ path: String) {
        #expect(guardUnderTest.check(URL(filePath: path)) != .allowed, "\(path)")
    }

    @Test(arguments: [
        "/private/var/folders/ab/xyz/C/com.apple.dt.Instruments",
        "/private/var/folders/ab/xyz/C/clang/ModuleCache/x",
        "/var/folders/ab/xyz/C/com.apple.dt.Instruments",
        "/var/folders/ab/xyz/C/org.llvm.clang.ModuleCache/abc",
        "/Users/test/Library/Developer/Xcode/DerivedData/App-abc", "/usr/local/texlive/2022",
        "/usr/local/texlive", "/Library/TeX/texbin", "/opt/anaconda3/envs/x", "/opt/miniconda3",
        "/Library/Developer/Xcode/iOS DeviceSupport/x",
        "/Users/test/.codex/log", "/Users/test/.codex/log/a.log", "/Users/test/Library/Caches/foo",
        "/Applications/Xcode-beta.app", "/Applications/Xcode.app/Contents", "/Applications/TeX/x",
        "/Users/test/Library/Developer/Xcode/../Xcode/DerivedData/x",
    ])
    func allows(_ path: String) {
        #expect(guardUnderTest.check(URL(filePath: path)) == .allowed, "\(path)")
    }

    @Test func deniedReasonsAreGerman() {
        func reason(_ p: String) -> String? {
            if case .denied(let r) = guardUnderTest.check(URL(filePath: p)) { return r }
            return nil
        }
        #expect(reason("/System/Library") == "Geschützter Systemordner")
        #expect(reason("/Users/test/.ssh/id") == "Zugangsdaten werden nie angefasst")
        #expect(reason("/opt/homebrew/Caskroom/x") == "Nur über Homebrew entfernbar")
        #expect(reason("/opt/foo") == "Liegt außerhalb der erlaubten Ordner")
    }

    @Test func deniesSymlinkEscapingRoot() throws {
        let t = try FixtureTree()
        let docs = try t.dir("home/Documents")
        try t.symlink("home/Library/Caches/evil", to: docs)
        let g = SafetyGuard(home: t.root.appending(path: "home"), userCacheDir: t.root.appending(path: "C"), allowedCacheSubdirs: [])
        #expect(g.check(t.root.appending(path: "home/Library/Caches/evil")) != .allowed)
        #expect(g.check(t.root.appending(path: "home/Library/Caches/evil/sub/file")) != .allowed)
        #expect(g.check(t.root.appending(path: "home/Library/Caches/evil/../evil")) != .allowed)
    }

    @Test func deniesSymlinkIntoCredentials() throws {
        let t = try FixtureTree()
        let ssh = try t.dir("home/.ssh")
        try t.symlink("home/Library/link", to: ssh)
        let g = SafetyGuard(home: t.root.appending(path: "home"), userCacheDir: t.root.appending(path: "C"), allowedCacheSubdirs: [])
        #expect(g.check(t.root.appending(path: "home/Library/link/id_rsa")) != .allowed)
    }

    @Test func allowsRealPathInsideHomeAndSymlinkedHome() throws {
        let t = try FixtureTree()
        try t.file("home/Library/Developer/Xcode/DerivedData/A/f", bytes: 3)
        let g = SafetyGuard(home: t.root.appending(path: "home"), userCacheDir: t.root.appending(path: "C"), allowedCacheSubdirs: [])
        #expect(g.check(t.root.appending(path: "home/Library/Developer/Xcode/DerivedData/A")) == .allowed)
        // Home über Symlink angegeben
        try t.symlink("homelink", to: t.root.appending(path: "home"))
        let g2 = SafetyGuard(home: t.root.appending(path: "homelink"), userCacheDir: t.root.appending(path: "C"), allowedCacheSubdirs: [])
        #expect(g2.check(t.root.appending(path: "home/Library/Developer/Xcode/DerivedData/A")) == .allowed)
        #expect(g2.check(t.root.appending(path: "home/Documents")) != .allowed)
        #expect(g2.check(t.root.appending(path: "homelink/Documents")) != .allowed)
    }

    @Test func caskroomInsideAllowedRootDenied() throws {
        let t = try FixtureTree()
        try t.dir("home/Library/Developer/Caskroom/x")
        let g = SafetyGuard(home: t.root.appending(path: "home"), userCacheDir: t.root.appending(path: "C"), allowedCacheSubdirs: [])
        #expect(g.check(t.root.appending(path: "home/Library/Developer/Caskroom/x")) != .allowed)
    }

    @Test func sidlingPrefixIsNotUnderRoot() {
        let g = SafetyGuard(home: URL(filePath: "/Users/test"), userCacheDir: URL(filePath: "/private/var/folders/ab/xyz/C"), allowedCacheSubdirs: ["clang"])
        #expect(g.check(URL(filePath: "/Users/test2/Library/x")) != .allowed)
        #expect(g.check(URL(filePath: "/Library/TeXtra")) != .allowed)
        #expect(g.check(URL(filePath: "/opt/anaconda3x")) != .allowed)
    }
}
