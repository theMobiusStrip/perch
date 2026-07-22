import Foundation
import PerchCore

/// Tails Codex rollout files (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`),
/// deriving session state, token totals, and account rate limits (PLAN §3.2).
///
/// Observed line shapes (verified against live rollouts on this machine,
/// cli_version 0.142.x) take precedence over the contract sketch:
/// - event_msg payload types are `task_started` / `task_complete` (not
///   `turn_started` / `turn_complete`); `turn_aborted` matches. Both alias
///   families are probed for forward/backward tolerance.
/// - `token_count` arrives as an event_msg payload:
///   `{info: {total_token_usage, last_token_usage, model_context_window},
///     rate_limits: {primary, secondary} | null}`. A top-level `token_count`
///   line type is probed too, per the contract.
/// - `session_meta.payload` carries no model field; the model lives in
///   `turn_context.payload.model` — probed as a fallback source.
/// - `thread_name_updated` event carries `thread_name` → session title.
@MainActor
final class CodexRolloutTailer {
    private let store: SessionStore
    private let usage: UsageStore
    private var engine: RolloutTailEngine?

    /// Session id → a turn started with no matching complete/abort yet.
    private var turnInFlight: [String: Bool] = [:]

    /// Thread ids whose session_meta declared `thread_source: "subagent"`
    /// (0.144+ multi-agent writes each subagent as its own rollout file).
    /// They are helper threads, not peer sessions: no store row, but their
    /// token_count lines still carry account-level rate limits.
    private var subagentThreads: Set<String> = []

    init(store: SessionStore, usage: UsageStore) {
        self.store = store
        self.usage = usage
    }

    func start() {
        guard engine == nil else { return }
        let root = PerchPaths.codexHomeDir.appendingPathComponent("sessions", isDirectory: true)
        let engine = RolloutTailEngine(root: root)
        engine.onBatch = { [weak self] batch in
            Task { @MainActor in self?.apply(batch) }
        }
        engine.onSweep = { [weak self] freshness, vanished in
            Task { @MainActor in self?.applyLiveness(freshness, vanished: vanished) }
        }
        self.engine = engine
        engine.start()
        PerchLog.info("Codex rollout tailer watching \(root.path)", category: "codex")
    }

    func stop() {
        engine?.stop()
        engine = nil
    }

    // MARK: - Semantic application (main actor)

    /// Selftest seam: feed one parsed rollout line through the semantic layer
    /// exactly as the engine would deliver it.
    func ingestLineForSelftest(_ json: JSONValue, sessionID: String,
                               path: String = "/tmp/rollout.jsonl", isSeed: Bool = false) {
        apply(RolloutLine(sessionID: sessionID, filePath: path, json: json, isSeed: isSeed))
    }

    private func apply(_ batch: RolloutBatch) {
        for line in batch.lines {
            apply(line)
        }
        // Turns replayed from files that were already stale at seed time are
        // not "in flight" — the process is very likely gone; the liveness
        // sweep settles their state.
        for id in batch.staleSeeds {
            turnInFlight[id] = false
        }
        for (id, path) in batch.touched where !subagentThreads.contains(id) {
            store.upsert(agent: .codex, id: id) { s in
                if s.transcriptPath == nil { s.transcriptPath = path }
                if s.state == .unknown { s.state = .idle }
                s.isLive = true
                s.lastActivity = Date()
            }
            store.setCodexLive(id: id, live: true)
        }
    }

    private func apply(_ line: RolloutLine) {
        let json = line.json
        let ts = Self.parseTimestamp(json["timestamp"]?.string)
        let payload = json["payload"] ?? .null

        if subagentThreads.contains(line.sessionID) {
            // Helper thread: keep only the account-level rate-limit signal.
            switch json["type"]?.string {
            case "token_count":
                applyRateLimits(payload, line: line, ts: ts)
            case "event_msg":
                let event = Self.unwrapEventPayload(payload)
                if event["type"]?.string == "token_count" {
                    applyRateLimits(event, line: line, ts: ts)
                }
            default:
                break
            }
            return
        }

        switch json["type"]?.string {
        case "session_meta":
            applySessionMeta(payload, line: line, ts: ts)
        case "turn_context":
            if let model = payload.first(of: ["model", "model_name"])?.string {
                store.upsert(agent: .codex, id: line.sessionID) { s in
                    s.model = model
                    if let ts { s.lastActivity = ts }
                }
            }
        case "event_msg":
            applyEventMessage(payload, line: line, ts: ts)
        case "token_count":
            // Top-level variant (contract probe; not observed on 0.142.x).
            applyTokenCount(payload, line: line, ts: ts)
        default:
            break
        }
    }

