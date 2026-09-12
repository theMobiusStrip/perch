import Foundation
import Darwin
import PerchCore

/// Trusts Perch's installed Codex hooks without the /hooks TUI by speaking the
/// same app-server JSON-RPC the TUI does: `hooks/list` returns each hook's
/// server-computed identity hash, `config/batchWrite` records it under
/// `hooks.state` in ~/.codex/config.toml. Codex only executes command hooks
/// whose recorded hash matches, so this step is what actually turns the
/// installed hooks on. The hash binds the hook's normalized identity
/// (event + matcher + command + timeout + async), so any future change to the
/// registered entries flips the status back to "modified" and needs a re-run.
///
/// Failure here is never fatal: hooks.json is already written, and the
/// fallback note tells the user to confirm once in Codex's /hooks screen.
enum CodexHookTrust {

    // MARK: - Request shapes (pure; covered by selftest)

    static func initializeRequest(id: Int) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("initialize"),
            "params": .object([
                "clientInfo": .object([
                    "name": .string("perch"),
                    "title": .string("Perch"),
                    "version": .string(AppVersion.string),
                ]),
            ]),
        ])
    }

    static func initializedNotification() -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string("initialized")])
    }

    static func hooksListRequest(id: Int, cwd: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("hooks/list"),
            "params": .object(["cwds": .array([.string(cwd)])]),
        ])
    }

    /// hooks.state upsert exactly as the /hooks TUI sends it: the value maps
    /// each hook's positional key to its server-computed current hash.
    static func batchWriteRequest(id: Int, updates: [HookEntry]) -> JSONValue {
        var value: [String: JSONValue] = [:]
        for entry in updates {
            value[entry.key] = .object(["trusted_hash": .string(entry.currentHash)])
        }
        return .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("config/batchWrite"),
            "params": .object([
                "edits": .array([.object([
                    "keyPath": .string("hooks.state"),
                    "value": .object(value),
                    "mergeStrategy": .string("upsert"),
                ])]),
                "filePath": .null,
                "expectedVersion": .null,
                "reloadUserConfig": .bool(true),
            ]),
        ])
    }

    // MARK: - Response parsing (pure; covered by selftest)

    struct HookEntry: Equatable {
        var key: String
        var currentHash: String
        var trustStatus: String
        var enabled: Bool = true

        var canRun: Bool { enabled && (trustStatus == "trusted" || trustStatus == "managed") }
    }

    struct ListSummary: Equatable {
        var perchHooks: [HookEntry]
        /// Count of "skipping async hook … not supported yet" warnings —
        /// Codex ≤0.142 runs only synchronous hooks, so most of Perch's
        /// registered events sit dormant until Codex ships async support.
        var asyncSkipped: Int
        var hasErrors: Bool = false
    }

    static func summarize(hooksListResult result: JSONValue,
                          expectedCommand: String? = nil, sourcePath: String? = nil) -> ListSummary {
        var hooks: [HookEntry] = []
        var asyncSkipped = 0
        var hasErrors = false
        for entry in result["data"]?.arrayValue ?? [] {
            if !(entry["errors"]?.arrayValue ?? []).isEmpty { hasErrors = true }
            for hook in entry["hooks"]?.arrayValue ?? [] {
                guard hook["command"]?.string?.contains(InstallSupport.marker) == true,
                      let key = hook["key"]?.string,
                      let hash = hook.first(of: ["currentHash", "current_hash"])?.string,
                      !hash.isEmpty else { continue }
                if let expectedCommand, hook["command"]?.string != expectedCommand { continue }
                if let sourcePath, !key.hasPrefix(sourcePath + ":") { continue }
                if expectedCommand != nil,
                   !CodexHookInstaller.allEvents.contains(where: {
                       normalizeEvent($0.rawValue) == normalizeEvent(eventName(fromKey: key))
                   }) { continue }
                if expectedCommand != nil {
                    guard hook.first(of: ["handlerType", "handler_type"])?.string == "command" else { continue }
                    let matcher = hook["matcher"]?.string
                    if let matcher, matcher != ".*" && matcher != "*" { continue }
                    if ["pretooluse", "permissionrequest", "posttooluse"].contains(normalizeEvent(eventName(fromKey: key))),
                       matcher == nil { continue }
                }
                let status = hook.first(of: ["trustStatus", "trust_status"])?.string ?? ""
                hooks.append(HookEntry(key: key, currentHash: hash, trustStatus: status.lowercased(),
                                       enabled: hook["enabled"]?.boolValue ?? (expectedCommand == nil)))
            }
            for warning in entry["warnings"]?.arrayValue ?? [] {
                if warning.string?.contains("async hook") == true { asyncSkipped += 1 }
            }
        }
        return ListSummary(perchHooks: hooks, asyncSkipped: asyncSkipped, hasErrors: hasErrors)
    }

    /// Human-readable event name from a positional hook key like
    /// "/Users/…/hooks.json:pre_tool_use:0:0".
    static func eventName(fromKey key: String) -> String {
        let parts = key.split(separator: ":")
        guard parts.count >= 3 else { return key }
        return String(parts[parts.count - 3])
    }

    /// Count of `[hooks.state."…hooks.json:…"]` sections in config.toml that
    /// carry a trusted_hash. Cheap textual scan for the Doctor report — the
    /// authoritative check (hash comparison) lives in the app-server and runs
    /// during install.
    static func trustRecordCount(configToml: String) -> Int {
        var count = 0
        var inMatchingSection = false
        var sectionCounted = false
        for rawLine in configToml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inMatchingSection = line.hasPrefix("[hooks.state.\"") && line.contains("hooks.json:")
                sectionCounted = false
                continue
            }
            if inMatchingSection, !sectionCounted, line.hasPrefix("trusted_hash") {
                count += 1
                sectionCounted = true
            }
        }
        return count
    }

    static func storedTrustRecordCount(
        codexHome: URL = PerchPaths.codexHomeDir
    ) -> Int? {
        let configPath = codexHome.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: configPath, encoding: .utf8) else { return nil }
        return trustRecordCount(configToml: text)
    }

    /// Stored records are diagnostic data, never proof that a hook can run.
    static func doctorLine(codexHome: URL = PerchPaths.codexHomeDir) -> String {
        let configPath = codexHome.appendingPathComponent("config.toml")
        guard let count = storedTrustRecordCount(codexHome: codexHome) else {
            return "Codex hook trust: no readable user config.toml; runtime inspection determines coverage."
        }
        if count > 0 {
            return "Codex hook trust: \(count) stored record(s) in \(configPath.path). "
                + "Current runtime coverage is reported above; stored records alone do not verify hooks."
        }
        return "Codex hook trust: no stored user trust records in \(configPath.path). "
            + "Managed hooks may still run; use runtime coverage above."
    }

    // MARK: - Driver

    private static let fallbackNote = "Run /hooks once in the Codex CLI (terminal — the desktop app "
        + "has no /hooks command) and trust the Perch hook instead; Codex never fires untrusted command hooks."

    /// Authoritative read-only inspection. Call from a background queue.
    /// The complete multi-runtime probe has one deadline, not one per hook.
    static func inspect(codexHome: URL = PerchPaths.codexHomeDir) -> MonitoringCheck {
        let runtimes = CodexRuntime.discover(codexHome: codexHome)
        guard !runtimes.isEmpty else {
            return MonitoringCheck(title: "Codex", state: .unavailable,
                                   summary: "Codex runtime not found", detail: nil)
        }
        let deadline = Date().addingTimeInterval(8)
        var coverages: [Coverage] = []
        var failures: [String] = []
        for runtime in runtimes {
            let transport = AppServerTransport(runtime: runtime)
            defer { transport.shutdown() }
            do {
                try transport.start()
                try initialize(transport, deadline: deadline)
                coverages.append(try coverage(transport, runtime: runtime, id: 1, deadline: deadline))
            } catch {
                failures.append("\(runtime.label): \(error.localizedDescription)")
            }
        }
        return check(coverages: coverages, failures: failures)
    }

    /// Only installation/explicit repair may write trust. Inspect every
    /// runtime first so incompatible hashes cannot overwrite each other.
    static func ensureTrusted() -> [String] {
        let deadline = Date().addingTimeInterval(12)
        let runtimes = CodexRuntime.discover()
        guard !runtimes.isEmpty else { return ["Codex runtime not found. \(fallbackNote)"] }
        var sessions: [(AppServerTransport, Coverage)] = []
        defer { sessions.forEach { $0.0.shutdown() } }
        var notes: [String] = []
        for runtime in runtimes {
            let transport = AppServerTransport(runtime: runtime)
            do {
                try transport.start()
                try initialize(transport, deadline: deadline)
                sessions.append((transport, try coverage(transport, runtime: runtime, id: 1, deadline: deadline)))
            } catch {
                transport.shutdown()
                notes.append("\(runtime.label): \(error.localizedDescription)")
            }
        }
        guard notes.isEmpty else {
            return notes + ["Could not inspect every detected runtime; trust unchanged. \(fallbackNote)"]
        }
        guard !conflictingHashes(sessions.map(\.1)) else {
            return ["Codex runtimes disagree on hook identities. Align their versions before repairing trust."]
        }
        for (transport, before) in sessions {
            guard before.hooksEnabled, !before.hooks.hasErrors, !before.hooks.perchHooks.isEmpty else {
                notes.append(before.summary)
                continue
            }
            // Disabled and managed entries belong to user/admin policy.
            let updates = before.hooks.perchHooks.filter {
                $0.enabled && ($0.trustStatus == "untrusted" || $0.trustStatus == "modified")
            }
            do {
                if !updates.isEmpty {
                    transport.send(batchWriteRequest(id: 3, updates: updates))
                    _ = try response(transport, id: 3, deadline: deadline)
                }
                let after = try coverage(transport, runtime: before.runtime, id: 4, deadline: deadline)
                if after.hooksEnabled && verified(expected: before.hooks.perchHooks, actual: after.hooks) {
                    notes.append(after.summary)
                } else {
                    notes.append("\(before.runtime.label): repair verification incomplete. \(after.summary)")
                }
            } catch {
                notes.append("\(before.runtime.label): repair verification failed (\(error.localizedDescription)). \(fallbackNote)")
            }
        }
        return notes
    }

    private enum ProbeError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): return message }
        }
    }

    private static func response(_ transport: AppServerTransport, id: Int, deadline: Date) throws -> JSONValue {
        guard let reply = transport.waitResponse(id: id, deadline: deadline) else {
            throw ProbeError.failed("runtime probe timed out or exited")
        }
        guard let result = reply["result"], reply["error"] == nil else {
            throw ProbeError.failed(reply["error"]?["message"]?.string ?? "invalid runtime response")
        }
        return result
    }

    private static func initialize(_ transport: AppServerTransport, deadline: Date) throws {
        transport.send(initializeRequest(id: 0))
        _ = try response(transport, id: 0, deadline: deadline)
        transport.send(initializedNotification())
    }

    private static func coverage(_ transport: AppServerTransport, runtime: CodexRuntime,
                                 id: Int, deadline: Date) throws -> Coverage {
        transport.send(hooksListRequest(id: id, cwd: FileManager.default.homeDirectoryForCurrentUser.path))
        let result = try response(transport, id: id, deadline: deadline)
        guard result["data"]?.arrayValue != nil else { throw ProbeError.failed("invalid hooks/list response") }
        transport.send(.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id + 1)), "method": .string("config/read"),
            "params": .object(["includeLayers": .bool(false)]),
        ]))
        let config = try response(transport, id: id + 1, deadline: deadline)
        guard config["config"]?.objectValue != nil else { throw ProbeError.failed("invalid config/read response") }
        let features = config["config"]?["features"]
        let enabled = features?["hooks"]?.boolValue ?? features?["codex_hooks"]?.boolValue ?? true
        let summary = summarize(hooksListResult: result,
                                expectedCommand: InstallSupport.hookCommand(
                                    bridgePath: PerchPaths.bridgeInstallPath.path, agent: .codex),
                                sourcePath: runtime.codexHome.appendingPathComponent("hooks.json").path)
        return Coverage(runtime: runtime, hooks: summary, hooksEnabled: enabled)
    }
}

