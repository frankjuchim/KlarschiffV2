import Testing
import Foundation
@testable import KlarschiffCore

private let launchctl = "/bin/launchctl"

private func svc(
    _ label: String, _ scope: LaunchScope, orphaned: Bool = true, own: Bool = false, running: Bool = false,
    plist: String? = nil
) -> LaunchItem {
    let path: String? = plist ?? {
        switch scope {
        case .user: "/Users/test/Library/LaunchAgents/\(label).plist"
        case .allUsers: "/Library/LaunchAgents/\(label).plist"
        case .system: "/Library/LaunchDaemons/\(label).plist"
        case .loginItem: nil
        }
    }()
    return LaunchItem(
        id: "\(scope.rawValue)/\(label)", label: label, scope: scope, plistURL: path.map { URL(filePath: $0) },
        isRunning: running, isOrphaned: orphaned, isOwnAgent: own, displayName: label, explanation: "Erklärung")
}

private let home = URL(filePath: "/Users/test")

private func ok() -> CommandResult { CommandResult(exitCode: 0, stdout: "", stderr: "") }

@Suite struct ServiceRemovalTests {
    @Test func onlyOrphanedNonAppleNonOwnNonLoginItems() {
        let items = [
            svc("com.example.user", .user),
            svc("com.example.fine", .user, orphaned: false),
            svc("de.frankjuchim.klarschiff2.check", .user, own: true),
            svc("com.apple.foo", .user),
            svc("COM.APPLE.x", .system),
            svc("Com.Apple.y", .allUsers),
            svc("com.example.login", .loginItem, plist: "/Users/test/Library/LaunchAgents/com.example.login.plist"),
        ]
        let findings = ServiceRemoval.finding(items, home: home, uid: 501)
        #expect(findings.count == 1)
        #expect(findings.first?.items.map(\.id) == ["user/com.example.user"])
    }

    @Test(arguments: ["com.example evil", "com.example;rm", "com.exämple", "com.example\u{301}", ".hidden",
                      "-dash", "", "com.example/../x", "gui/501/x", "com.example\n", String(repeating: "a", count: 202),
                      "com.ｅxample"])
    func invalidLabelsExcluded(_ label: String) {
        for scope in [LaunchScope.user, .allUsers, .system] {
            let item = svc(label, scope, plist: scope == .user ? "/Users/test/Library/LaunchAgents/x.plist"
                           : scope == .system ? "/Library/LaunchDaemons/x.plist" : "/Library/LaunchAgents/x.plist")
            #expect(ServiceRemoval.finding([item], home: home, uid: 501).isEmpty, "\(label) \(scope)")
        }
    }

    @Test func maxLengthLabelAllowed() {
        let label = String(repeating: "a", count: 201)
        #expect(ServiceRemoval.finding([svc(label, .system, plist: "/Library/LaunchDaemons/x.plist")], home: home, uid: 501).count == 1)
    }

    @Test(arguments: [
        (LaunchScope.system, "/Library/LaunchAgents/x.plist"),
        (LaunchScope.system, "/Library/LaunchDaemons/sub/x.plist"),
        (LaunchScope.system, "/Library/LaunchDaemons/x.txt"),
        (LaunchScope.system, "/Library/LaunchDaemons"),
        (LaunchScope.allUsers, "/Library/LaunchDaemons/x.plist"),
        (LaunchScope.allUsers, "/Library/LaunchAgents/../LaunchDaemons/x.plist"),
        (LaunchScope.user, "/Library/LaunchAgents/x.plist"),
        (LaunchScope.user, "/Users/test/Documents/x.plist"),
        (LaunchScope.user, "/Users/other/Library/LaunchAgents/x.plist"),
        (LaunchScope.user, "/Users/test/sub/Library/LaunchAgents/x.plist"),
        (LaunchScope.user, "/Users/test/Library/LaunchAgents/sub/x.plist"),
        (LaunchScope.user, "/Users/test/Library/LaunchAgents/../LaunchAgents/x.plist"),
    ])
    func plistOutsideExpectedFolderExcluded(_ c: (LaunchScope, String)) {
        #expect(ServiceRemoval.finding([svc("com.example.x", c.0, plist: c.1)], home: home, uid: 501).isEmpty, "\(c)")
    }

    @Test func missingPlistExcluded() {
        var item = svc("com.example.x", .system)
        item.plistURL = nil
        #expect(ServiceRemoval.finding([item], home: home, uid: 501).isEmpty)
    }