    private func applySessionMeta(_ payload: JSONValue, line: RolloutLine, ts: Date?) {
        // Tolerate one level of nesting (older recorders wrapped the meta).
        let meta: JSONValue
        if payload.first(of: ["cwd", "id", "session_id"]) != nil {
            meta = payload
        } else {
            meta = payload["payload"] ?? payload
        }
        if meta["thread_source"]?.string == "subagent" {
            if subagentThreads.insert(line.sessionID).inserted {
                // Credit the parent's badge, but never create a ghost parent
                // row for a thread whose parent already aged out.
                if let parent = meta["parent_thread_id"]?.string,
                   store.find(agent: .codex, id: parent) != nil {
                    store.upsert(agent: .codex, id: parent) { $0.subagentCount += 1 }
                }
                // A touched-map upsert from an earlier batch may have created
                // a row before this meta was seen; drop it.
                store.remove(agent: .codex, id: line.sessionID)
            }
            return
        }
        let startedAt = Self.parseTimestamp(meta["timestamp"]?.string) ?? ts
        store.upsert(agent: .codex, id: line.sessionID) { s in
            s.transcriptPath = line.filePath
            if let cwd = meta["cwd"]?.string { s.cwd = cwd }
            if let version = meta["cli_version"]?.string { s.version = version }
            if let branch = meta["git"]?["branch"]?.string { s.gitBranch = branch }
            // 0.144 subagent metas carry an object `source`; for peer threads
            // it stays a string, with `originator` as the fallback.
            if let source = meta["source"]?.string ?? meta["originator"]?.string {
                s.entrypoint = source
            }
            if let model = meta.first(of: ["model", "model_name"])?.string { s.model = model }
            if s.startedAt == nil { s.startedAt = startedAt }
            if s.state == .unknown { s.state = .idle }
            if let ts { s.lastActivity = ts }
        }
    }

    /// Payload may nest one level deep: probe payload.payload.
    private static func unwrapEventPayload(_ payload: JSONValue) -> JSONValue {
        if payload["type"]?.string == nil,
           let nested = payload["payload"], nested["type"]?.string != nil {
            return nested
        }
        return payload
    }

    private func applyEventMessage(_ payload: JSONValue, line: RolloutLine, ts: Date?) {
        let event = Self.unwrapEventPayload(payload)

        switch event["type"]?.string {
        case "task_started", "turn_started":
            turnInFlight[line.sessionID] = true
            let contextWindow = event["model_context_window"]?.int
            store.upsert(agent: .codex, id: line.sessionID) { s in
                s.state = .executing
                s.attentionNote = nil
                s.isLive = true
                if let contextWindow { s.contextWindowSize = contextWindow }
                if s.transcriptPath == nil { s.transcriptPath = line.filePath }
                if let ts { s.lastActivity = ts }
            }

        case "task_complete", "turn_complete":
            turnInFlight[line.sessionID] = false
            let message = event.first(of: ["last_agent_message"])?.string
            store.upsert(agent: .codex, id: line.sessionID) { s in
                s.state = .idle
                s.attentionNote = nil
                if let message, !message.isEmpty {
                    s.lastAssistantSnippet = String(message.prefix(300))
                }
                if let ts { s.lastActivity = ts }
            }

        case "turn_aborted", "task_aborted":
            turnInFlight[line.sessionID] = false
            store.upsert(agent: .codex, id: line.sessionID) { s in
                s.state = .idle
                s.attentionNote = nil
                if let ts { s.lastActivity = ts }
            }

        case "token_count":
            applyTokenCount(event, line: line, ts: ts)

        case "thread_name_updated":
            if let name = event.first(of: ["thread_name", "name"])?.string, !name.isEmpty {
                store.upsert(agent: .codex, id: line.sessionID) { s in
                    s.title = name
                }
            }

        case "context_compacted":
            store.upsert(agent: .codex, id: line.sessionID) { s in
                let at = ts ?? Date()
                s.appendTimeline(ToolEvent(
                    id: UUID().uuidString,
                    name: "compact",
                    summary: "Context compacted",
                    startedAt: at,
                    endedAt: at,
                    isNote: true))
                if let ts { s.lastActivity = ts }
            }

        default:
            break
        }
    }

    /// Rate limits are account-level; don't let hours-old replayed values
    /// overwrite the gauges.
    private func applyRateLimits(_ payload: JSONValue, line: RolloutLine, ts: Date?) {
        let staleReplay = line.isSeed
            && (ts.map { Date().timeIntervalSince($0) > 30 * 60 } ?? true)
        if !staleReplay {
            usage.applyCodexRateLimits(payload)
        }
    }

