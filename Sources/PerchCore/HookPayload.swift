import Foundation

/// Hook event names. Claude Code and Codex share this family (Codex adds
/// PostCompact; Claude adds Notification/PreCompact/SessionEnd and, since
/// 2.1.209, PostToolUseFailure).
public enum HookEventName: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    /// Claude ≥2.1.209: failing tool calls fire this INSTEAD of PostToolUse.
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case sessionEnd = "SessionEnd"
}

/// Tolerant accessor layer over a raw hook payload. Field gotchas observed
/// live (v2.1.197): PostToolUse carries `tool_response` (docs say
/// `tool_output`); PreToolUse includes undocumented `tool_use_id`; Stop
/// includes `last_assistant_message` and `background_tasks`.
public struct HookPayload: Sendable {
    public let json: JSONValue

    public init(_ json: JSONValue) {
        self.json = json
    }

    public var eventNameRaw: String? { json["hook_event_name"]?.string }
    public var eventName: HookEventName? { eventNameRaw.flatMap(HookEventName.init(rawValue:)) }

    public var sessionId: String? { json["session_id"]?.string }
    public var promptId: String? { json["prompt_id"]?.string }
    public var turnId: String? { json["turn_id"]?.string }
    public var transcriptPath: String? { json["transcript_path"]?.string }
    public var cwd: String? { json["cwd"]?.string }
    public var permissionMode: String? { json["permission_mode"]?.string }

    public var agentId: String? { json["agent_id"]?.string }
    public var agentType: String? { json["agent_type"]?.string }
    public var isSubagentContext: Bool { agentId != nil }

    public var toolName: String? { json["tool_name"]?.string }
    public var toolInput: JSONValue? { json["tool_input"] }
    public var toolUseId: String? { json["tool_use_id"]?.string }
    /// Accepts both the observed field and the documented one.
    public var toolResponse: JSONValue? { json.first(of: ["tool_response", "tool_output"]) }
    /// PostToolUseFailure (observed live on 2.1.209): `error` is a short
    /// message ("Exit code 1"), alongside `is_interrupt` and `duration_ms`.
    public var errorMessage: String? { json["error"]?.string }
    public var isInterrupt: Bool { json["is_interrupt"]?.boolValue ?? false }

    public var prompt: String? { json["prompt"]?.string }
    public var message: String? { json["message"]?.string }
    public var notificationType: String? { json.first(of: ["notification_type", "type"])?.string }
    public var lastAssistantMessage: String? { json["last_assistant_message"]?.string }
    public var backgroundTasks: [JSONValue]? { json["background_tasks"]?.arrayValue }
    public var stopHookActive: Bool { json["stop_hook_active"]?.boolValue ?? false }

    /// SessionStart source ("startup" | "resume" | "clear" | ...).
    public var source: String? { json["source"]?.string }

}
