import Foundation

private func runTool(_ ctx: ScanContext, _ path: String, name: String, _ args: [String]) async throws -> String {
    let result = try await ctx.runner.run(path, args, timeout: .seconds(120), environment: [:])
    guard result.succeeded else {
        let excerpt = String(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        throw CommandError.launchFailed("\(name) \(args.joined(separator: " ")): Exit \(result.exitCode) \(excerpt)")
    }
    return result.stdout
}

private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

// MARK: - Conda

/// Conda-/Anaconda-/Miniconda-Installationen: Paket-Cache über `conda clean`, ganze Installation nur als Hinweis.
public struct CondaScanner: Scanner {
    public let id = "toolchains.conda"
    public init() {}

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let installations = [
            ctx.absolute("/opt/anaconda3"), ctx.absolute("/opt/miniconda3"),
            ctx.homePath("anaconda3"), ctx.homePath("miniconda3"),
        ].filter(isDirectory)
        var cacheDirs = installations.map { $0.appending(path: "pkgs") }
        cacheDirs.append(ctx.homePath(".conda/pkgs"))
        cacheDirs = cacheDirs.filter(isDirectory)

        var findings: [Finding] = []
        if !cacheDirs.isEmpty {
            var items: [FindingItem] = []
            for url in cacheDirs {
                try Task.checkCancellation()
                let rel = url.path.hasPrefix(ctx.home.path) ? String(url.path.dropFirst(ctx.home.path.count + 1)) : url.path
                items.append(FindingItem(id: url.path, url: url, name: rel, size: try? await ctx.sizer.size(of: url)))
            }
            let cmd = ToolCommand(tool: "conda", arguments: ["clean", "--all", "-y"], timeout: .seconds(300))
            let hasConda = ctx.tools.path(for: "conda") != nil
            let method: RemovalMethod = hasConda ? .tool([cmd], fallback: nil) : .hint(.revealInFinder(cacheDirs[0]))
            findings.append(Finding(
                id: FindingID(scannerID: id, key: "pkgs"), category: .toolchains,
                title: "Conda – Paket-Cache",
                summary: "Heruntergeladene Pakete und Archive von Conda. „conda clean“ entfernt, was keine Umgebung mehr braucht; Pakete lädt Conda bei Bedarf neu.",
                risk: hasConda ? .review : .hintOnly, method: method, items: items,
                size: items.compactMap(\.size).reduce(0, +), blockingApps: [], keepSuggested: false,
                commandPreview: hasConda ? [cmd.display] : [], needsFullDiskAccess: false))
        }

        for inst in installations {
            try Task.checkCancellation()
            let name = inst.lastPathComponent.lowercased().hasPrefix("miniconda") ? "Miniconda" : "Anaconda"
            let size = try? await ctx.sizer.size(of: inst)
            findings.append(Finding(
                id: FindingID(scannerID: id, key: inst.path), category: .toolchains,
                title: "\(name) – ganze Installation",
                summary: "Die komplette \(name)-Installation samt aller Umgebungen. Entferne sie über die offizielle Deinstallation: erst „anaconda-clean“ ausführen, danach den Ordner löschen. Klarschiff zeigt ihn dir dafür im Finder.",
                risk: .hintOnly, method: .hint(.revealInFinder(inst)),
                items: [FindingItem(id: inst.path, url: inst, name: inst.lastPathComponent, size: size)],
                size: size, blockingApps: [], keepSuggested: false, commandPreview: [], needsFullDiskAccess: false))
        }
        return findings
    }
}

// MARK: - Ollama

/// Lokale KI-Modelle von Ollama: je Modell über `ollama rm`, ohne CLI der ganze Modellordner.
public struct OllamaScanner: Scanner {
    public let id = "ai.ollama"
    public init() {}

    static func parseSize(_ s: String) -> Int64? {
        let parts = s.split(separator: " ").map(String.init)
        guard parts.count == 2, let value = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let factor: Double
        switch parts[1].uppercased() {
        case "B": factor = 1
        case "KB": factor = 1e3
        case "MB": factor = 1e6
        case "GB": factor = 1e9
        case "TB": factor = 1e12
        default: return nil
        }
        return Int64((value * factor).rounded())
    }

