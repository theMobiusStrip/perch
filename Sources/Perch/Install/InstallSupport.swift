import Foundation
import PerchCore

/// Result of an installer / uninstaller run. Rendered in the menu-bar alert
/// and printed by the headless CLI commands (`Perch --install-claude-hooks` …).
struct InstallReport {
    var changed: Bool
    var backupPath: String?
    var notes: [String]

    /// Multi-line human summary.
    var summaryText: String {
        var lines: [String] = [changed ? "Changes applied." : "No changes needed."]
        if let backupPath {
            lines.append("Backup: \(backupPath)")
        }
        lines.append(contentsOf: notes.map { "• \($0)" })
        return lines.joined(separator: "\n")
    }
}

/// Errors thrown by the installers. Config-write safety is sacred (PLAN §0):
/// when an existing file cannot be read, parsed, or merged we THROW — we never
/// clobber anything we don't fully understand.
enum InstallError: LocalizedError {
    case unreadable(path: String, detail: String)
    case unparseable(path: String, detail: String)
    case notAnObject(path: String)
    case unmergeable(path: String, detail: String)
    case writeFailed(path: String, detail: String)
    case bridgeSourceNotFound(searched: [String])

    var errorDescription: String? {
        switch self {
        case .unreadable(let path, let detail):
            return "Cannot read \(path): \(detail)"
        case .unparseable(let path, let detail):
            return "Refusing to touch \(path) — the existing file does not parse as JSON (\(detail)). Fix or move it aside, then retry."
        case .notAnObject(let path):
            return "Refusing to touch \(path) — the top-level JSON value is not an object."
        case .unmergeable(let path, let detail):
            return "Refusing to modify \(path) — \(detail); a safe merge is impossible."
        case .writeFailed(let path, let detail):
            return "Failed writing \(path): \(detail)"
        case .bridgeSourceNotFound(let searched):
            return "perch-bridge binary not found. Searched: \(searched.joined(separator: ", "))"
        }
    }
}

/// Shared plumbing for both installers: tolerant read, marker-based merge,
/// timestamped backup, atomic replace.
enum InstallSupport {
    /// Our entries are identified by this substring in the command string.
    static let marker = "perch-bridge"

    struct ObjectFile {
        var object: [String: JSONValue]
        /// Raw bytes of the pre-existing file; nil when the file doesn't exist
        /// yet. Used verbatim for the backup sibling.
        var raw: Data?
    }

