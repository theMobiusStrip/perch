import Foundation
import PerchCore

struct SessionKey: Hashable, Sendable {
    let agent: AgentKind
    let id: String
}

enum SessionState: String, Sendable {
    case executing
    case waitingPermission
    case waitingInput
    case idle
    case ended
    case unknown

    var needsAttention: Bool {
        self == .waitingPermission || self == .waitingInput
    }
}

/// One entry in a session's tool timeline, built from PreToolUse/PostToolUse.
struct ToolEvent: Identifiable, Equatable {
    let id: String            // tool_use_id when present, else generated
    var name: String
    var summary: String       // plain-language one-liner ("Read PLAN.md", "Run `make test`")
    var startedAt: Date
    var endedAt: Date?
    var isError: Bool = false
    var isNote: Bool = false  // compaction markers etc.
    var risk: RiskLevel = .safe
}

struct Session: Identifiable, Equatable {
    let key: SessionKey
    var id: SessionKey { key }

    var title: String?             // ai-title / custom-title / pid-file name
    var cwd: String?
    var gitBranch: String?
    var model: String?             // display name preferred
    var state: SessionState = .unknown
    var attentionNote: String?     // e.g. Notification message while waiting
    var startedAt: Date?
    var lastActivity: Date = Date()
    var isLive: Bool = true
    var pid: Int32?
    var entrypoint: String?        // "claude-desktop" vs terminal etc.
    var version: String?
    var transcriptPath: String?

    var lastPrompt: String?
    var lastAssistantSnippet: String?
    /// Risk level of the most recent flagged tool call (for the row badge).
    var lastRisk: RiskLevel = .safe
    var lastRiskAt: Date?

    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    var contextUsedPct: Double?
    var contextWindowSize: Int?
    var costUSD: Double?

    var subagentCount: Int = 0
    var timeline: [ToolEvent] = []

    var needsAttention: Bool { state.needsAttention }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "unknown" }
        return (cwd as NSString).lastPathComponent
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return projectName
    }

    init(key: SessionKey) {
        self.key = key
    }
}

extension Session {
    static let timelineCap = 200
    static let riskBadgeTTL: TimeInterval = 5 * 60

    /// Row badges are an immediate-attention cue, not a permanent label on a
    /// session. The retained detection history remains available for an hour.
    func visibleRisk(at date: Date = Date()) -> RiskLevel? {
        guard lastRisk != .safe, let lastRiskAt,
              date.timeIntervalSince(lastRiskAt) <= Self.riskBadgeTTL else { return nil }
        return lastRisk
    }

    mutating func appendTimeline(_ event: ToolEvent) {
        timeline.append(event)
        if timeline.count > Self.timelineCap {
            timeline.removeFirst(timeline.count - Self.timelineCap)
        }
    }

    mutating func completeTimelineEvent(id: String, at date: Date, isError: Bool) {
        if let idx = timeline.lastIndex(where: { $0.id == id && $0.endedAt == nil }) {
            timeline[idx].endedAt = date
            timeline[idx].isError = isError
        }
    }
}

/// Plain-language summaries for tool calls shown in the timeline.
enum ToolSummary {
    static func summarize(toolName: String, input: JSONValue?) -> String {
        func lastComponent(_ path: String) -> String { (path as NSString).lastPathComponent }
        func truncate(_ s: String, _ n: Int = 60) -> String {
            s.count > n ? String(s.prefix(n)) + "…" : s
        }
        let path = input?.first(of: ["file_path", "path", "notebook_path"])?.string
        switch toolName {
        case "Read": return "Read \(path.map(lastComponent) ?? "file")"
        case "Write": return "Write \(path.map(lastComponent) ?? "file")"
        case "Edit", "MultiEdit", "NotebookEdit": return "Edit \(path.map(lastComponent) ?? "file")"
        case "Bash", "shell", "local_shell":
            if let cmd = input?.first(of: ["command", "cmd"])?.string { return "Run `\(truncate(cmd))`" }
            return "Run shell command"
        case "Grep": return "Search for \(truncate(input?["pattern"]?.string ?? "pattern", 40))"
        case "Glob": return "Find files \(truncate(input?["pattern"]?.string ?? "", 40))"
        case "WebFetch": return "Fetch \(truncate(input?["url"]?.string ?? "URL", 50))"
        case "WebSearch": return "Search web: \(truncate(input?["query"]?.string ?? "", 40))"
        case "Task", "Agent": return "Spawn agent: \(truncate(input?["description"]?.string ?? "task", 40))"
        case "apply_patch": return "Apply patch"
        default:
            return truncate(toolName, 40)
        }
    }
}
