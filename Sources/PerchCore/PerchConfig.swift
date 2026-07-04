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
    /// Extra keys we don't model yet — preserved verbatim.
    public var extra: [String: JSONValue]

    public init() {
        self.originalClaudeStatusline = nil
        self.scratchDirs = []
        self.extra = [:]
    }

    enum KnownKeys: String, CaseIterable {
        case originalClaudeStatusline
        case scratchDirs
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
