import Foundation
import ServiceManagement

/// Zeitplan des automatischen Checks (UserDefaults `checkSchedule`).
enum CheckSchedule: String, CaseIterable, Sendable {
    case off, weekly, monthly
}

/// Anmeldestatus eines LaunchAgents (gespiegelt von `SMAppService.Status`).
enum AgentStatus: Sendable, Equatable {
    case enabled, requiresApproval, notRegistered, notFound
}

/// An- und Abmelden der LaunchAgent-plists aus `Contents/Library/LaunchAgents` – in Tests eine Attrappe.
protocol AgentService: Sendable {
    func register(_ plist: String) throws
    func unregister(_ plist: String) async throws
    func status(_ plist: String) -> AgentStatus
}

/// Produktion: `SMAppService.agent(plistName:)`. Braucht eine signierte App; unsignierte Debug-Builds
/// melden oft `.notFound`/`.requiresApproval`.
struct SMAppAgentService: AgentService {
    func register(_ plist: String) throws {
        try SMAppService.agent(plistName: plist).register()
    }

    func unregister(_ plist: String) async throws {
        try await SMAppService.agent(plistName: plist).unregister()
    }

    func status(_ plist: String) -> AgentStatus {
        switch SMAppService.agent(plistName: plist).status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}

/// Meldet genau die plist des gewählten Zeitplans an und die jeweils andere ab (Spec §4).
struct CheckScheduler: Sendable {
    static let weeklyPlist = "de.frankjuchim.klarschiff2.check.weekly.plist"
    static let monthlyPlist = "de.frankjuchim.klarschiff2.check.monthly.plist"

    private let service: any AgentService

    init(service: any AgentService) {
        self.service = service
    }

    static func plist(for schedule: CheckSchedule) -> String? {
        switch schedule {
        case .off: nil
        case .weekly: weeklyPlist
        case .monthly: monthlyPlist
        }
    }

    /// Andere plist abmelden (nur wenn angemeldet – sonst wirft `SMAppService`), gewählte anmelden; `.off` → beide ab.
    func apply(_ schedule: CheckSchedule) async throws {
        let chosen = Self.plist(for: schedule)
        for plist in [Self.weeklyPlist, Self.monthlyPlist] where plist != chosen {
            switch service.status(plist) {
            case .enabled, .requiresApproval: try await service.unregister(plist)
            case .notRegistered, .notFound: break
            }
        }
        if let chosen { try service.register(chosen) }
    }

    /// Status der plist des Zeitplans; `.off` gilt als „nicht angemeldet“.
    func status(for schedule: CheckSchedule) -> AgentStatus {
        guard let plist = Self.plist(for: schedule) else { return .notRegistered }
        return service.status(plist)
    }
}
