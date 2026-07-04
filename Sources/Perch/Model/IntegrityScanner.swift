import CryptoKit
import Foundation
import PerchCore

/// Live, read-only inventory of the agent's persistence surface — the files a
/// hijacked agent would write to in order to survive a session: its own
/// config/hooks, the instructions it reads every run, and OS-level autostart.
/// Perch never judges intent; it shows current state (present? changed lately?
/// any hook that isn't ours?) and lets you decide. Nothing here is derived
/// from what Perch happened to watch — it's the truth on disk right now, so it
/// covers changes made before Perch launched or while hooks were uninstalled.
///
/// Every item carries a content-derived `fingerprint`. Acknowledging an item
/// (notch button or `--integrity-ack`) records that fingerprint; while the
/// surface still matches it, the flag is suppressed and the row reads
/// "reviewed". This is not an approval — Perch stays read-only — it only
/// changes "changed recently" into the useful "changed since you looked".

enum IntegrityStatus: String, Sendable {
    case unchanged       // present, not modified recently, nothing unusual
    case changedRecently // mtime within the recency window
    case nonPerch        // a hook/command Perch doesn't recognise as its own
    case unreadable      // exists but Perch could not read it (don't claim empty)
    case absent          // not present (for optional surface)
}

enum IntegrityCategory: String, CaseIterable, Sendable {
    case agentConfig = "Agent config"
    case memory = "Instructions & memory"
    case persistence = "System persistence"
}

struct IntegrityItem: Identifiable, Sendable, Equatable {
    let id: String
    let category: IntegrityCategory
    let label: String
    let detail: String
    let lastModified: Date?
    let status: IntegrityStatus
    /// Content-derived identity used by the acknowledge flow: while the
    /// surface still hashes to an acknowledged fingerprint, its flag stays
    /// suppressed; any real change produces a new fingerprint and re-flags.
    let fingerprint: String

    init(id: String, category: IntegrityCategory, label: String, detail: String,
         lastModified: Date?, status: IntegrityStatus, fingerprint: String = "") {
        self.id = id
        self.category = category
        self.label = label
        self.detail = detail
        self.lastModified = lastModified
        self.status = status
        self.fingerprint = fingerprint
    }

    var isFlagged: Bool {
        status == .nonPerch || status == .changedRecently || status == .unreadable
    }
}

struct IntegritySnapshot: Sendable, Equatable {
    var items: [IntegrityItem] = []
    var scannedAt: Date?

    func items(in category: IntegrityCategory) -> [IntegrityItem] {
        items.filter { $0.category == category }
    }
    /// Items worth a glance: an unrecognised hook, a recent change, or
    /// something Perch couldn't read.
    var flaggedCount: Int { items.filter(\.isFlagged).count }

    /// Plain-text rendering for `Perch --integrity-report` — one line per
    /// surface item, so the scan is scriptable and auditable. Flagged rows
    /// carry their id so `--integrity-ack <id>` can reference them.
    var reportText: String {
        var out = ["Persistence surface — \(flaggedCount) item(s) worth review"]
        for category in IntegrityCategory.allCases {
            let rows = items(in: category)
            guard !rows.isEmpty else { continue }
            out.append("")
            out.append("\(category.rawValue):")
            for item in rows {
                var line = "  [\(item.status.rawValue)] \(item.label) — \(item.detail)"
                if let m = item.lastModified {
                    let df = DateFormatter()
                    df.locale = Locale(identifier: "en_US_POSIX")
                    df.dateFormat = "yyyy-MM-dd HH:mm"
                    line += " (modified \(df.string(from: m)))"
                }
                if item.isFlagged { line += " · id:\(item.id)" }
                out.append(line)
            }
        }
        if flaggedCount > 0 {
            out.append("")
            out.append("After reviewing, silence a row until it changes again: Perch --integrity-ack <id>|all")
        }
        return out.joined(separator: "\n")
    }
}