    private func applyTokenCount(_ payload: JSONValue, line: RolloutLine, ts: Date?) {
        // Token totals are per-session cumulative counters, so replaying old
        // ones is always correct (SET semantics).
        applyRateLimits(payload, line: line, ts: ts)

        let info = payload["info"] ?? .null
        store.upsert(agent: .codex, id: line.sessionID) { s in
            if let totals = info["total_token_usage"] {
                let totalInput = totals["input_tokens"]?.int
                let cachedInput = totals["cached_input_tokens"]?.int
                if let v = totalInput {
                    s.inputTokens = Self.uncachedInputTokens(
                        totalInput: v, cachedInput: cachedInput ?? s.cacheReadTokens)
                }
                if let v = cachedInput { s.cacheReadTokens = v }
                if let v = totals["output_tokens"]?.int { s.outputTokens = v }
            }
            if let window = info["model_context_window"]?.int { s.contextWindowSize = window }
            if let last = info["last_token_usage"]?["total_tokens"]?.double,
               let window = info["model_context_window"]?.double, window > 0 {
                s.contextUsedPct = min(100, last / window * 100)
            }
            if let ts { s.lastActivity = ts }
        }
    }

    /// Codex's cumulative input_tokens includes cached_input_tokens. Session
    /// totals display the categories separately, so subtract the overlap.
    static func uncachedInputTokens(totalInput: Int, cachedInput: Int) -> Int {
        max(0, totalInput - cachedInput)
    }

    /// Sweep result from the engine: session id → file mtime fresh (<90s),
    /// plus ids whose rollout file stopped being tracked since the last sweep.
    private func applyLiveness(_ freshness: [String: Bool], vanished: Set<String>) {
        for (id, fresh) in freshness where !subagentThreads.contains(id) {
            let live = fresh || (turnInFlight[id] ?? false)
            store.setCodexLive(id: id, live: live)
        }
        // A vanished file (zstd compaction, deletion, age-out) can never
        // deliver task_complete: mark the session dead rather than holding
        // an in-flight turn live forever.
        for id in vanished where freshness[id] == nil {
            turnInFlight.removeValue(forKey: id)
            subagentThreads.remove(id)
            store.setCodexLive(id: id, live: false)
        }
        // Turn-state entries no longer backed by any tracked file: same.
        for id in Array(turnInFlight.keys) where freshness[id] == nil {
            turnInFlight.removeValue(forKey: id)
            store.setCodexLive(id: id, live: false)
        }
        store.expireInactiveCodex()
    }

    // MARK: - Timestamps

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}

// MARK: - Wire types (engine → main actor)

private struct RolloutLine {
    let sessionID: String
    let filePath: String
    let json: JSONValue
    let isSeed: Bool
}

private struct RolloutBatch {
    var lines: [RolloutLine] = []
    /// Session id → file path, for every file that produced new bytes.
    var touched: [String: String] = [:]
    /// Sessions seeded from files whose mtime was already stale.
    var staleSeeds: Set<String> = []

    var isEmpty: Bool { lines.isEmpty && touched.isEmpty && staleSeeds.isEmpty }
}

// MARK: - Background tail engine

/// Owns all file IO on a private serial queue. A small private tailer rather
/// than section C's FileTailer: its internals aren't pinned by the contract,
/// and this file must not depend on concurrently-written code.
private final class RolloutTailEngine {
    private let root: URL
    private let queue = DispatchQueue(label: "dev.evan.perch.codex-tailer", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var sweepTimer: DispatchSourceTimer?
    private var files: [String: FileState] = [:]   // path → tail state
    /// Session ids whose tracked file was dropped (vanished or aged out)
    /// since the last sweep; reported so their sessions can be marked dead.
    private var vanishedSessions: Set<String> = []
    private var didInitialSweep = false

    /// Hop-to-main callbacks, set before start().
    var onBatch: ((RolloutBatch) -> Void)?
    var onSweep: (([String: Bool], Set<String>) -> Void)?

    private struct FileState {
        var sessionID: String
        var offset: UInt64 = 0
        var partial = Data()
    }

    private static let seedFreshnessWindow: TimeInterval = 90
    private static let seedHistoryCutoff: TimeInterval = 24 * 3600
    private static let seedLineCap = 200
    private static let maxReadPerTick = 8 * 1024 * 1024

    init(root: URL) {
        self.root = root
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.pollTimer?.cancel()
            self?.pollTimer = nil
            self?.sweepTimer?.cancel()
            self?.sweepTimer = nil
        }
    }