    /// Missing file → empty object (we'll create it). Whitespace-only file →
    /// empty object (nothing to lose; still backed up). Anything else that
    /// fails to parse as a JSON object → THROW.
    static func readObjectFile(at url: URL) throws -> ObjectFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ObjectFile(object: [:], raw: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw InstallError.unreadable(path: url.path, detail: error.localizedDescription)
        }
        if String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ObjectFile(object: [:], raw: data)
        }
        let json: JSONValue
        do {
            json = try JSONValue(parsing: data)
        } catch {
            throw InstallError.unparseable(path: url.path, detail: String(describing: error))
        }
        guard let obj = json.objectValue else {
            throw InstallError.notAnObject(path: url.path)
        }
        return ObjectFile(object: obj, raw: data)
    }

    // MARK: - Hook entry construction

    /// Exact hook command string. The bridge path contains a space
    /// ("Application Support"), so it is always quoted.
    static func hookCommand(bridgePath: String, agent: AgentKind) -> String {
        "\"\(bridgePath)\" --hook \(agent.rawValue)"
    }

    static func statuslineCommand(bridgePath: String) -> String {
        "\"\(bridgePath)\" --statusline"
    }

    static func hookEntry(command: String, timeout: Int, isAsync: Bool) -> JSONValue {
        var obj: [String: JSONValue] = [
            "type": .string("command"),
            "command": .string(command),
            "timeout": .number(Double(timeout)),
        ]
        if isAsync {
            obj["async"] = .bool(true)
        }
        return .object(obj)
    }

    static func matcherGroup(matcher: String, entry: JSONValue) -> JSONValue {
        .object(["matcher": .string(matcher), "hooks": .array([entry])])
    }

    /// True when a hook entry (or a statusLine object — same shape check) is
    /// ours: its "command" contains the perch-bridge marker.
    static func isPerchEntry(_ entry: JSONValue) -> Bool {
        entry["command"]?.string?.contains(marker) == true
    }

    static func containsPerchEntry(_ groups: [JSONValue]) -> Bool {
        groups.contains { group in
            group["hooks"]?.arrayValue?.contains(where: isPerchEntry) == true
        }
    }

    /// Strip every Perch-marked hook entry from the matcher groups. Groups
    /// emptied by the removal are dropped; everything else (user hooks,
    /// unknown keys inside groups, non-object oddities) is preserved verbatim.
    static func removingPerchEntries(from groups: [JSONValue]) -> [JSONValue] {
        groups.compactMap { group in
            guard var obj = group.objectValue,
                  let hooks = obj["hooks"]?.arrayValue else { return group }
            let kept = hooks.filter { !isPerchEntry($0) }
            if kept.count == hooks.count { return group }
            if kept.isEmpty { return nil }
            obj["hooks"] = .array(kept)
            return .object(obj)
        }
    }

    /// De-duplicating upsert: remove any pre-existing Perch entries, then
    /// append exactly one desired group. Re-running with an unchanged desired
    /// group reproduces the same array (idempotence).
    static func replacingPerchEntries(in groups: [JSONValue], with desiredGroup: JSONValue) -> [JSONValue] {
        removingPerchEntries(from: groups) + [desiredGroup]
    }

    // MARK: - Whole-file merge helpers

    /// Upsert our hook entries for the given events into `root["hooks"]`,
    /// preserving all unknown keys and every user hook entry. Throws when the
    /// existing structure can't be merged safely.
    static func mergePerchHooks(into root: inout [String: JSONValue],
                                filePath: String,
                                command: String,
                                matcher: String,
                                asyncEvents: [HookEventName],
                                syncEvents: [HookEventName]) throws {
        var hooks: [String: JSONValue]
        switch root["hooks"] {
        case nil, .some(.null):
            hooks = [:]
        case .some(.object(let o)):
            hooks = o
        default:
            throw InstallError.unmergeable(path: filePath, detail: "\"hooks\" is not a JSON object")
        }

        for event in asyncEvents + syncEvents {
            let sync = syncEvents.contains(event)
            let entry = hookEntry(command: command, timeout: sync ? 300 : 10, isAsync: !sync)
            let group = matcherGroup(matcher: matcher, entry: entry)
            let existing: [JSONValue]
            switch hooks[event.rawValue] {
            case nil, .some(.null):
                existing = []
            case .some(.array(let a)):
                existing = a
            default:
                throw InstallError.unmergeable(path: filePath,
                                               detail: "hooks.\(event.rawValue) is not a JSON array")
            }
            hooks[event.rawValue] = .array(replacingPerchEntries(in: existing, with: group))
        }
        root["hooks"] = .object(hooks)
    }

    /// Remove Perch entries from every event under `root["hooks"]`. Empty
    /// arrays/objects left behind by our removal are pruned. Returns the
    /// number of events touched.
    static func removePerchHooks(from root: inout [String: JSONValue]) -> Int {
        guard case .some(.object(var hooks)) = root["hooks"] else { return 0 }
        var touched = 0
        for (event, value) in hooks {
            guard let groups = value.arrayValue, containsPerchEntry(groups) else { continue }
            let cleaned = removingPerchEntries(from: groups)
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = .array(cleaned)
            }
            touched += 1
        }
        if touched > 0 {
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = .object(hooks)
            }
        }
        return touched
    }

    /// Count of the given events that currently carry a Perch entry.
    static func wiredEventCount(root: [String: JSONValue], events: [HookEventName]) -> Int {
        guard let hooks = root["hooks"]?.objectValue else { return 0 }
        return events.filter { event in
            guard let groups = hooks[event.rawValue]?.arrayValue else { return false }
            return containsPerchEntry(groups)
        }.count
    }

    // MARK: - Backup + atomic write

    static func backupTimestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Timestamped backup sibling (exact original bytes), then atomic replace
    /// (temp file + rename(2) in the same directory). Preserves the original
    /// file's permissions; new files get 0600. Returns the backup path, or
    /// nil when the target didn't exist yet.
    @discardableResult
    static func writeObjectFile(_ object: [String: JSONValue], to url: URL,
                                originalRaw: Data?) throws -> String? {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw InstallError.writeFailed(path: dir.path,
                                           detail: "cannot create directory: \(error.localizedDescription)")
        }

        var backupPath: String?
        if let originalRaw {
            let base = url.path + ".perch-backup-" + backupTimestamp()
            var candidate = base
            var n = 1
            while fm.fileExists(atPath: candidate) {
                n += 1
                candidate = "\(base)-\(n)"
            }
            guard fm.createFile(atPath: candidate, contents: originalRaw,
                                attributes: [.posixPermissions: 0o600]) else {
                throw InstallError.writeFailed(path: candidate, detail: "could not create backup file")
            }
            backupPath = candidate
        }

        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
            ?? NSNumber(value: 0o600)

        var data = JSONValue.object(object).encodedData(pretty: true)
        data.append(0x0A)

        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).perch-tmp-\(UUID().uuidString)")
        // Create the temp file 0600 from the start so its contents (which may
        // include preserved secrets like env/API-key blocks) are never briefly
        // readable at default-umask permissions; widen to the preserved mode
        // only after the write completes.
        guard fm.createFile(atPath: tmp.path, contents: data,
                            attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw InstallError.writeFailed(path: url.path, detail: "could not create temp file")
        }
        do {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmp.path)
        } catch {
            try? fm.removeItem(at: tmp)
            throw InstallError.writeFailed(path: url.path, detail: error.localizedDescription)
        }
        guard rename(tmp.path, url.path) == 0 else {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            throw InstallError.writeFailed(path: url.path, detail: "atomic rename failed: \(err)")
        }
        PerchLog.info("Wrote \(url.path)\(backupPath.map { " (backup: \($0))" } ?? "")", category: "install")
        return backupPath
    }
}

