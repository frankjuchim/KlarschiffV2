import Foundation

public struct ToolRemover: Remover {
    private let runner: CommandRunner
    private let tools: ToolLocator

    public init(runner: CommandRunner, tools: ToolLocator) {
        self.runner = runner
        self.tools = tools
    }

    public func remove(_ finding: Finding, items: [FindingItem], dryRun: Bool) async -> [ItemResult] {
        let outcomeFor: (FindingItem?) -> ItemOutcome
        let outcome = await execute(finding, dryRun: dryRun)
        switch outcome {
        case .removed: outcomeFor = { item in .removed(freed: item?.size) }
        default: outcomeFor = { _ in outcome }
        }
        if items.isEmpty { return [ItemResult(findingID: finding.id, itemID: nil, outcome: outcomeFor(nil))] }
        return items.map { ItemResult(findingID: finding.id, itemID: $0.id, outcome: outcomeFor($0)) }
    }

    private func execute(_ finding: Finding, dryRun: Bool) async -> ItemOutcome {
        guard case .tool(let commands, _) = finding.method else { return .failed("Falsche Methode") }
        if dryRun { return .skipped(RemovalText.dryRun) }
        for command in commands {
            let exe: String?
            switch command.tool {
            case "xcrun": exe = "/usr/bin/xcrun"
            default: exe = tools.path(for: command.tool)
            }
            guard let exe else { return .failed("Werkzeug nicht gefunden: \(command.tool)") }
            let env = tools.environment(for: exe, base: command.tool == "brew" ? ToolLocator.brewEnvironment : [:])
            do {
                let r = try await runner.run(exe, command.arguments, timeout: command.timeout, environment: env)
                if r.exitCode != 0 {
                    if command.tool == "brew", let tap = HomebrewErrors.untrustedTap(in: r.stderr) {
                        let name = command.arguments.last { !$0.hasPrefix("-") } ?? ""
                        return .failed("Homebrew vertraut diesem Tap nicht. Führe nacheinander aus: brew trust \(tap) · brew uninstall --cask \(name) · brew untap \(tap)")
                    }
                    let msg = RemovalText.shorten(r.stderr)
                    return .failed(msg.isEmpty ? "Exit \(r.exitCode)" : msg)
                }
            } catch CommandError.timeout {
                return .failed("Zeitüberschreitung")
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return .removed(freed: nil)
    }
}
