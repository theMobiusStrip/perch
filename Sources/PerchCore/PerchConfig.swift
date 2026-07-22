import Foundation

/// Perch's own config file (~/Library/Application Support/Perch/config.json).
/// Read by both the app and the bridge (statusline chaining), so it lives in
/// PerchCore. Unknown keys in the file are preserved on save — including the
/// `alwaysAllow` key written by pre-0.3 versions, which no longer has any
/// effect (Perch is observe-only and never answers permission prompts).
public struct PerchConfig: Codable, Sendable {
    /// The user's pre-existing `statusLine` object from ~/.claude/settings.json,
    /// captured at install time. The bridge chains it: exec the original
    /// command with the same stdin and print its output.
    public var originalClaudeStatusline: JSONValue?
    /// Regenerable scratch directories (basenames or path fragments) the user
    /// declares safe to `rm -rf` — a recursive delete scoped to these badges
    /// instead of firing a danger notification. For project-local build-output
    /// dirs Perch can't know are ephemeral by name (e.g. `.sweep`, `.preview`).
    public var scratchDirs: [String]
    /// Whether Perch may make its one and only network call: a periodic
    /// unauthenticated GET to the GitHub releases API to see if a newer build
    /// exists. Default on; the menu exposes a toggle. When false Perch makes
    /// zero network calls.
    public var checkForUpdates: Bool
    /// How old (days) a clean, merged, session-free agent worktree must be
    /// before the worktree audit calls it reclaimable. Default 7; clamped to
    /// at least 1 so a value of 0/negative can never mark same-day worktrees
    /// removable.
    public var worktreeStaleDays: Int
    /// Per-category notification preferences. Defaults preserve the behavior
    /// from before preferences were exposed.
    public var notifyDangerousCalls: Bool
    public var notifyAttention: Bool
    public var notifyTaskCompletion: Bool
    public var notifyUsageThresholds: Bool
    public var playNotificationSounds: Bool
    /// Set once the user finishes or dismisses the guided monitoring setup.
    public var hasCompletedSetup: Bool
    /// Most recent end-to-end hook event observed from each integration. These
    /// timestamps distinguish static hook configuration from verified delivery
    /// across app launches without retaining any event content.
    public var lastClaudeHookEventAt: Date?
    public var lastCodexHookEventAt: Date?
    /// Extra keys we don't model yet — preserved verbatim.
    public var extra: [String: JSONValue]

    public static let defaultWorktreeStaleDays = 7

    public init() {
        self.originalClaudeStatusline = nil
        self.scratchDirs = []
        self.checkForUpdates = true
        self.worktreeStaleDays = PerchConfig.defaultWorktreeStaleDays
        self.notifyDangerousCalls = true
        self.notifyAttention = true
        self.notifyTaskCompletion = true
        self.notifyUsageThresholds = true
        self.playNotificationSounds = true
        self.hasCompletedSetup = false
        self.lastClaudeHookEventAt = nil
        self.lastCodexHookEventAt = nil
        self.extra = [:]
    }

    enum KnownKeys: String, CaseIterable {
        case originalClaudeStatusline
        case scratchDirs
        case checkForUpdates
        case worktreeStaleDays
        case notifyDangerousCalls
        case notifyAttention
        case notifyTaskCompletion
        case notifyUsageThresholds
        case playNotificationSounds
        case hasCompletedSetup
        case lastClaudeHookEventAt
        case lastCodexHookEventAt
    }

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        var config = PerchConfig()
        if let v = raw["originalClaudeStatusline"], !v.isNull {
            config.originalClaudeStatusline = v
        }
        if let arr = raw["scratchDirs"]?.arrayValue {
            config.scratchDirs = arr.compactMap(\.string)
        }
        if let v = raw["checkForUpdates"]?.boolValue {
            config.checkForUpdates = v
        }
        if let v = raw["worktreeStaleDays"]?.int {
            config.worktreeStaleDays = max(1, v)
        }
        if let v = raw["notifyDangerousCalls"]?.boolValue {
            config.notifyDangerousCalls = v
        }
        if let v = raw["notifyAttention"]?.boolValue {
            config.notifyAttention = v
        }
        if let v = raw["notifyTaskCompletion"]?.boolValue {
            config.notifyTaskCompletion = v
        }
        if let v = raw["notifyUsageThresholds"]?.boolValue {
            config.notifyUsageThresholds = v
        }
        if let v = raw["playNotificationSounds"]?.boolValue {
            config.playNotificationSounds = v
        }
        if let v = raw["hasCompletedSetup"]?.boolValue {
            config.hasCompletedSetup = v
        }
        if let seconds = raw["lastClaudeHookEventAt"]?.double {
            config.lastClaudeHookEventAt = Date(timeIntervalSince1970: seconds)
        }
        if let seconds = raw["lastCodexHookEventAt"]?.double {
            config.lastCodexHookEventAt = Date(timeIntervalSince1970: seconds)
        }
        if let obj = raw.objectValue {
            let known = Set(KnownKeys.allCases.map(\.rawValue))
            config.extra = obj.filter { !known.contains($0.key) }
        }
        self = config
    }

    public func encode(to encoder: Encoder) throws {
        var obj = extra
        if let originalClaudeStatusline {
            obj["originalClaudeStatusline"] = originalClaudeStatusline
        }
        if !scratchDirs.isEmpty {
            obj["scratchDirs"] = .array(scratchDirs.map(JSONValue.string))
        }
        // Default is true; only persist the non-default so files stay minimal.
        if !checkForUpdates {
            obj["checkForUpdates"] = .bool(false)
        }
        // Same discipline: only persist a staleDays that differs from default.
        if worktreeStaleDays != PerchConfig.defaultWorktreeStaleDays {
            obj["worktreeStaleDays"] = .number(Double(worktreeStaleDays))
        }
        if !notifyDangerousCalls { obj["notifyDangerousCalls"] = .bool(false) }
        if !notifyAttention { obj["notifyAttention"] = .bool(false) }
        if !notifyTaskCompletion { obj["notifyTaskCompletion"] = .bool(false) }
        if !notifyUsageThresholds { obj["notifyUsageThresholds"] = .bool(false) }
        if !playNotificationSounds { obj["playNotificationSounds"] = .bool(false) }
        if hasCompletedSetup { obj["hasCompletedSetup"] = .bool(true) }
        if let lastClaudeHookEventAt {
            obj["lastClaudeHookEventAt"] = .number(lastClaudeHookEventAt.timeIntervalSince1970)
        }
        if let lastCodexHookEventAt {
            obj["lastCodexHookEventAt"] = .number(lastCodexHookEventAt.timeIntervalSince1970)
        }
        try JSONValue.object(obj).encode(to: encoder)
    }

    public static func load() -> PerchConfig {
        guard let data = try? Data(contentsOf: PerchPaths.configFile),
              let config = try? JSONDecoder().decode(PerchConfig.self, from: data) else {
            return PerchConfig()
        }
        return config
    }

    public func save() throws {
        try PerchPaths.ensureAppSupportDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try data.write(to: PerchPaths.configFile, options: .atomic)
    }
}