/// Keeps the bundled bridge binary at its stable, hook-command-visible path
/// (~/Library/Application Support/Perch/perch-bridge) so hook registrations
/// survive app moves and rebuilds.
enum BridgeDeployer {
    /// Copy the bundled bridge (Bundle.main Resources; dev fallback: sibling
    /// of the running executable, then .build/{release,debug}/perch-bridge)
    /// to PerchPaths.bridgeInstallPath. Overwrite if size/mtime differ.
    /// chmod 0755. Returns destination.
    @discardableResult
    static func deploy() throws -> URL {
        let fm = FileManager.default
        let dest = PerchPaths.bridgeInstallPath

        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "perch-bridge", withExtension: nil) {
            candidates.append(bundled)
        }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("perch-bridge"))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent(".build/release/perch-bridge"))
        candidates.append(cwd.appendingPathComponent(".build/debug/perch-bridge"))

        var searched: [String] = []
        var source: URL?
        for candidate in candidates {
            searched.append(candidate.path)
            if fm.fileExists(atPath: candidate.path) {
                source = candidate
                break
            }
        }
        guard let source else {
            throw InstallError.bridgeSourceNotFound(searched: searched)
        }
        if source.standardizedFileURL.path == dest.standardizedFileURL.path {
            return dest
        }

        try PerchPaths.ensureAppSupportDir()
        if needsCopy(from: source, to: dest, fm: fm) {
            // Copy to a temp name in the same directory, then rename(2) over
            // dest, so a hook or statusline invocation racing the update never
            // sees a missing/partial binary, and a failed copy leaves the
            // previously deployed bridge intact.
            let tmp = dest.deletingLastPathComponent()
                .appendingPathComponent(".\(dest.lastPathComponent).perch-tmp-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: source, to: tmp)
                try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: tmp.path)
                guard rename(tmp.path, dest.path) == 0 else {
                    let err = String(cString: strerror(errno))
                    throw InstallError.writeFailed(path: dest.path, detail: "atomic rename failed: \(err)")
                }
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
            PerchLog.info("Deployed perch-bridge \(source.path) -> \(dest.path)", category: "install")
        }
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dest.path)
        return dest
    }

    private static func needsCopy(from source: URL, to dest: URL, fm: FileManager) -> Bool {
        guard let s = try? fm.attributesOfItem(atPath: source.path),
              let d = try? fm.attributesOfItem(atPath: dest.path) else { return true }
        let sizeEqual = (s[.size] as? NSNumber)?.uint64Value == (d[.size] as? NSNumber)?.uint64Value
        guard let sm = s[.modificationDate] as? Date,
              let dm = d[.modificationDate] as? Date else { return true }
        // copyItem preserves mtime, so equal-within-a-second means same build.
        let mtimeEqual = abs(sm.timeIntervalSince(dm)) < 1.0
        return !(sizeEqual && mtimeEqual)
    }
}