    @Test func userItemsTrashAndAdminStepsForOthers() throws {
        let items = [
            svc("com.example.user", .user),
            svc("com.example.agent", .allUsers),
            svc("com.example.daemon", .system),
        ]
        let findings = ServiceRemoval.finding(items, home: home, uid: 501)
        #expect(findings.count == 2)
        let trash = try #require(findings.first { $0.method == .trash })
        #expect(trash.items.map(\.url?.path) == ["/Users/test/Library/LaunchAgents/com.example.user.plist"])
        #expect(trash.category == .services && trash.risk == .review && trash.id.scannerID == "services.orphaned")
        #expect(trash.tab == .services)
        #expect(!trash.isPreselected(isKept: false))
        #expect(trash.summary.contains("gelöscht") && trash.summary.contains("gestoppt"))

        let admin = try #require(findings.first { if case .admin = $0.method { true } else { false } })
        #expect(admin.category == .services && admin.risk == .review && admin.id.scannerID == "services.orphaned")
        #expect(admin.items.map(\.id) == ["allUsers/com.example.agent", "system/com.example.daemon"])
        #expect(admin.summary.contains("gelöscht") && admin.summary.contains("gestoppt"))
        guard case .admin(let steps) = admin.method else { return }
        #expect(steps == [
            AdminStep(executable: "/bin/rm", arguments: ["-f", "/Library/LaunchAgents/com.example.agent.plist"],
                      itemID: "allUsers/com.example.agent"),
            AdminStep(executable: launchctl, arguments: ["bootout", "system/com.example.daemon"],
                      itemID: "system/com.example.daemon"),
            AdminStep(executable: "/bin/rm", arguments: ["-f", "/Library/LaunchDaemons/com.example.daemon.plist"],
                      itemID: "system/com.example.daemon", runsIfPreviousSucceeded: true),
        ])
    }

    @Test func adminStepsPassTheAllowList() async {
        let g = SafetyGuard(home: URL(filePath: "/Users/test"), userCacheDir: URL(filePath: "/private/var/folders/ab/xyz/C"),
                            allowedCacheSubdirs: [])
        let items = [svc("com.example.agent", .allUsers), svc("com.example.daemon", .system)]
        let admin = ServiceRemoval.finding(items, home: home, uid: 501)[0]
        let ex = FakeExecutor(fixed: .completed([0, 0, 0]))
        let r = await AdminRemover(executor: ex, guard: g).remove([(admin, admin.items)], dryRun: false)
        #expect(ex.runs.count == 1 && ex.runs[0].count == 3)
        #expect(r.map(\.outcome) == [.removed(freed: nil), .removed(freed: nil)])
    }

    @Test(arguments: ["com.openssh.sshd", "COM.VIX.CRON", "com.vix.cron", "org.cups.cupsd", "ORG.Apache.HTTPD",
                      "org.net-snmp.snmpd", "org.openldap.slapd", "org.ntp.ntpd", "Org.Ntp.sntp"])
    func appleDaemonsWithoutApplePrefixExcluded(_ label: String) {
        for scope in [LaunchScope.user, .allUsers, .system] {
            #expect(ServiceRemoval.finding([svc(label, scope)], home: home, uid: 501).isEmpty, "\(label) \(scope)")
        }
    }

    @Test func userHomeDefaultsToNSHomeDirectory() {
        let real = svc("com.example.x", .user, plist: NSHomeDirectory() + "/Library/LaunchAgents/com.example.x.plist")
        #expect(ServiceRemoval.finding([real]).count == 1)
        #expect(ServiceRemoval.finding([svc("com.example.x", .user)]).isEmpty || NSHomeDirectory() == "/Users/test")
    }

    @Test func partialSelectionPreviewShowsOnlySelectedDaemon() {
        let items = [svc("com.example.agent", .allUsers), svc("com.example.daemon", .system)]
        let admin = ServiceRemoval.finding(items, home: home, uid: 501)[0]
        let plan = RemovalPlan(findings: [admin], selection: [admin.id: ["system/com.example.daemon"]], options: RemovalOptions())
        #expect(plan.commandPreview == [
            "sudo /bin/launchctl bootout system/com.example.daemon",
            "sudo /bin/rm -f /Library/LaunchDaemons/com.example.daemon.plist  # nur wenn der Dienst gestoppt wurde",
        ])
        let onlyA = RemovalPlan(findings: [admin], selection: [admin.id: ["allUsers/com.example.agent"]], options: RemovalOptions())
        #expect(onlyA.commandPreview == ["sudo /bin/rm -f /Library/LaunchAgents/com.example.agent.plist"])
    }

    // MARK: bootout

    @Test func bootoutAlwaysForRemovableUserAndAllUsersAgents() async {
        let runner = FakeCommandRunner()
        runner.stub(launchctl, ["bootout", "gui/501/com.example.user"], result: ok())
        runner.stub(launchctl, ["bootout", "gui/501/com.example.agent"], result: ok())
        runner.stub(launchctl, ["bootout", "gui/501/com.example.idle"], result: ok())
        let items = [
            svc("com.example.user", .user, running: true),
            svc("com.example.agent", .allUsers, running: true),
            svc("com.example.idle", .user, running: false),
            svc("com.example.daemon", .system, running: true),
            svc("com.example.fine", .user, orphaned: false, running: true),
            svc("com.apple.x", .user, running: true),
            svc("de.frankjuchim.klarschiff2.check", .user, own: true, running: true),
            svc("com.example.login", .loginItem, running: true, plist: "/Users/test/Library/LaunchAgents/l.plist"),
            svc("bad label", .user, running: true, plist: "/Users/test/Library/LaunchAgents/b.plist"),
        ]
        let r = await ServiceRemoval.bootout(items, runner: runner, home: home, uid: 501, dryRun: false)
        // Auch nicht laufende (aber evtl. geladene) Agents werden gestoppt.
        #expect(runner.calls.map(\.0) == [launchctl, launchctl, launchctl])
        #expect(runner.calls.map(\.1) == [["bootout", "gui/501/com.example.user"], ["bootout", "gui/501/com.example.agent"],
                                          ["bootout", "gui/501/com.example.idle"]])
        #expect(r.map(\.itemID) == ["user/com.example.user", "allUsers/com.example.agent", "user/com.example.idle"])
        #expect(r.map(\.outcome) == [.removed(freed: nil), .removed(freed: nil), .removed(freed: nil)])
        let ids = ServiceRemoval.finding(items, home: home, uid: 501).map(\.id)
        #expect(r.allSatisfy { ids.contains($0.findingID) })
    }

    @Test func bootoutNotFoundCountsAsDoneAndErrorsReported() async {
        let runner = FakeCommandRunner()
        runner.stub(launchctl, ["bootout", "gui/501/com.example.a"],
                    result: CommandResult(exitCode: 113, stdout: "", stderr: "Boot-out failed: 113: Could not find service"))
        runner.stub(launchctl, ["bootout", "gui/501/com.example.b"],
                    result: CommandResult(exitCode: 3, stdout: "", stderr: "Boot-out failed: 3: No such process"))
        runner.stub(launchctl, ["bootout", "gui/501/com.example.c"],
                    result: CommandResult(exitCode: 5, stdout: "", stderr: "Input/output error"))
        let items = ["a", "b", "c"].map { svc("com.example.\($0)", .user, running: true) }
        let r = await ServiceRemoval.bootout(items, runner: runner, home: home, uid: 501, dryRun: false)
        #expect(r[0].outcome == .removed(freed: nil))
        #expect(r[1].outcome == .removed(freed: nil))
        if case .failed(let m) = r[2].outcome { #expect(m.contains("Input/output error")) } else { Issue.record("erwartet failed") }
    }

    @Test func bootoutDryRunNoCalls() async {
        let runner = FakeCommandRunner()
        let r = await ServiceRemoval.bootout([svc("com.example.a", .user, running: true)], runner: runner, home: home, uid: 501, dryRun: true)
        #expect(runner.calls.isEmpty)
        #expect(r.map(\.outcome) == [.skipped("Trockenlauf")])
    }

    // MARK: Abschlussreview

    @Test func previewStopsEveryRemovableAgentAndMarksConditionalRm() throws {
        let items = [
            svc("com.example.user", .user, running: false),
            svc("com.example.agent", .allUsers, running: false),
            svc("com.example.daemon", .system),
        ]
        let findings = ServiceRemoval.finding(items, home: home, uid: 501)
        let trash = try #require(findings.first { $0.method == .trash })
        #expect(trash.commandPreview == ["/bin/launchctl bootout gui/501/com.example.user"])
        let admin = try #require(findings.first { if case .admin = $0.method { true } else { false } })
        // Alle-Benutzer-Agents werden erst nach dem Admin-Schritt gestoppt.
        #expect(admin.commandPreview == [
            "/bin/rm -f /Library/LaunchAgents/com.example.agent.plist",
            "/bin/launchctl bootout system/com.example.daemon",
            "/bin/rm -f /Library/LaunchDaemons/com.example.daemon.plist  # nur wenn der Dienst gestoppt wurde",
            "/bin/launchctl bootout gui/501/com.example.agent",
        ])
        #expect(ServiceRemoval.commandPreview(items, home: home, uid: 501) == [
            "/bin/launchctl bootout gui/501/com.example.user",
            "In den Papierkorb: /Users/test/Library/LaunchAgents/com.example.user.plist",
            "sudo /bin/rm -f /Library/LaunchAgents/com.example.agent.plist",
            "sudo /bin/launchctl bootout system/com.example.daemon",
            "sudo /bin/rm -f /Library/LaunchDaemons/com.example.daemon.plist  # nur wenn der Dienst gestoppt wurde",
            "/bin/launchctl bootout gui/501/com.example.agent",
        ])
        #expect(ServiceRemoval.commandPreview([svc("com.example.fine", .user, orphaned: false)], home: home, uid: 501).isEmpty)
    }

    @Test func sharedLabelWithIntactServiceBlocksRemovalAndBootout() async {
        // Benutzer und Alle Benutzer teilen gui/<uid>: ein intakter Dienst gleichen Namens schützt den verwaisten.
        let items = [
            svc("com.example.shared", .user),
            svc("com.example.shared", .allUsers, orphaned: false),
            svc("com.example.sys", .system),
            svc("com.example.sys", .system, orphaned: false, plist: "/Library/LaunchDaemons/other.plist"),
            svc("com.example.cross", .user),
            svc("com.example.cross", .system, orphaned: false),
            svc("com.example.free", .allUsers),
        ]
        let marked = ServiceRemoval.markSharedLabels(items, home: home)
        #expect(marked.map(\.sharesLabelWithKeptService) == [true, false, true, false, false, false, false])
        #expect(marked.filter { ServiceRemoval.isRemovable($0, home: home) }.map(\.id)
            == ["user/com.example.cross", "allUsers/com.example.free"])
        #expect(ServiceRemoval.notRemovableReason(marked[0], home: home) == ServiceRemoval.sharedLabelReason)
        #expect(ServiceRemoval.sharedLabelReason
            == "Ein gleichnamiger, intakter Dienst läuft – bitte über die zugehörige App entfernen.")

        // finding und bootout erkennen den Konflikt auch ohne vorheriges Markieren.
        let ids = ServiceRemoval.finding(items, home: home, uid: 501).flatMap(\.items).map(\.id)
        #expect(ids == ["user/com.example.cross", "allUsers/com.example.free"])
        let runner = FakeCommandRunner()
        runner.stub(launchctl, ["bootout", "gui/501/com.example.cross"], result: ok())
        runner.stub(launchctl, ["bootout", "gui/501/com.example.free"], result: ok())
        _ = await ServiceRemoval.bootout(items, runner: runner, home: home, uid: 501, dryRun: false)
        #expect(runner.calls.map(\.1) == [["bootout", "gui/501/com.example.cross"], ["bootout", "gui/501/com.example.free"]])
        // Bereits markiert: auch als Teilmenge gesperrt.
        #expect(ServiceRemoval.finding([marked[0]], home: home, uid: 501).isEmpty)
    }

    @Test func notRemovableReasons() {
        #expect(ServiceRemoval.notRemovableReason(svc("com.example.ok", .user), home: home) == nil)
        #expect(ServiceRemoval.notRemovableReason(svc("com.apple.x", .system), home: home) == "Gehört zu macOS.")
        #expect(ServiceRemoval.notRemovableReason(svc("org.cups.cupsd", .system), home: home) == "Gehört zu macOS.")
        #expect(ServiceRemoval.notRemovableReason(
            svc("com.example.login", .loginItem, plist: "/Users/test/Library/LaunchAgents/l.plist"), home: home)
            == "Anmeldeobjekte schaltest du in den Systemeinstellungen aus.")
        #expect(ServiceRemoval.notRemovableReason(svc("bad label", .user, plist: "/Users/test/Library/LaunchAgents/b.plist"),
                                                  home: home)?.isEmpty == false)
        #expect(ServiceRemoval.notRemovableReason(svc("com.example.x", .user, plist: "/Users/test/Documents/x.plist"),
                                                  home: home) == "Die Startdatei liegt nicht am erwarteten Ort.")
    }
}
