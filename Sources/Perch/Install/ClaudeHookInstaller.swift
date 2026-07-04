import Foundation
import PerchCore

/// Idempotent installer for Perch's hooks + statusline in
/// ~/.claude/settings.json (PLAN §2.1, §2.3). Discipline: parse → merge
/// preserving unknown keys → timestamped backup sibling → atomic replace;
/// throw rather than clobber anything unparseable.
enum ClaudeHookInstaller {
    static var settingsPath: URL {
        PerchPaths.claudeConfigDir.appendingPathComponent("settings.json")
    }

    /// Non-decision events — installed `"async": true` so they never slow the agent.
    private static let asyncEvents: [HookEventName] = [
        .sessionStart, .userPromptSubmit, .postToolUse, .notification, .stop,
        .subagentStart, .subagentStop, .preCompact, .sessionEnd,
    ]
    /// Sync events — Claude Code reads their stdout. Perch acks these
    /// immediately and never writes a decision; they stay sync only so the
    /// hook wiring matches what the events support.
    private static let syncEvents: [HookEventName] = [.permissionRequest, .preToolUse]
    private static var allEvents: [HookEventName] { asyncEvents + syncEvents }

    // MARK: - Install

    static func install(settingsPath: URL = ClaudeHookInstaller.settingsPath,
                        bridgePath: String = PerchPaths.bridgeInstallPath.path) throws -> InstallReport {
        let file = try InstallSupport.readObjectFile(at: settingsPath)
        var root = file.object
        var notes: [String] = []

        // Hooks: upsert our entries, preserve everything else.
        try InstallSupport.mergePerchHooks(
            into: &root,
            filePath: settingsPath.path,
            command: InstallSupport.hookCommand(bridgePath: bridgePath, agent: .claude),
            matcher: "*",
            asyncEvents: asyncEvents,
            syncEvents: syncEvents)

        // statusLine: chain, don't replace. A pre-existing non-Perch statusLine
        // is saved into PerchConfig BEFORE we overwrite it; the bridge execs it
        // and forwards its output.
        let desiredStatusline: JSONValue = .object([
            "type": .string("command"),
            "command": .string(InstallSupport.statuslineCommand(bridgePath: bridgePath)),
            "refreshInterval": .number(5),
        ])
        if let existing = root["statusLine"], !existing.isNull {
            if InstallSupport.isPerchEntry(existing) {
                // Already ours — repair in place (no-op unless the bridge path changed).
                root["statusLine"] = desiredStatusline
            } else {
                var config = PerchConfig.load()
                config.originalClaudeStatusline = existing
                try config.save()
                root["statusLine"] = desiredStatusline
                notes.append("Existing statusLine saved to Perch config — the bridge will chain it.")
            }
        } else {
            root["statusLine"] = desiredStatusline
        }

        let changed = JSONValue.object(root) != JSONValue.object(file.object)
        var backupPath: String?
        if changed {
            backupPath = try InstallSupport.writeObjectFile(root, to: settingsPath, originalRaw: file.raw)
            notes.insert("Registered Perch hooks for \(allEvents.count) events " +
                         "(all observe-only) + statusLine " +
                         "in \(settingsPath.path).", at: 0)
            notes.append("Restart running Claude Code sessions to pick up the hooks.")
        } else {
            notes.insert("Perch hooks + statusLine already present in \(settingsPath.path).", at: 0)
        }
        return InstallReport(changed: changed, backupPath: backupPath, notes: notes)
    }

    // MARK: - Uninstall

    static func uninstall(settingsPath: URL = ClaudeHookInstaller.settingsPath) throws -> InstallReport {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else {
            return InstallReport(changed: false, backupPath: nil,
                                 notes: ["\(settingsPath.path) does not exist — nothing to remove."])
        }
        let file = try InstallSupport.readObjectFile(at: settingsPath)
        var root = file.object
        var notes: [String] = []

        let touched = InstallSupport.removePerchHooks(from: &root)
        if touched > 0 {
            notes.append("Removed Perch hook entries from \(touched) event(s).")
        }

        var restoredOriginalStatusline = false
        if let statusline = root["statusLine"], InstallSupport.isPerchEntry(statusline) {
            if let original = PerchConfig.load().originalClaudeStatusline {
                root["statusLine"] = original
                restoredOriginalStatusline = true
                notes.append("Restored the original statusLine.")
            } else {
                root.removeValue(forKey: "statusLine")
                notes.append("Removed the Perch statusLine.")
            }
        }

        let changed = JSONValue.object(root) != JSONValue.object(file.object)
        var backupPath: String?
        if changed {
            backupPath = try InstallSupport.writeObjectFile(root, to: settingsPath, originalRaw: file.raw)
        } else {
            notes.append("No Perch entries found in \(settingsPath.path) — nothing to remove.")
        }
        // Only drop the captured original once settings.json actually reflects the
        // restore — if writeObjectFile threw above, the capture survives for retry.
        if restoredOriginalStatusline {
            var config = PerchConfig.load()
            config.originalClaudeStatusline = nil
            try config.save()
        }
        return InstallReport(changed: changed, backupPath: backupPath, notes: notes)
    }

    // MARK: - Status

    static func status(settingsPath: URL = ClaudeHookInstaller.settingsPath) -> String {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else {
            return "Claude: hooks not installed (no settings.json at \(settingsPath.path))"
        }
        guard let file = try? InstallSupport.readObjectFile(at: settingsPath) else {
            return "Claude: settings.json exists but cannot be parsed (\(settingsPath.path))"
        }
        let wired = InstallSupport.wiredEventCount(root: file.object, events: allEvents)
        let statusline: String
        if let sl = file.object["statusLine"], !sl.isNull {
            statusline = InstallSupport.isPerchEntry(sl) ? "Perch" : "user's (not chained)"
        } else {
            statusline = "none"
        }
        return "Claude: hooks \(wired)/\(allEvents.count) events, statusLine \(statusline) — \(settingsPath.path)"
    }
}