    /// Spalten sind durch mindestens zwei Leerzeichen getrennt: NAME, ID, SIZE, MODIFIED.
    static func parseList(_ out: String) -> [(name: String, size: Int64?)] {
        var models: [(String, Int64?)] = []
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("NAME") { continue }
            let cols = line.components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard cols.count >= 3, !cols[0].isEmpty else { continue }
            models.append((cols[0], parseSize(cols[2])))
        }
        return models
    }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        let summary = "Ein lokal gespeichertes KI-Modell von Ollama. Du kannst es jederzeit mit „ollama pull“ erneut laden."
        var cliError: Error?
        if let ollama = ctx.tools.path(for: "ollama") {
            do {
                let out = try await runTool(ctx, ollama, name: "ollama", ["list"])
                return Self.parseList(out).map { model in
                    let cmd = ToolCommand(tool: "ollama", arguments: ["rm", model.name], timeout: .seconds(300))
                    return Finding(
                        id: FindingID(scannerID: id, key: model.name), category: .aiLeftovers,
                        title: "Ollama-Modell: \(model.name)", summary: summary,
                        risk: .review, method: .tool([cmd], fallback: nil),
                        items: [FindingItem(id: model.name, name: model.name, size: model.size)],
                        size: model.size, blockingApps: [], keepSuggested: false,
                        commandPreview: [cmd.display], needsFullDiskAccess: false)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Server läuft nicht o. Ä.: wie ohne CLI den Modellordner anbieten.
                cliError = error
            }
        }
        let dir = ctx.homePath(".ollama/models")
        guard isDirectory(dir) else {
            if let cliError { throw cliError }
            return []
        }
        let size = try? await ctx.sizer.size(of: dir)
        let blocking = ctx.runningApps.running([
            AppRef(bundleID: "com.electron.ollama", processName: nil, displayName: "Ollama"),
            AppRef(bundleID: nil, processName: "ollama", displayName: "ollama"),
        ])
        return [Finding(
            id: FindingID(scannerID: id, key: "models"), category: .aiLeftovers,
            title: "Ollama-Modelle",
            summary: "Alle lokal gespeicherten KI-Modelle von Ollama. Du kannst sie später erneut laden.",
            risk: .review, method: .delete,
            items: [FindingItem(id: dir.path, url: dir, name: "models", size: size)],
            size: size, blockingApps: blocking, keepSuggested: false,
            commandPreview: ["rm -rf " + ShellQuote.quote(dir.path)], needsFullDiskAccess: false)]
    }
}

// MARK: - Rustup

/// Rust-Toolchains über `rustup toolchain uninstall`; die Standard-Toolchain wird zum Behalten vorgeschlagen.
public struct RustupScanner: Scanner {
    public let id = "languages.rustup"
    public init() {}

    static func parse(_ out: String) -> [(name: String, isDefault: Bool)] {
        out.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            guard let open = line.firstIndex(of: "(") else { return (line, false) }
            let name = line[..<open].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return (name, line[open...].contains("default"))
        }
    }

    public func scan(_ ctx: ScanContext) async throws -> [Finding] {
        guard let rustup = ctx.tools.path(for: "rustup") else { return [] }
        let out = try await runTool(ctx, rustup, name: "rustup", ["toolchain", "list"])
        var findings: [Finding] = []
        for tc in Self.parse(out) {
            try Task.checkCancellation()
            guard !tc.name.contains("/"), tc.name != "..", tc.name != "." else { continue }
            let url = ctx.homePath(".rustup/toolchains/\(tc.name)")
            // Kein Symlink (lstat), nur ein echter Ordner.
            guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
            else { continue }
            let size = try? await ctx.sizer.size(of: url)
            let cmd = ToolCommand(tool: "rustup", arguments: ["toolchain", "uninstall", tc.name], timeout: .seconds(300))
            findings.append(Finding(
                id: FindingID(scannerID: id, key: tc.name), category: .languages,
                title: "Rust-Toolchain \(tc.name)",
                summary: tc.isDefault
                    ? "Deine Standard-Toolchain für Rust. Entfernst du sie, braucht rustup eine neue Standardeinstellung."
                    : "Eine installierte Rust-Version. rustup installiert sie bei Bedarf erneut.",
                risk: .review, method: .tool([cmd], fallback: nil),
                items: [FindingItem(id: url.path, url: url, name: tc.name, size: size)],
                size: size, blockingApps: [], keepSuggested: tc.isDefault,
                commandPreview: [cmd.display], needsFullDiskAccess: false))
        }
        return findings
    }
}
