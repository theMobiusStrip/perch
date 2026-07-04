import Foundation
import PerchCore

/// Tails ~/.claude/projects/<slug>/*.jsonl (honoring $CLAUDE_CONFIG_DIR via
/// PerchPaths) and feeds catch-up data into the SessionStore: token usage,
/// model, titles, last prompt, last assistant snippet, lastActivity.
///
/// Polls the directory tree every 2s (contract-sanctioned fallback; new lines
/// land well under 2s). Hooks own session STATE — the tailer never flips state
/// except unknown → idle.
@MainActor
final class ClaudeTranscriptTailer {
    private let store: SessionStore
    private let queue = DispatchQueue(label: "dev.evan.perch.claude-tail", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let worker = ClaudeTranscriptWorker()

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        let store = self.store
        let worker = self.worker
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(400),
                       repeating: .seconds(2),
                       leeway: .milliseconds(250))
        timer.setEventHandler {
            // Runs on `queue`; worker is confined to it.
            let updates = worker.poll()
            guard !updates.isEmpty else { return }
            Task { @MainActor in
                for update in updates {
                    Self.apply(update, to: store)
                }
            }
        }
        timer.resume()
        self.timer = timer
        PerchLog.info("Claude transcript tailer watching \(worker.projectsDir.path)", category: "claude-tail")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        timer?.cancel()
    }

    // MARK: - Store application (main actor)

    private static func apply(_ update: TranscriptUpdate, to store: SessionStore) {
        let isNew = store.find(agent: .claude, id: update.sessionId) == nil
        store.upsert(agent: .claude, id: update.sessionId) { s in
            s.transcriptPath = update.transcriptPath
            if let cwd = update.cwd { s.cwd = cwd }
            if let branch = update.gitBranch { s.gitBranch = branch }
            if let version = update.version { s.version = version }
            if let model = update.model { s.model = model }
            if let title = update.title, !title.isEmpty { s.title = title }
            if let prompt = update.lastPrompt, !prompt.isEmpty {
                s.lastPrompt = String(prompt.prefix(200))
            }
            if let snippet = update.snippet { s.lastAssistantSnippet = snippet }
            s.inputTokens += update.inputTokens
            s.outputTokens += update.outputTokens
            s.cacheReadTokens += update.cacheReadTokens
            s.cacheCreationTokens += update.cacheCreationTokens
            if let ts = update.latestTimestamp {
                // Fresh session objects default lastActivity to "now" — the
                // transcript line timestamp is the truth for a session first
                // discovered here, and during the launch catch-up scan, where
                // liveness may have created the session moments earlier with
                // lastActivity defaulted to launch time (backdate it). Never
                // clobber real hook activity: catch-up backdating applies only
                // while the session is still idle/unknown. Otherwise only bump
                // forward.
                let authoritative = isNew ||
                    (update.isCatchUp && (s.state == .idle || s.state == .unknown))
                if authoritative || ts > s.lastActivity { s.lastActivity = ts }
            }
            // Transcripts are catch-up only; hooks own state.
            if s.state == .unknown { s.state = .idle }
        }
    }
}

// MARK: - Per-session update accumulated from parsed lines

private struct TranscriptUpdate: Sendable {
    let sessionId: String
    var transcriptPath: String
    var cwd: String?
    var gitBranch: String?
    var version: String?
    var model: String?
    var title: String?
    var lastPrompt: String?
    var snippet: String?
    var latestTimestamp: Date?
    /// True when this update comes from the launch catch-up scan (the first
    /// poll), where the transcript timestamp is authoritative for lastActivity.
    var isCatchUp = false
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
}

// MARK: - Background worker (confined to the tailer's queue)

private final class ClaudeTranscriptWorker {
    let projectsDir = PerchPaths.claudeConfigDir.appendingPathComponent("projects", isDirectory: true)

    private struct StatKey: Equatable {
        var size: UInt64
        var mtime: Date
    }

