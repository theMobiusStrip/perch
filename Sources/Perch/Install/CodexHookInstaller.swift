import Foundation
import PerchCore

/// Idempotent installer for Perch's hooks in ~/.codex/hooks.json (PLAN §3.1).
/// Claude-compatible registration shape; matcher is the regex ".*". Same
/// merge/backup/atomic-write discipline as the Claude installer. Codex also
/// gates command hooks behind a trust record — CodexHookTrust writes it after
/// install (callers chain ensureTrusted() into the report).
enum CodexHookInstaller {
    static var hooksPath: URL {
        PerchPaths.codexHomeDir.appendingPathComponent("hooks.json")
    }

    private static let asyncEvents: [HookEventName] = [
        .sessionStart, .userPromptSubmit, .postToolUse, .stop,
        .subagentStart, .subagentStop, .preCompact, .postCompact, .interrupt,
    ]
    private static let syncEvents: [HookEventName] = [.permissionRequest, .preToolUse, .sessionEnd]
    static var allEvents: [HookEventName] { asyncEvents + syncEvents }

    // MARK: - Install

    static func install(hooksPath: URL = CodexHookInstaller.hooksPath,
                        bridgePath: String = PerchPaths.bridgeInstallPath.path) throws -> InstallReport {
        // Create if missing; if the file exists but can't parse → throw.
        let file = try InstallSupport.readObjectFile(at: hooksPath)
        var root = file.object
        var notes: [String] = []

        try InstallSupport.mergePerchHooks(
            into: &root,
            filePath: hooksPath.path,
            command: InstallSupport.hookCommand(bridgePath: bridgePath, agent: .codex),
            matcher: ".*",
            asyncEvents: asyncEvents,
            syncEvents: syncEvents)

        // Codex caps terminal hooks at three seconds, unlike tool hooks.
        if var hooks = root["hooks"]?.objectValue {
            for event in [HookEventName.sessionEnd, .interrupt] {
                let entry = InstallSupport.hookEntry(
                    command: InstallSupport.hookCommand(bridgePath: bridgePath, agent: .codex),
                    timeout: 3, isAsync: event == .interrupt)
                hooks[event.rawValue] = .array(InstallSupport.replacingPerchEntries(
                    in: hooks[event.rawValue]?.arrayValue ?? [],
                    with: InstallSupport.matcherGroup(matcher: ".*", entry: entry)))
            }
            root["hooks"] = .object(hooks)
        }

        let changed = JSONValue.object(root) != JSONValue.object(file.object)
        var backupPath: String?
        if changed {
            backupPath = try InstallSupport.writeObjectFile(root, to: hooksPath, originalRaw: file.raw)
            notes.insert("Registered Perch hooks for \(allEvents.count) Codex events " +
                         "(all observe-only) in \(hooksPath.path).", at: 0)
        } else {
            notes.insert("Perch hooks already present in \(hooksPath.path).", at: 0)
        }
        notes.append(versionSupportNote())
        return InstallReport(changed: changed, backupPath: backupPath, notes: notes)
    }

    // MARK: - Uninstall

    static func uninstall(hooksPath: URL = CodexHookInstaller.hooksPath) throws -> InstallReport {
        guard FileManager.default.fileExists(atPath: hooksPath.path) else {
            return InstallReport(changed: false, backupPath: nil,
                                 notes: ["\(hooksPath.path) does not exist — nothing to remove."])
        }
        let file = try InstallSupport.readObjectFile(at: hooksPath)
        var root = file.object
        var notes: [String] = []

        let touched = InstallSupport.removePerchHooks(from: &root)
        if touched > 0 {
            notes.append("Removed Perch hook entries from \(touched) event(s).")
        }

        let changed = JSONValue.object(root) != JSONValue.object(file.object)
        var backupPath: String?
        if changed {
            backupPath = try InstallSupport.writeObjectFile(root, to: hooksPath, originalRaw: file.raw)
        } else {
            notes.append("No Perch entries found in \(hooksPath.path) — nothing to remove.")
        }
        return InstallReport(changed: changed, backupPath: backupPath, notes: notes)
    }