/// Line-delimited JSON-RPC over a `codex app-server` child process. Stdout is
/// drained on a readability handler; callers poll for a response by id with a
/// deadline so a hung server can never wedge the install past its budget.
private final class AppServerTransport {
    private let runtime: CodexRuntime
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var messages: [JSONValue] = []
    /// Most recent response consumed by waitResponse — kept for error notes.
    private(set) var lastResponse: JSONValue?

    init(runtime: CodexRuntime) { self.runtime = runtime }

    func start() throws {
        runtime.configure(process, arguments: ["app-server"])
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.ingest(handle.availableData)
        }
        try process.run()
    }

    func send(_ message: JSONValue) {
        var data = message.encodedData()
        data.append(0x0A)
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// Poll for the response with the given id. 50ms granularity; returns nil
    /// once the deadline passes or the server exits without answering.
    func waitResponse(id: Int, deadline: Date) -> JSONValue? {
        while Date() < deadline {
            lock.lock()
            let found = messages.first { message in
                message["id"]?.int == id && (message["result"] != nil || message["error"] != nil)
            }
            lock.unlock()
            if let found {
                lastResponse = found
                return found
            }
            if !process.isRunning { return nil }
            usleep(50_000)
        }
        return nil
    }

    func shutdown() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let message = try? JSONValue(parsing: line) else { continue }
            messages.append(message)
        }
    }
}