    private let tailer = FileTailer()
    private var knownFiles: Set<String> = []
    private var lastStat: [String: StatKey] = [:]
    /// sessionId → seen `message.id|requestId` keys (ccusage dedupe rule).
    private var seenUsageKeys: [String: Set<String>] = [:]
    /// transcript path → session ids whose usage-dedupe sets it feeds
    /// (so `seenUsageKeys` can be pruned when the transcript is deleted).
    private var usageSessionIds: [String: Set<String>] = [:]
    private var parseFailures: [String: Int] = [:]
    private var warnedMissingDir = false
    private var isFirstScan = true

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func poll() -> [TranscriptUpdate] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            if !warnedMissingDir {
                warnedMissingDir = true
                PerchLog.info("Claude projects dir not readable at \(projectsDir.path)", category: "claude-tail")
            }
            return []
        }
        warnedMissingDir = false
        let firstScan = isFirstScan
        isFirstScan = false

        var merged: [String: TranscriptUpdate] = [:]
        var seenPaths: Set<String> = []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                seenPaths.insert(file.path)
                processFile(file, into: &merged)
            }
        }
        pruneDeadFiles(keeping: seenPaths)
        if firstScan {
            // Launch catch-up: every update in the first scan comes from a
            // file's initial parse — the transcript timestamp is authoritative
            // for lastActivity (see apply()).
            for key in merged.keys { merged[key]?.isCatchUp = true }
        }
        return Array(merged.values)
    }

    /// Drop per-file and per-session tracking for transcripts that no longer
    /// exist on disk (Claude Code's cleanupPeriodDays purges old *.jsonl), so
    /// a long-lived Perch does not grow without bound.
    private func pruneDeadFiles(keeping seenPaths: Set<String>) {
        let dead = knownFiles.subtracting(seenPaths)
        guard !dead.isEmpty else { return }
        let fm = FileManager.default
        for path in dead {
            // Re-check on disk: a transient enumeration failure of a single
            // project dir must not drop live tail offsets/dedupe state.
            guard !fm.fileExists(atPath: path) else { continue }
            knownFiles.remove(path)
            lastStat.removeValue(forKey: path)
            parseFailures.removeValue(forKey: path)
            tailer.forget(path: path)
            if let ids = usageSessionIds.removeValue(forKey: path) {
                // Keep a session's dedupe set while any surviving file still
                // feeds it (resumed sessions copy lines across files).
                for id in ids where !usageSessionIds.contains(where: { $0.value.contains(id) }) {
                    seenUsageKeys.removeValue(forKey: id)
                }
            }
        }
    }

    private func processFile(_ url: URL, into merged: inout [String: TranscriptUpdate]) {
        let path = url.path
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = UInt64(max(0, values?.fileSize ?? 0))
        let mtime = values?.contentModificationDate ?? .distantPast
        let stat = StatKey(size: size, mtime: mtime)

        var initialLineCap: Int?
        if !knownFiles.contains(path) {
            knownFiles.insert(path)
            if mtime < Date(timeIntervalSinceNow: -24 * 3600) {
                // Old history: seed at end without opening — ingest only future appends.
                tailer.seed(path: path, offset: size)
                lastStat[path] = stat
                return
            }
            // Fresh file: parse from 0 but only ingest the tail for initial state.
            initialLineCap = 200
        } else if lastStat[path] == stat {
            return // unchanged — skip the open entirely
        }
        lastStat[path] = stat

        var lines = tailer.readNewLines(path: path)
        if let cap = initialLineCap, lines.count > cap {
            lines.removeFirst(lines.count - cap)
        }
        guard !lines.isEmpty else { return }

        // Transcript files are named <sessionId>.jsonl — fallback for
        // metadata lines that omit session_id.
        let fallbackSessionId = url.deletingPathExtension().lastPathComponent
        for line in lines {
            parse(line: line, path: path, fallbackSessionId: fallbackSessionId, into: &merged)
        }
    }

    // MARK: - Line parsing

    private func parse(line: String, path: String, fallbackSessionId: String,
                       into merged: inout [String: TranscriptUpdate]) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let json = JSONValue(parsingLine: trimmed), json.objectValue != nil else {
            noteParseFailure(path)
            return
        }
        // Sidechain (subagent) lines are excluded from state/tokens/snippets.
        if json["isSidechain"]?.boolValue == true { return }
        guard let type = json["type"]?.string else { return }

        let sessionId = json["sessionId"]?.string ?? fallbackSessionId
        guard !sessionId.isEmpty else { return }

        switch type {
        case "assistant":
            var update = merged[sessionId] ?? TranscriptUpdate(sessionId: sessionId, transcriptPath: path)
            applyEnvelope(json, to: &update)
            applyAssistant(json, sessionId: sessionId, path: path, to: &update)
            merged[sessionId] = update

        case "user":
            var update = merged[sessionId] ?? TranscriptUpdate(sessionId: sessionId, transcriptPath: path)
            applyEnvelope(json, to: &update)
            merged[sessionId] = update

        case "ai-title", "custom-title":
            // Observed fields: aiTitle / customTitle (docs suggested title/content — probe all).
            if let title = json.first(of: ["aiTitle", "customTitle", "title", "content"])?.string {
                var update = merged[sessionId] ?? TranscriptUpdate(sessionId: sessionId, transcriptPath: path)
                update.title = title
                merged[sessionId] = update
            }

        case "last-prompt":
            if let prompt = json.first(of: ["lastPrompt", "prompt", "content"])?.string {
                var update = merged[sessionId] ?? TranscriptUpdate(sessionId: sessionId, transcriptPath: path)
                update.lastPrompt = prompt
                merged[sessionId] = update
            }

        default:
            break // summary / queue-operation / attachment / system / progress …
        }
    }

    /// Shared envelope fields present on user/assistant lines.
    private func applyEnvelope(_ json: JSONValue, to update: inout TranscriptUpdate) {
        if let cwd = json["cwd"]?.string, !cwd.isEmpty { update.cwd = cwd }
        if let branch = json["gitBranch"]?.string, !branch.isEmpty { update.gitBranch = branch }
        if let version = json["version"]?.string, !version.isEmpty { update.version = version }
        if let raw = json["timestamp"]?.string, let date = Self.parseTimestamp(raw) {
            if update.latestTimestamp.map({ date > $0 }) ?? true {
                update.latestTimestamp = date
            }
        }
    }

    private func applyAssistant(_ json: JSONValue, sessionId: String, path: String,
                                to update: inout TranscriptUpdate) {
        let message = json["message"]
        if let model = message?["model"]?.string, !model.isEmpty { update.model = model }

        // Token accumulation, deduped by message.id + requestId (ccusage rule).
        let messageId = message?["id"]?.string
        let requestId = json["requestId"]?.string
        let dedupeKey: String?
        if messageId == nil && requestId == nil {
            dedupeKey = json["uuid"]?.string
        } else {
            dedupeKey = "\(messageId ?? "")|\(requestId ?? "")"
        }
        var shouldCount = true
        if let key = dedupeKey {
            usageSessionIds[path, default: []].insert(sessionId)
            var seen = seenUsageKeys[sessionId, default: []]
            if seen.contains(key) {
                shouldCount = false
            } else {
                seen.insert(key)
                if seen.count > 20_000 { seen.removeAll() } // unbounded-growth valve
                seenUsageKeys[sessionId] = seen
            }
        }
        if shouldCount, let usage = message?["usage"] {
            update.inputTokens += usage["input_tokens"]?.int ?? 0
            update.outputTokens += usage["output_tokens"]?.int ?? 0
            update.cacheReadTokens += usage["cache_read_input_tokens"]?.int ?? 0
            update.cacheCreationTokens += usage["cache_creation_input_tokens"]?.int ?? 0
        }

        // Concatenated text blocks → snippet (first 300 chars).
        if let blocks = message?["content"]?.arrayValue {
            let text = blocks
                .compactMap { block -> String? in
                    guard block["type"]?.string == "text" else { return nil }
                    return block["text"]?.string
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                update.snippet = String(text.prefix(300))
            }
        }
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }

    private func noteParseFailure(_ path: String) {
        let count = (parseFailures[path] ?? 0) + 1
        parseFailures[path] = count
        if count == 1 || count % 200 == 0 {
            PerchLog.warn("Malformed transcript line (#\(count)) in \((path as NSString).lastPathComponent)",
                          category: "claude-tail")
        }
    }
}