    // MARK: - Status

    static func installationStatus(
        hooksPath: URL = CodexHookInstaller.hooksPath
    ) -> HookInstallationStatus {
        guard FileManager.default.fileExists(atPath: hooksPath.path) else {
            return HookInstallationStatus(state: .missing, wiredEvents: 0,
                                          totalEvents: allEvents.count,
                                          summary: "Hooks not installed")
        }
        guard let file = try? InstallSupport.readObjectFile(at: hooksPath) else {
            return HookInstallationStatus(state: .unreadable, wiredEvents: 0,
                                          totalEvents: allEvents.count,
                                          summary: "hooks.json cannot be read safely")
        }
        let wired = InstallSupport.wiredEventCount(root: file.object, events: allEvents)
        return HookInstallationStatus(
            state: wired == allEvents.count ? .ready : .partial,
            wiredEvents: wired,
            totalEvents: allEvents.count,
            summary: "\(wired)/\(allEvents.count) hooks installed")
    }

    static func status(hooksPath: URL = CodexHookInstaller.hooksPath) -> String {
        let status = installationStatus(hooksPath: hooksPath)
        switch status.state {
        case .missing:
            return "Codex: hooks not installed (no hooks.json at \(hooksPath.path))"
        case .unreadable:
            return "Codex: hooks.json exists but cannot be parsed (\(hooksPath.path))"
        case .partial, .ready:
            return "Codex: \(status.summary) — \(hooksPath.path)"
        }
    }

    // MARK: - Version detection

    /// `codex --version` → "0.142.4" (first dotted-number token), nil when the
    /// CLI can't be found or doesn't answer within 3s.
    static func detectVersion() -> String? {
        guard let output = runCodexVersionCommand() else { return nil }
        guard let range = output.range(of: #"[0-9]+(?:\.[0-9]+)+"#,
                                       options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// One-line support verdict for the detected Codex version. Shared by
    /// install notes and the Doctor report.
    static func versionSupportNote() -> String {
        guard let version = detectVersion() else {
            return "Codex runtime: not found on PATH or in supported app locations — hooks will sit dormant until Codex is installed."
        }
        if isVersion(version, atLeast: [0, 124]) {
            return "Codex runtime: \(version) — hook support available; event coverage is checked per runtime."
        }
        if isVersion(version, atLeast: [0, 114]) {
            return "Codex runtime: \(version) — hooks need `hooks = true` under `[features]` in config.toml (0.114–0.123)."
        }
        return "Codex runtime: \(version) — hooks UNSUPPORTED below 0.114; upgrade Codex (only the notify fallback would work)."
    }

    /// Version probe uses the first discovered runtime. Trust and coverage
    /// inspect every discovered runtime using its explicit context.
    static func configureCodexProcess(_ process: Process, arguments: [String]) {
        if let runtime = CodexRuntime.discover().first {
            runtime.configure(process, arguments: arguments)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex"] + arguments
            var env = ProcessInfo.processInfo.environment
            env["CODEX_HOME"] = PerchPaths.codexHomeDir.path
            process.environment = env
        }
    }

    private static func runCodexVersionCommand() -> String? {
        let process = Process()
        configureCodexProcess(process, arguments: ["--version"])
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // swallow
        do {
            try process.run()
        } catch {
            PerchLog.warn("codex --version failed to launch: \(error)", category: "install")
            return nil
        }
        // --version output is tiny (fits the pipe buffer), so it's safe to
        // wait for exit before draining. 3s watchdog against a hung CLI.
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            PerchLog.warn("codex --version timed out", category: "install")
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Dotted-version comparison; missing components count as 0.
    static func isVersion(_ version: String, atLeast minimum: [Int]) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(parts.count, minimum.count) {
            let a = i < parts.count ? parts[i] : 0
            let b = i < minimum.count ? minimum[i] : 0
            if a != b { return a > b }
        }
        return true
    }
}