/// Pure + injectable so the selftest can drive it over a fixture directory.
enum IntegrityScanner {
    /// How recent a modification has to be to be surfaced as "changed".
    static let recencyWindow: TimeInterval = 24 * 3600

    /// Project cwds of the live Claude sessions, read from the pid registry.
    /// The CLI (`--integrity-report`) has no live SessionStore, so it uses this
    /// to cover per-project CLAUDE.md/AGENTS.md/.mcp.json — matching what the
    /// notch panel shows for the same sessions.
    static func liveSessionProjectDirs(
        sessionsDir: URL = PerchPaths.claudeConfigDir.appendingPathComponent("sessions", isDirectory: true)
    ) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var cwds = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let cwd = (try? JSONValue(parsing: data))?["cwd"]?.string, !cwd.isEmpty else { continue }
            cwds.insert(cwd)
        }
        return cwds.map { URL(fileURLWithPath: $0) }
    }

    static func scan(claudeDir: URL = PerchPaths.claudeConfigDir,
                     codexDir: URL = PerchPaths.codexHomeDir,
                     home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                     bridgePath: String = PerchPaths.bridgeInstallPath.path,
                     projectDirs: [URL] = [],
                     now: Date = Date(),
                     recency: TimeInterval = IntegrityScanner.recencyWindow,
                     acks: [String: String] = [:]) -> IntegritySnapshot {
        var items: [IntegrityItem] = []
        items.append(contentsOf: agentConfigItems(claudeDir: claudeDir, codexDir: codexDir, home: home,
                                                   bridgePath: bridgePath, projectDirs: projectDirs,
                                                   now: now, recency: recency))
        items.append(contentsOf: memoryItems(claudeDir: claudeDir, codexDir: codexDir,
                                             projectDirs: projectDirs, now: now, recency: recency))
        items.append(contentsOf: persistenceItems(home: home, now: now, recency: recency))
        return IntegritySnapshot(items: items.map { applyAck($0, acks: acks) }, scannedAt: now)
    }

    /// An acknowledged fingerprint suppresses the review flag (never
    /// `unreadable` — an unreadable surface must stay visible). The row keeps
    /// its data and gains a "reviewed" marker; any content change produces a
    /// new fingerprint and the flag returns.
    private static func applyAck(_ item: IntegrityItem, acks: [String: String]) -> IntegrityItem {
        guard item.status == .nonPerch || item.status == .changedRecently,
              !item.fingerprint.isEmpty, acks[item.id] == item.fingerprint else { return item }
        return IntegrityItem(id: item.id, category: item.category, label: item.label,
                             detail: item.detail + " · reviewed", lastModified: item.lastModified,
                             status: .unchanged, fingerprint: item.fingerprint)
    }

    // MARK: - Category scans

    private static func agentConfigItems(claudeDir: URL, codexDir: URL, home: URL, bridgePath: String,
                                         projectDirs: [URL], now: Date, recency: TimeInterval) -> [IntegrityItem] {
        var out: [IntegrityItem] = []

        // Claude settings.json — the hook/statusLine surface. A hook command
        // Perch doesn't recognise as its own is where a config hijack hides.
        let settings = claudeDir.appendingPathComponent("settings.json")
        if let hooks = readHookSurface(settings, bridgePath: bridgePath) {
            let mtime = modDate(settings)
            // A hook OR a statusLine command Perch doesn't recognise is an
            // execute-on-every-run foothold — both raise the item to review.
            let unrecognised = hooks.nonPerchHooks > 0 || hooks.statusLine == "non-Perch"
            let status: IntegrityStatus = unrecognised ? .nonPerch
                : recentlyChanged(mtime, now: now, recency: recency) ? .changedRecently : .unchanged
            var detail = "\(hooks.totalHooks) hook command(s)"
            if hooks.nonPerchHooks > 0 { detail += " · \(hooks.nonPerchHooks) not from Perch" }
            detail += " · statusLine: \(hooks.statusLine)"
            // Fingerprint the hook SURFACE, not the file: acknowledging the
            // user's own hooks must survive unrelated settings churn
            // (permissions edits), while any new/changed foreign command
            // re-flags.
            out.append(IntegrityItem(id: "claude-settings", category: .agentConfig,
                                     label: "~/.claude/settings.json", detail: detail,
                                     lastModified: mtime, status: status,
                                     fingerprint: hooks.fingerprint))
        } else {
            out.append(IntegrityItem(id: "claude-settings", category: .agentConfig,
                                     label: "~/.claude/settings.json", detail: "not present",
                                     lastModified: nil, status: .absent))
        }

        out.append(contentsOf: fileItem(claudeDir.appendingPathComponent("settings.local.json"),
                                         id: "claude-settings-local", label: "~/.claude/settings.local.json",
                                         category: .agentConfig, now: now, recency: recency, optional: true))

        // Codex hooks.json gets the same ownership check as Claude's
        // settings: a file that holds only Perch's own bridge hooks is
        // Perch's own write — flagging it as "changed recently" would make
        // the installer trip its own alarm. Any non-bridge command is the
        // foothold this page exists to show.
        out.append(contentsOf: codexHooksItem(codexDir.appendingPathComponent("hooks.json"),
                                              bridgePath: bridgePath, now: now, recency: recency))

        // Codex config.toml is rewritten routinely by Codex itself, so its
        // fingerprint covers only the keys an attacker would touch
        // (approval/sandbox/notify/trust/MCP) — service-tier churn doesn't
        // re-flag, a new notify hook or trusted dir does.
        out.append(contentsOf: codexConfigItem(codexDir.appendingPathComponent("config.toml"),
                                               now: now, recency: recency))

        // MCP servers: each entry is a process the agent auto-launches — a
        // prime hijack/persistence vector. Count global + per-project entries
        // in ~/.claude.json plus any project-level .mcp.json files. The
        // ~/.claude.json file itself is rewritten every session, so recency
        // is keyed to the SERVER SET (via ack fingerprint), never to mtime.
        if let servers = mcpServerNames(home.appendingPathComponent(".claude.json"),
                                        projectDirs: projectDirs) {
            let f = home.appendingPathComponent(".claude.json")
            out.append(IntegrityItem(id: "mcp-servers", category: .agentConfig,
                                     label: "MCP servers (~/.claude.json)",
                                     detail: servers.isEmpty ? "none configured"
                                        : "\(servers.count) server(s) auto-launched",
                                     lastModified: modDate(f),
                                     status: servers.isEmpty ? .absent : .unchanged,
                                     fingerprint: sha("mcp\n" + servers.sorted().joined(separator: "\n"))))
        }

        // Directories that run code at the agent's request. Plugins are
        // judged by the installed set (installed_plugins.json), not directory
        // mtime — marketplace auto-refresh used to keep the row orange forever.
        out.append(pluginsItem(claudeDir.appendingPathComponent("plugins"), now: now, recency: recency))
        out.append(dirItem(claudeDir.appendingPathComponent("skills"), id: "claude-skills",
                           label: "~/.claude/skills", noun: "skill", category: .agentConfig,
                           now: now, recency: recency))
        out.append(dirItem(claudeDir.appendingPathComponent("commands"), id: "claude-commands",
                           label: "~/.claude/commands", noun: "command", category: .agentConfig,
                           now: now, recency: recency))
        return out
    }

    private static func memoryItems(claudeDir: URL, codexDir: URL, projectDirs: [URL],
                                    now: Date, recency: TimeInterval) -> [IntegrityItem] {
        var out: [IntegrityItem] = []
        out.append(contentsOf: fileItem(claudeDir.appendingPathComponent("CLAUDE.md"),
                                         id: "claude-md-global", label: "~/.claude/CLAUDE.md",
                                         category: .memory, now: now, recency: recency, optional: true))
        out.append(dirItem(claudeDir.appendingPathComponent("memory"), id: "claude-memory",
                           label: "~/.claude/memory", noun: "memory file", category: .memory,
                           now: now, recency: recency))

        // Per-project instruction files (CLAUDE.md / AGENTS.md) across the
        // sessions Perch currently knows about — the real poison target.
        var found: [(path: String, mtime: Date)] = []
        for dir in projectDirs {
            for name in ["CLAUDE.md", "AGENTS.md"] {
                let f = dir.appendingPathComponent(name)
                guard let m = modDate(f) else { continue }
                found.append((f.path, m))
            }
        }
        if !found.isEmpty {
            let latest = found.max { $0.mtime < $1.mtime }!
            let status: IntegrityStatus = recentlyChanged(latest.mtime, now: now, recency: recency)
                ? .changedRecently : .unchanged
            // Name the file that moved — "3 across active projects" alone
            // gave nothing to review.
            let short = latest.path.split(separator: "/").suffix(2).joined(separator: "/")
            out.append(IntegrityItem(id: "project-instructions", category: .memory,
                                     label: "Project CLAUDE.md / AGENTS.md",
                                     detail: "\(found.count) across active projects · latest: \(short)",
                                     lastModified: latest.mtime, status: status,
                                     fingerprint: sha(found.map { "\($0.path)@\($0.mtime.timeIntervalSince1970)" }
                                        .sorted().joined(separator: "\n"))))
        }
        return out
    }

    private static func persistenceItems(home: URL, now: Date, recency: TimeInterval) -> [IntegrityItem] {
        var out: [IntegrityItem] = []
        out.append(launchAgentsItem(home.appendingPathComponent("Library/LaunchAgents"),
                                    now: now, recency: recency))

        // Shell profiles — the classic "runs on every new shell" foothold.
        let profiles = [".zshrc", ".bashrc", ".bash_profile", ".profile", ".zprofile"]
            .map { home.appendingPathComponent($0) }
        let present = profiles.compactMap { url -> (String, Date)? in
            guard let m = modDate(url) else { return nil }
            return (url.lastPathComponent, m)
        }
        if present.isEmpty {
            out.append(IntegrityItem(id: "shell-profiles", category: .persistence,
                                     label: "Shell profiles", detail: "none present",
                                     lastModified: nil, status: .absent))
        } else {
            let latest = present.map(\.1).max()
            let status: IntegrityStatus = recentlyChanged(latest, now: now, recency: recency)
                ? .changedRecently : .unchanged
            out.append(IntegrityItem(id: "shell-profiles", category: .persistence,
                                     label: "Shell profiles", detail: "\(present.count) present",
                                     lastModified: latest, status: status,
                                     fingerprint: sha(present.map { "\($0.0)@\($0.1.timeIntervalSince1970)" }
                                        .sorted().joined(separator: "\n"))))
        }
        return out
    }

    // MARK: - Surface-specific items

    /// ~/.codex/hooks.json shares the shape of Claude's hooks block. All
    /// commands recognised as the deployed bridge → Perch's own install,
    /// nothing to review; anything else → the same nonPerch amber as
    /// settings.json (this file used to get only an mtime check, so Perch
    /// flagged its own installer and would have missed an injected command).
    private static func codexHooksItem(_ url: URL, bridgePath: String,
                                       now: Date, recency: TimeInterval) -> [IntegrityItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] } // optional surface
        guard let surface = readHookSurface(url, bridgePath: bridgePath) else {
            return [IntegrityItem(id: "codex-hooks", category: .agentConfig, label: "~/.codex/hooks.json",
                                  detail: "present, unreadable", lastModified: nil, status: .unreadable)]
        }
        let mtime = modDate(url)
        let status: IntegrityStatus
        let detail: String
        if surface.nonPerchHooks > 0 {
            status = .nonPerch
            detail = "\(surface.totalHooks) hook command(s) · \(surface.nonPerchHooks) not from Perch"
        } else {
            status = .unchanged
            detail = "\(surface.totalHooks) hook command(s) · all Perch"
        }
        return [IntegrityItem(id: "codex-hooks", category: .agentConfig, label: "~/.codex/hooks.json",
                              detail: detail, lastModified: mtime, status: status,
                              fingerprint: surface.fingerprint)]
    }

    /// Keys in config.toml an attacker would touch; anything else (model,
    /// service tier, UI prefs) is routine Codex churn.
    private static let codexSensitiveKeys = ["approval_policy", "sandbox_mode", "notify",
                                             "approvals_reviewer", "trust_level", "mcp_servers",
                                             "model_providers", "hooks"]

    private static func codexConfigItem(_ url: URL, now: Date, recency: TimeInterval) -> [IntegrityItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] } // optional surface
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return [IntegrityItem(id: "codex-config", category: .agentConfig, label: "~/.codex/config.toml",
                                  detail: "present, unreadable", lastModified: nil, status: .unreadable)]
        }
        let mtime = modDate(url)
        let sensitive = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in codexSensitiveKeys.contains { line.hasPrefix($0) } || line.hasPrefix("[") }
        let status: IntegrityStatus = recentlyChanged(mtime, now: now, recency: recency)
            ? .changedRecently : .unchanged
        return [IntegrityItem(id: "codex-config", category: .agentConfig, label: "~/.codex/config.toml",
                              detail: "present", lastModified: mtime, status: status,
                              fingerprint: sha("codex-config\n" + sensitive.joined(separator: "\n")))]
    }

    /// Plugins judged by the installed set: name@version+sha from
    /// installed_plugins.json. Marketplace refresh files and cache churn no
    /// longer count as change; a new/updated plugin does.
    private static func pluginsItem(_ dir: URL, now: Date, recency: TimeInterval) -> IntegrityItem {
        let manifest = dir.appendingPathComponent("installed_plugins.json")
        guard let data = try? Data(contentsOf: manifest),
              let plugins = (try? JSONValue(parsing: data))?["plugins"]?.objectValue else {
            // No manifest — fall back to the plain directory view.
            return dirItem(dir, id: "claude-plugins", label: "~/.claude/plugins", noun: "plugin",
                           category: .agentConfig, now: now, recency: recency)
        }
        var identity: [String] = []
        for (name, installs) in plugins {
            for install in installs.arrayValue ?? [] {
                let sha = install["gitCommitSha"]?.string ?? install["version"]?.string ?? "?"
                identity.append("\(name)@\(sha)")
            }
        }
        let mtime = modDate(manifest)
        let status: IntegrityStatus = plugins.isEmpty ? .absent
            : recentlyChanged(mtime, now: now, recency: recency) ? .changedRecently : .unchanged
        let plural = plugins.count == 1 ? "plugin" : "plugins"
        return IntegrityItem(id: "claude-plugins", category: .agentConfig, label: "~/.claude/plugins",
                             detail: plugins.isEmpty ? "none installed" : "\(plugins.count) \(plural) installed",
                             lastModified: mtime, status: status,
                             fingerprint: sha("plugins\n" + identity.sorted().joined(separator: "\n")))
    }

    /// LaunchAgents counted from active *.plist files only — a
    /// com.foo.plist.disabled is not an autostart, and lumping it in both
    /// inflated the count and hid which entries actually run.
    private static func launchAgentsItem(_ dir: URL, now: Date, recency: TimeInterval) -> IntegrityItem {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return IntegrityItem(id: "launchagents", category: .persistence,
                                 label: "~/Library/LaunchAgents", detail: "none",
                                 lastModified: nil, status: .absent)
        }
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            return IntegrityItem(id: "launchagents", category: .persistence,
                                 label: "~/Library/LaunchAgents", detail: "present, unreadable",
                                 lastModified: nil, status: .unreadable)
        }
        let active = entries.filter { $0.pathExtension == "plist" }
        let disabled = entries.count - active.count
        guard !active.isEmpty else {
            return IntegrityItem(id: "launchagents", category: .persistence,
                                 label: "~/Library/LaunchAgents",
                                 detail: disabled > 0 ? "none active · \(disabled) disabled" : "empty",
                                 lastModified: nil, status: .absent)
        }
        let latest = active.compactMap { modDate($0) }.max()
        let status: IntegrityStatus = recentlyChanged(latest, now: now, recency: recency)
            ? .changedRecently : .unchanged
        var detail = "\(active.count) agent\(active.count == 1 ? "" : "s")"
        if disabled > 0 { detail += " · \(disabled) disabled" }
        let identity = active.map { "\($0.lastPathComponent)@\(modDate($0)?.timeIntervalSince1970 ?? 0)" }
        return IntegrityItem(id: "launchagents", category: .persistence,
                             label: "~/Library/LaunchAgents", detail: detail,
                             lastModified: latest, status: status,
                             fingerprint: sha("launchagents\n" + identity.sorted().joined(separator: "\n")))
    }

    // MARK: - Building blocks

    struct HookSurface {
        var totalHooks: Int
        var nonPerchHooks: Int
        var statusLine: String  // "Perch" | "non-Perch" | "none"
        /// Identity of everything foreign on this surface — acknowledging it
        /// survives Perch's own hook churn but not a new outside command.
        var fingerprint: String
    }

    /// A command is one of Perch's own iff it invokes the real deployed bridge
    /// as a whole shell token — not merely as a substring. This defeats the
    /// `/tmp/perch-bridge-fake` naming trick: the bridge path must be followed
    /// by a token boundary (quote, whitespace, or end of string).
    static func invokesPerchBridge(_ command: String, bridgePath: String) -> Bool {
        guard !bridgePath.isEmpty else { return false }
        var searchStart = command.startIndex
        while let range = command.range(of: bridgePath, range: searchStart..<command.endIndex) {
            if range.upperBound == command.endIndex { return true }
            let next = command[range.upperBound]
            if next == "\"" || next == "'" || next == " " || next == "\t" { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// Parses a settings-style hook surface (Claude settings.json or Codex
    /// hooks.json). Returns nil if the file is absent or unparseable (caller
    /// renders absent/unreadable).
    static func readHookSurface(_ url: URL, bridgePath: String) -> HookSurface? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONValue(parsing: data).objectValue else { return nil }
        var total = 0, nonPerch = 0
        var foreign: [String] = []
        if let hooks = root["hooks"]?.objectValue {
            for (event, matchers) in hooks {
                for matcher in matchers.arrayValue ?? [] {
                    for entry in matcher["hooks"]?.arrayValue ?? [] {
                        guard let cmd = entry["command"]?.string else { continue }
                        total += 1
                        if !invokesPerchBridge(cmd, bridgePath: bridgePath) {
                            nonPerch += 1
                            foreign.append("\(event):\(cmd)")
                        }
                    }
                }
            }
        }
        let statusLine: String
        if let sl = root["statusLine"], !sl.isNull {
            let cmd = sl["command"]?.string ?? ""
            if invokesPerchBridge(cmd, bridgePath: bridgePath) {
                statusLine = "Perch"
            } else {
                statusLine = "non-Perch"
                foreign.append("statusLine:\(cmd)")
            }
        } else {
            statusLine = "none"
        }
        return HookSurface(totalHooks: total, nonPerchHooks: nonPerch, statusLine: statusLine,
                           fingerprint: sha("hooks\n" + foreign.sorted().joined(separator: "\n")))
    }

    /// Names of configured MCP servers — each an auto-launched process.
    /// Collects the global `mcpServers`, every `projects[*].mcpServers` in
    /// ~/.claude.json, and any per-project `.mcp.json`. nil only if the
    /// ~/.claude.json file is absent/unparseable (caller omits the row).
    private static func mcpServerNames(_ url: URL, projectDirs: [URL]) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONValue(parsing: data).objectValue else { return nil }
        var names: [String] = (root["mcpServers"]?.objectValue?.keys).map(Array.init) ?? []
        if let projects = root["projects"]?.objectValue {
            for (path, project) in projects {
                for name in (project["mcpServers"]?.objectValue ?? [:]).keys {
                    names.append("\(path):\(name)")
                }
            }
        }
        for dir in projectDirs {
            if let d = try? Data(contentsOf: dir.appendingPathComponent(".mcp.json")),
               let obj = try? JSONValue(parsing: d).objectValue {
                for name in (obj["mcpServers"]?.objectValue ?? [:]).keys {
                    names.append("\(dir.path):\(name)")
                }
            }
        }
        return names
    }

    private static func fileItem(_ url: URL, id: String, label: String, category: IntegrityCategory,
                                 now: Date, recency: TimeInterval, optional: Bool) -> [IntegrityItem] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        // Probe existence separately from stat: a file that exists but can't
        // be stat'd (permission-denied, dangling symlink) must not be reported
        // as absent — that would hide a real foothold.
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return optional ? [] : [IntegrityItem(id: id, category: category, label: label,
                                                  detail: "not present", lastModified: nil, status: .absent)]
        }
        guard let mtime = modDate(url) else {
            return [IntegrityItem(id: id, category: category, label: label,
                                  detail: "present, unreadable", lastModified: nil, status: .unreadable)]
        }
        let status: IntegrityStatus = recentlyChanged(mtime, now: now, recency: recency) ? .changedRecently : .unchanged
        let content = try? Data(contentsOf: url)
        return [IntegrityItem(id: id, category: category, label: label, detail: "present",
                              lastModified: mtime, status: status,
                              fingerprint: content.map { sha($0) } ?? "mtime:\(mtime.timeIntervalSince1970)")]
    }

    private static func dirItem(_ url: URL, id: String, label: String, noun: String,
                                category: IntegrityCategory, now: Date, recency: TimeInterval) -> IntegrityItem {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        guard exists else {
            return IntegrityItem(id: id, category: category, label: label,
                                 detail: "none", lastModified: nil, status: .absent)
        }
        // The directory exists — distinguish "genuinely empty" from "present
        // but Perch can't read it" so an unreadable dir never reads as a clean
        // all-clear (no-false-verdicts invariant).
        guard let entries = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            return IntegrityItem(id: id, category: category, label: label,
                                 detail: "present, unreadable", lastModified: nil, status: .unreadable)
        }
        if entries.isEmpty {
            return IntegrityItem(id: id, category: category, label: label,
                                 detail: "empty", lastModified: nil, status: .absent)
        }
        let latest = entries.compactMap { modDate($0) }.max()
        let status: IntegrityStatus = recentlyChanged(latest, now: now, recency: recency) ? .changedRecently : .unchanged
        let plural = entries.count == 1 ? noun : noun + "s"
        let identity = entries.map { "\($0.lastPathComponent)@\(modDate($0)?.timeIntervalSince1970 ?? 0)" }
        return IntegrityItem(id: id, category: category, label: label,
                             detail: "\(entries.count) \(plural)", lastModified: latest, status: status,
                             fingerprint: sha("dir\n" + identity.sorted().joined(separator: "\n")))
    }

    private static func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func recentlyChanged(_ date: Date?, now: Date, recency: TimeInterval) -> Bool {
        guard let date else { return false }
        let age = now.timeIntervalSince(date)
        // Strict `<` so the boundary matches IntegrityView.age()'s day bucket
        // (`s < 86_400`): a file exactly `recency` old reads "1d ago" and is
        // NOT flagged, never orange-"recent" with a "1d ago" label.
        return age >= 0 && age < recency
    }

    private static func sha(_ text: String) -> String { sha(Data(text.utf8)) }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
