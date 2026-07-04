import Foundation

/// Canonical paths shared by the app and the bridge CLI.
public enum PerchPaths {
    public static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Perch", isDirectory: true)
    }

    public static var socketPath: String { appSupportDir.appendingPathComponent("perch.sock").path }
    public static var configFile: URL { appSupportDir.appendingPathComponent("config.json") }
    public static var logFile: URL { appSupportDir.appendingPathComponent("perch.log") }
    /// Stable location the hook commands point at (survives app moves).
    public static var bridgeInstallPath: URL { appSupportDir.appendingPathComponent("perch-bridge") }

    /// Claude config dir, honoring $CLAUDE_CONFIG_DIR.
    public static var claudeConfigDir: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    public static var codexHomeDir: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    @discardableResult
    public static func ensureAppSupportDir() throws -> URL {
        let dir = appSupportDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }
}

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}

public enum BridgeKind: String, Codable, Sendable {
    case hook
    case statusline
}

/// One envelope per bridge invocation, sent app-ward over the unix socket
/// as a single newline-terminated JSON line.
public struct BridgeEnvelope: Codable, Sendable {
    public var v: Int
    public var kind: BridgeKind
    public var agent: AgentKind
    public var receivedAtMs: Int64
    public var payload: JSONValue

    public init(kind: BridgeKind, agent: AgentKind, receivedAtMs: Int64, payload: JSONValue) {
        self.v = 1
        self.kind = kind
        self.agent = agent
        self.receivedAtMs = receivedAtMs
        self.payload = payload
    }
}

/// App reply. `stdout == nil` means: print nothing, exit 0 — the agent
/// behaves exactly as if Perch didn't exist. The app replies empty to every
/// hook event (observe-only); `stdout`, if ever set, is printed verbatim by
/// the bridge, kept only for wire-format compatibility.
public struct BridgeReply: Codable, Sendable {
    public var stdout: JSONValue?

    public init(stdout: JSONValue?) {
        self.stdout = stdout
    }

    public static let empty = BridgeReply(stdout: nil)
}

/// Wire framing: one JSON object per line, UTF-8, '\n' terminated.
public enum BridgeFraming {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeLine<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
