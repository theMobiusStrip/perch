import Foundation
import PerchCore

/// Central hub. Everything mutating session state funnels through here on the
/// main actor: socket envelopes (hooks/statusline), transcript tailers,
/// liveness monitor.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    // Wired by AppDelegate.
    var riskFeed: RiskFeed?
    var usageStore: UsageStore?
    var securityPosture: SecurityPosture?
    /// (session, reason) — notch auto-expand + notifications.
    var onAttention: ((Session, String) -> Void)?
    var onTaskComplete: ((Session, String?) -> Void)?
    /// Fired when the detector flags a danger-level tool call — OS
    /// notification + notch attention. (session, toolName, risk)
    var onRiskDetected: ((Session, String, RiskAssessment) -> Void)?

    private var map: [SessionKey: Session] = [:]

    // MARK: - Generic upsert API (used by tailers/liveness)

    func upsert(agent: AgentKind, id: String, mutate: (inout Session) -> Void) {
        let key = SessionKey(agent: agent, id: id)
        var session = map[key] ?? Session(key: key)
        mutate(&session)
        map[key] = session
        publish()
    }

    func find(agent: AgentKind, id: String) -> Session? {
        map[SessionKey(agent: agent, id: id)]
    }

    func remove(agent: AgentKind, id: String) {
        let key = SessionKey(agent: agent, id: id)
        guard map.removeValue(forKey: key) != nil else { return }
        riskFeed?.dismissAll(for: key)
        publish()
    }

    func allSessions(agent: AgentKind) -> [Session] {
        map.values.filter { $0.key.agent == agent }
    }

    // MARK: - Socket envelopes

    func handleEnvelope(_ env: BridgeEnvelope, reply: @escaping @Sendable (BridgeReply) -> Void) {
        let payload = HookPayload(env.payload)
        switch env.kind {
        case .statusline:
            usageStore?.applyClaudeStatusline(payload)
            applyStatuslineToSession(payload)
            // Rate-limit gauges depend entirely on this payload; log its
            // shape so "why no Claude gauges" is answerable from the log.
            let hasLimits = payload.json["rate_limits"]?.objectValue != nil
            PerchLog.info("Statusline from \(payload.sessionId ?? "?") — rate_limits \(hasLimits ? "present" : "ABSENT")",
                          category: "usage")
            reply(.empty)
        case .hook:
            guard let event = payload.eventName else {
                PerchLog.warn("Unknown hook event: \(payload.eventNameRaw ?? "nil")", category: "store")
                reply(.empty)
                return
            }
            route(event: event, payload: payload, agent: env.agent, reply: reply)
        }
    }

    private func route(event: HookEventName, payload: HookPayload, agent: AgentKind,
                       reply: @escaping @Sendable (BridgeReply) -> Void) {
        guard let sid = payload.sessionId else {
            reply(.empty)
            return
        }
        let now = Date()
        let touch: (inout Session) -> Void = { s in
            s.lastActivity = now
            if let cwd = payload.cwd { s.cwd = cwd }
            if let tp = payload.transcriptPath { s.transcriptPath = tp }
            s.isLive = true
        }

        switch event {
        case .sessionStart:
            PerchLog.info("SessionStart \(agent.rawValue):\(sid) cwd=\(payload.cwd ?? "?")", category: "store")
            upsert(agent: agent, id: sid) { s in
                touch(&s)
                if s.startedAt == nil { s.startedAt = now }
                if s.state == .unknown || s.state == .ended { s.state = .idle }
            }
            reply(.empty)

        case .userPromptSubmit:
            upsert(agent: agent, id: sid) { s in
                touch(&s)
                s.state = .executing
                s.attentionNote = nil
                if let prompt = payload.prompt { s.lastPrompt = String(prompt.prefix(200)) }
            }
            reply(.empty)

        case .preToolUse:
            let toolName = payload.toolName ?? "tool"
            let risk = RiskAssessor.assess(agent: agent, toolName: toolName, input: payload.toolInput)
            upsert(agent: agent, id: sid) { s in
                touch(&s)
                s.state = .executing
                if !risk.isEmpty { s.lastRisk = risk.level }
                if risk.level == .danger {
                    s.attentionNote = "DANGER: \(risk.findings.first?.message ?? toolName)"
                }
                if !payload.isSubagentContext {
                    var event = ToolEvent(
                        id: payload.toolUseId ?? UUID().uuidString,
                        name: toolName,
                        summary: ToolSummary.summarize(toolName: toolName, input: payload.toolInput),
                        startedAt: now)
                    event.risk = risk.level
                    s.appendTimeline(event)
                }
            }
            // Observe-only: reply immediately and empty — Perch never answers
            // for the agent. Flagged calls surface in the feed (notch card)
            // and, for danger, an OS notification.
            reply(.empty)
            surfaceRisk(risk, agent: agent, sid: sid, toolName: toolName,
                        toolInput: payload.toolInput, cwd: payload.cwd)

        case .postToolUse:
            upsert(agent: agent, id: sid) { s in
                touch(&s)
                s.state = .executing
                if let toolUseId = payload.toolUseId {
                    let isError = payload.toolResponse?["is_error"]?.boolValue
                        ?? payload.toolResponse?["error"].map { !$0.isNull } ?? false
                    s.completeTimelineEvent(id: toolUseId, at: now, isError: isError)
                }
            }
            reply(.empty)

        case .permissionRequest:
            let toolName = payload.toolName ?? "tool"
            let risk = RiskAssessor.assess(agent: agent, toolName: toolName, input: payload.toolInput)
            upsert(agent: agent, id: sid) { s in
                touch(&s)
                s.state = .waitingPermission
                s.attentionNote = risk.isEmpty
                    ? "Permission: \(toolName)"
                    : "\(risk.level.label.uppercased()): \(risk.findings.first?.message ?? toolName)"
                s.lastRisk = risk.level
            }
            // Observe-only: the terminal owns the decision. Reply immediately
            // (empty stdout = no opinion) so the agent's own prompt shows with
            // zero added latency; Perch just surfaces what is being asked.
            reply(.empty)
            surfaceRisk(risk, agent: agent, sid: sid, toolName: toolName,
                        toolInput: payload.toolInput, cwd: payload.cwd)
            if let session = find(agent: agent, id: sid) {
                let reason = risk.isEmpty
                    ? "Permission requested: \(toolName)"
                    : "\(risk.level.label.uppercased()) — \(risk.findings.first?.message ?? toolName)"
                onAttention?(session, reason)
            }

        case .notification:
            upsert(agent: agent, id: sid) { s in
                touch(&s)
                if s.state != .waitingPermission { s.state = .waitingInput }
                s.attentionNote = payload.message
            }
            if let session = find(agent: agent, id: sid) {
                onAttention?(session, payload.message ?? "Session needs input")
            }
            reply(.empty)

        case .stop:
            upsert(agent: agent, id: sid) { s in
                touch(&s)
                s.state = .idle
                s.attentionNote = nil
                if let msg = payload.lastAssistantMessage {
                    s.lastAssistantSnippet = String(msg.prefix(300))
                }
            }
            if let session = find(agent: agent, id: sid), !payload.stopHookActive {
                onTaskComplete?(session, payload.lastAssistantMessage)
            }
            reply(.empty)

        case .subagentStart:
            upsert(agent: agent, id: sid) { s in
                touch(&s)
                s.subagentCount += 1
            }
            reply(.empty)

        case .subagentStop:
            upsert(agent: agent, id: sid) { s in
                touch(&s)
                s.subagentCount = max(0, s.subagentCount - 1)
            }
            reply(.empty)

        case .preCompact, .postCompact:
            upsert(agent: agent, id: sid) { s in
                touch(&s)
                s.appendTimeline(ToolEvent(
                    id: UUID().uuidString,
                    name: "compact",
                    summary: event == .preCompact ? "Compacting context…" : "Context compacted",
                    startedAt: now,
                    endedAt: now,
                    isNote: true))
            }
            reply(.empty)

        case .sessionEnd:
            PerchLog.info("SessionEnd \(agent.rawValue):\(sid)", category: "store")
            let key = SessionKey(agent: agent, id: sid)
            riskFeed?.dismissAll(for: key)
            upsert(agent: agent, id: sid) { s in
                s.lastActivity = now
                s.state = .ended
                s.isLive = false
                s.attentionNote = nil
            }
            scheduleRemoval(of: key)
            reply(.empty)
        }
    }

    /// Common risk surfacing for PreToolUse/PermissionRequest: log, feed the
    /// notch card, and escalate danger to an OS notification. Detection never
    /// touches the agent — it only makes noise on this side of the glass.
    private func surfaceRisk(_ risk: RiskAssessment, agent: AgentKind, sid: String,
                             toolName: String, toolInput: JSONValue?, cwd: String?) {
        guard !risk.isEmpty else { return }
        PerchLog.warn("Risk \(risk.level.label) on \(toolName) (\(agent.rawValue)): \(risk.findings.map(\.code).joined(separator: ","))",
                      category: "detect")
        let key = SessionKey(agent: agent, id: sid)
        // PreToolUse and PermissionRequest both fire for the same call; the
        // feed's dedupe decides what counts as a new event, so the score and
        // the notification tally each real call exactly once.
        let isNewEvent = riskFeed?.add(key: key,
                                       toolName: toolName,
                                       toolInput: toolInput ?? .null,
                                       cwd: cwd ?? find(agent: agent, id: sid)?.cwd,
                                       risk: risk) ?? true
        guard isNewEvent else { return }
        securityPosture?.record(risk.level)
        if risk.level == .danger, let session = find(agent: agent, id: sid) {
            onRiskDetected?(session, toolName, risk)
        }
    }

    private func applyStatuslineToSession(_ payload: HookPayload) {
        guard let sid = payload.sessionId else { return }
        upsert(agent: .claude, id: sid) { s in
            if let name = payload.json["model"]?["display_name"]?.string { s.model = name }
            if let pct = payload.json["context_window"]?["used_percentage"]?.double { s.contextUsedPct = pct }
            if let size = payload.json["context_window"]?["context_window_size"]?.int { s.contextWindowSize = size }
            if let cost = payload.json["cost"]?["total_cost_usd"]?.double { s.costUSD = cost }
        }
    }

    // MARK: - Liveness (Claude pid registry / Codex inference)

    /// Full set of live Claude sessions from ~/.claude/sessions. Sessions not
    /// in the set are gone: their process died or exited — remove them.
    func applyClaudeLiveness(_ live: [ClaudeLiveInfo]) {
        var seen = Set<String>()
        for info in live {
            seen.insert(info.sessionId)
            if find(agent: .claude, id: info.sessionId) == nil {
                PerchLog.info("Discovered live claude session \(info.sessionId) pid=\(info.pid) cwd=\(info.cwd ?? "?")",
                              category: "liveness")
            }
            upsert(agent: .claude, id: info.sessionId) { s in
                s.pid = info.pid
                s.isLive = true
                s.entrypoint = info.entrypoint
                s.version = info.version
                if s.cwd == nil { s.cwd = info.cwd }
                if s.title == nil, let name = info.name, !name.isEmpty { s.title = name }
                if s.startedAt == nil, let ms = info.startedAtMs {
                    s.startedAt = Date(timeIntervalSince1970: Double(ms) / 1000)
                }
                if s.state == .unknown { s.state = .idle }
            }
        }
        for session in allSessions(agent: .claude) where !seen.contains(session.key.id) {
            if let pid = session.pid {
                // Known process: keep the session if it's still alive (a
                // transient registry scan glitch must not tear down live
                // sessions).
                let alive = kill(pid, 0) == 0 || errno == EPERM
                if alive { continue }
                PerchLog.info("Removing \(session.key.agent.rawValue):\(session.key.id) — pid \(pid) gone",
                              category: "store")
                remove(agent: .claude, id: session.key.id)
            } else {
                // Hook-only session (never registered a pid file — startup
                // race or non-registering environment). Keep it while it is
                // active; GC after 10 minutes of silence.
                let idle = Date().timeIntervalSince(session.lastActivity) > 600
                if idle || session.state == .ended {
                    PerchLog.info("Removing hook-only session \(session.key.id) (idle=\(idle))",
                                  category: "store")
                    remove(agent: .claude, id: session.key.id)
                }
            }
        }
    }

    /// Codex has no pid registry; the rollout tailer infers liveness.
    func setCodexLive(id: String, live: Bool) {
        guard var s = map[SessionKey(agent: .codex, id: id)] else { return }
        s.isLive = live
        if !live, s.state != .ended { s.state = .idle }
        map[s.key] = s
        publish()
    }

    // MARK: - Internals

    private func scheduleRemoval(of key: SessionKey, after seconds: TimeInterval = 30) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self else { return }
            if let s = self.map[key], s.state == .ended {
                self.remove(agent: key.agent, id: key.id)
            }
        }
    }

    private func publish() {
        sessions = map.values.sorted { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            let aExec = a.state == .executing, bExec = b.state == .executing
            if aExec != bExec { return aExec }
            return a.lastActivity > b.lastActivity
        }
    }
}

/// Parsed ~/.claude/sessions/<pid>.json entry, validated against the live
/// process table (pid + procStart double-check) by LivenessMonitor.
struct ClaudeLiveInfo: Sendable, Equatable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    var startedAtMs: Int64?
    var version: String?
    var kind: String?
    var entrypoint: String?
    var name: String?
}
