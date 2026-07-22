import Foundation
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
    }

    struct ListSummary: Equatable {
        var perchHooks: [HookEntry]
        /// Count of "skipping async hook … not supported yet" warnings —
        /// Codex ≤0.142 runs only synchronous hooks, so most of Perch's
        /// registered events sit dormant until Codex ships async support.
        var asyncSkipped: Int
    }

    static func summarize(hooksListResult result: JSONValue) -> ListSummary {
        var hooks: [HookEntry] = []
        var asyncSkipped = 0
        for entry in result["data"]?.arrayValue ?? [] {
            for hook in entry["hooks"]?.arrayValue ?? [] {
                guard hook["command"]?.string?.contains(InstallSupport.marker) == true,
                      let key = hook["key"]?.string,
                      let hash = hook.first(of: ["currentHash", "current_hash"])?.string else { continue }
                let status = hook.first(of: ["trustStatus", "trust_status"])?.string ?? ""
                hooks.append(HookEntry(key: key, currentHash: hash, trustStatus: status.lowercased()))
            }
            for warning in entry["warnings"]?.arrayValue ?? [] {
                if warning.string?.contains("async hook") == true { asyncSkipped += 1 }
            }
        }
        return ListSummary(perchHooks: hooks, asyncSkipped: asyncSkipped)
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

    /// One-line Doctor summary based on the config.toml scan.
    static func doctorLine(codexHome: URL = PerchPaths.codexHomeDir) -> String {
        let configPath = codexHome.appendingPathComponent("config.toml")
        guard let count = storedTrustRecordCount(codexHome: codexHome) else {
            return "Codex hook trust: no config.toml — install Codex hooks to set it up."
        }
        if count > 0 {
            return "Codex hook trust: \(count) trust record(s) in \(configPath.path) — hooks run without the /hooks prompt. "
                + "Changing the registered hooks invalidates the hash; repair Codex in Monitoring Setup afterwards."
        }
        return "Codex hook trust: NO trust record in \(configPath.path) — Codex will not run Perch's hooks. "
            + "Repair Codex in Monitoring Setup (auto-trusts) or run /hooks once in the Codex CLI."
    }

    // MARK: - Driver

    private static let fallbackNote = "Run /hooks once in the Codex CLI (terminal — the desktop app "
        + "has no /hooks command) and trust the Perch hook instead; Codex never fires untrusted command hooks."

    /// Trust every untrusted Perch hook Codex can currently see. Returns
    /// install-note lines; never throws (the install itself already
    /// succeeded). Blocks the calling thread for up to ~12s worst case;
    /// installs are rare one-shot actions.
    static func ensureTrusted() -> [String] {
        let deadline = Date().addingTimeInterval(12)
        let transport = AppServerTransport()
        do {
            try transport.start()
        } catch {
            return ["Codex hook trust: could not launch `codex app-server` (\(error.localizedDescription)). \(fallbackNote)"]
        }
        defer { transport.shutdown() }

        func fail(_ stage: String, _ response: JSONValue?) -> [String] {
            let detail = response?["error"]?["message"]?.string
                ?? (response == nil ? "timed out" : "unexpected reply")
            PerchLog.warn("codex hook trust: \(stage) failed — \(detail)", category: "install")
            return ["Codex hook trust: \(stage) failed (\(detail)). \(fallbackNote)"]
        }

        transport.send(initializeRequest(id: 0))
        guard let initResponse = transport.waitResponse(id: 0, deadline: deadline),
              initResponse["error"] == nil else {
            return fail("initialize", transport.lastResponse)
        }
        transport.send(initializedNotification())

        transport.send(hooksListRequest(id: 1, cwd: FileManager.default.homeDirectoryForCurrentUser.path))
        guard let listResponse = transport.waitResponse(id: 1, deadline: deadline),
              let listResult = listResponse["result"] else {
            return fail("hooks/list", transport.lastResponse)
        }
        let summary = summarize(hooksListResult: listResult)

        var notes: [String] = []
        if summary.asyncSkipped > 0 {
            notes.append("This Codex runs only synchronous hooks (PreToolUse, PermissionRequest) — "
                + "\(summary.asyncSkipped) async Perch registrations stay dormant until Codex supports async hooks.")
        }
        guard !summary.perchHooks.isEmpty else {
            notes.append("Codex hook trust: Codex reported no Perch hooks — "
                + "it may predate hook support (needs ≥0.114). \(fallbackNote)")
            return notes
        }

        let untrusted = summary.perchHooks.filter { $0.trustStatus != "trusted" }
        let events = summary.perchHooks.map { eventName(fromKey: $0.key) }.joined(separator: ", ")
        if untrusted.isEmpty {
            notes.append("Codex already trusts Perch's hooks (\(events)).")
            return notes
        }

        transport.send(batchWriteRequest(id: 2, updates: untrusted))
        guard let writeResponse = transport.waitResponse(id: 2, deadline: deadline),
              writeResponse["error"] == nil else {
            notes += fail("config/batchWrite", transport.lastResponse)
            return notes
        }

        // Re-list so the success note reflects what Codex says, not what we hope.
        transport.send(hooksListRequest(id: 3, cwd: FileManager.default.homeDirectoryForCurrentUser.path))
        let verified = transport.waitResponse(id: 3, deadline: deadline)
            .flatMap { $0["result"] }
            .map { summarize(hooksListResult: $0).perchHooks.allSatisfy { $0.trustStatus == "trusted" } }
        if verified == true {
            PerchLog.info("codex hook trust: trusted \(untrusted.count) hook(s)", category: "install")
            notes.append("Trusted Perch's Codex hooks (\(events)) — recorded under hooks.state in "
                + "~/.codex/config.toml, same effect as confirming in the CLI's /hooks screen.")
        } else {
            notes.append("Codex hook trust: wrote trust records but verification "
                + (verified == nil ? "timed out" : "still shows untrusted hooks") + ". \(fallbackNote)")
        }
        return notes
    }
}

/// Line-delimited JSON-RPC over a `codex app-server` child process. Stdout is
/// drained on a readability handler; callers poll for a response by id with a
/// deadline so a hung server can never wedge the install past its budget.
private final class AppServerTransport {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var messages: [JSONValue] = []
    /// Most recent response consumed by waitResponse — kept for error notes.
    private(set) var lastResponse: JSONValue?

    func start() throws {
        CodexHookInstaller.configureCodexProcess(process, arguments: ["app-server"])
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe() // deprecation warnings etc. — irrelevant here
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