    private func startOnQueue() {
        guard pollTimer == nil else { return }
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now(), repeating: 1.5)
        poll.setEventHandler { [weak self] in self?.tick() }
        poll.resume()
        pollTimer = poll

        let sweep = DispatchSource.makeTimerSource(queue: queue)
        sweep.schedule(deadline: .now() + 30, repeating: 30)
        sweep.setEventHandler { [weak self] in self?.sweep() }
        sweep.resume()
        sweepTimer = sweep
    }

    // MARK: Scan tick

    private func tick() {
        var batch = RolloutBatch()
        var present = Set<String>()
        let fm = FileManager.default

        // Today + yesterday, recomputed every tick (handles midnight rollover;
        // strictly fresher than the contract's hourly rescan).
        for dir in Self.watchDirs(root: root) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let path = dir.appendingPathComponent(name).path
                present.insert(path)
                process(path: path, into: &batch)
            }
        }

        // Keep tailing already-tracked files whose dir aged out of the window
        // (a long session crossing two midnights); drop states for files that
        // vanished (zstd compression replaces .jsonl with .jsonl.zst) or have
        // been idle past the seed cutoff — otherwise the map grows without
        // bound and every dead rollout ever seen is stat'ed each tick.
        for path in Array(files.keys) where !present.contains(path) {
            guard let state = files[path] else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: path) else {
                files.removeValue(forKey: path)
                vanishedSessions.insert(state.sessionID)
                continue
            }
            if let mtime = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(mtime) > Self.seedHistoryCutoff {
                files.removeValue(forKey: path)
                vanishedSessions.insert(state.sessionID)
            } else {
                process(path: path, into: &batch)
            }
        }

        if !batch.isEmpty { onBatch?(batch) }
        if !didInitialSweep {
            didInitialSweep = true
            sweep()   // settle liveness for stale-seeded sessions immediately
        }
    }

    private func process(path: String, into batch: inout RolloutBatch) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let sizeNumber = attrs[.size] as? NSNumber else { return }
        let size = sizeNumber.uint64Value
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        if files[path] == nil {
            let name = (path as NSString).lastPathComponent
            let sessionID = Self.sessionID(fromFileName: name)
            files[path] = seed(path: path, size: size, mtime: mtime,
                               sessionID: sessionID, into: &batch)
            return
        }

        var state = files[path]!
        if size < state.offset {
            // Truncated or replaced — start over.
            state.offset = 0
            state.partial = Data()
        }
        guard size > state.offset else {
            files[path] = state
            return
        }

        let newLines = readLines(path: path, upTo: size, state: &state)
        if !newLines.isEmpty {
            for raw in newLines {
                appendParsed(raw, sessionID: state.sessionID, path: path,
                             isSeed: false, into: &batch)
            }
            batch.touched[state.sessionID] = path
        }
        files[path] = state
    }

    /// First sight of a file. Older than 24h → offset at END, parse nothing.
    /// Fresh → ingest the last 200 lines (plus the session_meta first line
    /// when it falls outside that window, so cwd/version aren't lost).
    private func seed(path: String, size: UInt64, mtime: Date,
                      sessionID: String, into batch: inout RolloutBatch) -> FileState {
        var state = FileState(sessionID: sessionID)

        if Date().timeIntervalSince(mtime) > Self.seedHistoryCutoff {
            state.offset = size
            return state
        }

        guard let handle = FileHandle(forReadingAtPath: path) else {
            state.offset = size
            return state
        }
        defer { try? handle.close() }

        let maxSeedBytes: UInt64 = 4 * 1024 * 1024
        var headLine: String?
        var startOffset: UInt64 = 0
        if size > maxSeedBytes {
            // Grab the first line separately (session_meta lives there).
            if let head = try? handle.read(upToCount: 256 * 1024),
               let nl = head.firstIndex(of: 0x0A) {
                headLine = String(decoding: head[head.startIndex..<nl], as: UTF8.self)
            }
            startOffset = size - maxSeedBytes
        }

        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            PerchLog.warn("Seek failed for \(path): \(error)", category: "codex")
            state.offset = size
            return state
        }
        guard let data = try? handle.read(upToCount: Int(size - startOffset)) else {
            state.offset = size
            return state
        }
        state.offset = startOffset + UInt64(data.count)

        var lines = Self.splitLines(data, partial: &state.partial)
        if startOffset > 0, !lines.isEmpty {
            lines.removeFirst()   // partial line at the seek boundary
        }
        // Cap AFTER dropping response_item bulk: raw rollouts are dominated
        // by it, and a raw-line cap would push a mid-turn task_started out
        // of the window (session then swept dead while executing). The
        // substring pre-filter is cheap; appendParsed re-checks the parsed
        // type, and if the heuristic matches nothing (format drift) we fall
        // back to the raw suffix — old behavior, never worse.
        var pool = lines.filter(Self.isSeedCandidate)
        if pool.isEmpty { pool = lines }
        var toIngest = Array(pool.suffix(Self.seedLineCap))
        if let headLine {
            toIngest.insert(headLine, at: 0)
        } else if pool.count > Self.seedLineCap,
                  let first = pool.first, first.contains("\"session_meta\"") {
            toIngest.insert(first, at: 0)
        }

        for raw in toIngest {
            appendParsed(raw, sessionID: sessionID, path: path, isSeed: true, into: &batch)
        }

        if Date().timeIntervalSince(mtime) < Self.seedFreshnessWindow {
            batch.touched[sessionID] = path
        } else {
            batch.staleSeeds.insert(sessionID)
        }
        return state
    }

    private func readLines(path: String, upTo size: UInt64, state: inout FileState) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.offset)
        } catch {
            return []
        }
        let toRead = min(Int(size - state.offset), Self.maxReadPerTick)
        guard toRead > 0, let data = try? handle.read(upToCount: toRead), !data.isEmpty else {
            return []
        }
        state.offset += UInt64(data.count)
        return Self.splitLines(data, partial: &state.partial)
    }

    // MARK: Sweep (liveness)

    private func sweep() {
        let now = Date()
        var freshness: [String: Bool] = [:]
        for (path, state) in files {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            let fresh = mtime.map { now.timeIntervalSince($0) < Self.seedFreshnessWindow } ?? false
            freshness[state.sessionID] = (freshness[state.sessionID] ?? false) || fresh
        }
        // Ids still backed by another tracked file are not vanished.
        let vanished = vanishedSessions.filter { freshness[$0] == nil }
        vanishedSessions.removeAll()
        onSweep?(freshness, vanished)
    }

    // MARK: Parsing helpers

    private static let interestingTypes: Set<String> = [
        "session_meta", "event_msg", "turn_context", "token_count",
    ]

    /// Cheap textual probe for the seed window's type filter. Rollout lines
    /// are compact JSON with a top-level `"type":"…"`; false positives are
    /// filtered again by appendParsed after parsing.
    private static func isSeedCandidate(_ raw: String) -> Bool {
        for type in interestingTypes where raw.contains("\"type\":\"\(type)\"") {
            return true
        }
        return false
    }

    private func appendParsed(_ raw: String, sessionID: String, path: String,
                              isSeed: Bool, into batch: inout RolloutBatch) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let json = JSONValue(parsingLine: trimmed) else {
            PerchLog.warn("Skipping malformed rollout line in \((path as NSString).lastPathComponent)",
                          category: "codex")
            return
        }
        guard let type = json["type"]?.string, Self.interestingTypes.contains(type) else {
            return   // response_item and friends: bulk, no session-level signal
        }
        batch.lines.append(RolloutLine(sessionID: sessionID, filePath: path,
                                       json: json, isSeed: isSeed))
    }

    /// Splits complete lines out of `partial + chunk`; the trailing incomplete
    /// remainder goes back into `partial`.
    private static func splitLines(_ chunk: Data, partial: inout Data) -> [String] {
        var buffer = partial
        buffer.append(chunk)
        var out: [String] = []
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            if nl > start {
                out.append(String(decoding: buffer[start..<nl], as: UTF8.self))
            }
            start = buffer.index(after: nl)
        }
        partial = Data(buffer[start...])
        return out
    }

    /// `rollout-<ts>-<uuid>.jsonl` → thread uuid (last 36 chars before the
    /// extension); falls back to the filename stem.
    private static func sessionID(fromFileName name: String) -> String {
        var stem = name
        if stem.hasSuffix(".jsonl") { stem = String(stem.dropLast(6)) }
        if stem.count >= 36 {
            let candidate = String(stem.suffix(36))
            if UUID(uuidString: candidate) != nil { return candidate }
        }
        return stem
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    private static func watchDirs(root: URL) -> [URL] {
        let now = Date()
        return [now, now.addingTimeInterval(-86400)].map {
            root.appendingPathComponent(dayFormatter.string(from: $0), isDirectory: true)
        }
    }
}
