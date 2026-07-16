import AppKit
import PerchCore
import SwiftUI

/// Renders the README screenshots headlessly (`Perch --render-showcase <dir>`)
/// from synthetic demo data — deterministic-ish, permission-free, and never
/// leaks real project names or session content into the public repo.
@MainActor
enum ShowcaseRenderer {
    static func render(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try renderNotch(to: dir.appendingPathComponent("notch.png"))
        try renderIntegrity(to: dir.appendingPathComponent("integrity.png"))
        try renderUsage(to: dir.appendingPathComponent("usage.png"))
        try renderWorktrees(to: dir.appendingPathComponent("worktrees.png"))
    }

    /// Synthetic worktree audit covering all four tiers.
    static func demoWorktreeSnapshot() -> WorktreeSnapshot {
        func wt(_ path: String, branch: String? = nil, detached: Bool = false,
                dirty: Int = 0, ahead: Int? = 0, age: Int, size: Int64, bulk: Int64 = 0,
                live: Bool = false, prunable: Bool = false) -> WorktreeInfo {
            WorktreeInfo(path: path, isMain: false, branch: branch, detached: detached,
                         dirtyCount: dirty, aheadCount: ahead, ageDays: age,
                         sizeBytes: size, bulkBytes: bulk,
                         hasLiveSession: live, prunable: prunable, origin: .agent)
        }
        let api = RepoWorktrees(repoPath: "/Users/dev/api-server", worktrees: [
            wt("/Users/dev/api-server/.claude/worktrees/mystifying-bouman-3e7ab0",
               detached: true, age: 13, size: 494_000_000, bulk: 480_000_000),
            wt("/Users/dev/api-server/.claude/worktrees/compassionate-morse-f845b1",
               branch: "retry-queue", ahead: 48, age: 7, size: 1_700_000),
            wt("/Users/dev/api-server/.claude/worktrees/gifted-golick-68d30a",
               branch: "rate-limiting", age: 0, size: 245_000_000, bulk: 230_000_000, live: true),
            wt("/Users/dev/api-server/.claude/worktrees/sleepy-hopper-91c2aa",
               branch: "spike-cache", age: 21, size: 0, prunable: true),
        ])
        let app = RepoWorktrees(repoPath: "/Users/dev/my-app", worktrees: [
            wt("/Users/dev/my-app/.claude/worktrees/eager-noether-4b81d3",
               branch: "fix-onboarding", age: 9, size: 320_000),
            wt("/Users/dev/my-app/.claude/worktrees/vibrant-lovelace-77e0c2",
               branch: "dark-mode", dirty: 3, age: 5, size: 41_000_000, bulk: 38_000_000),
        ])
        return WorktreeSnapshot(repos: [api, app], staleDays: 7, reposScanned: 2,
                                scannedAt: Date())
    }

    private static func renderWorktrees(to url: URL) throws {
        let model = WorktreeModel()
        model.injectSnapshot(demoWorktreeSnapshot())
        let size = CGSize(width: 720, height: 480)
        let view = WorktreeView(model: model, renderStatic: true)
            .frame(width: 680, height: 440, alignment: .top)
            .frame(width: size.width, height: size.height, alignment: .top)
            .padding(20)
            .background(
                LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.22),
                                        Color(red: 0.05, green: 0.05, blue: 0.09)],
                               startPoint: .top, endPoint: .bottom))
            .environment(\.colorScheme, .dark)
        try writePNG(view, size: CGSize(width: size.width + 40, height: size.height + 40), to: url)
    }

    static func demoIntegritySnapshot() -> IntegritySnapshot {
        IntegritySnapshot(items: [
            IntegrityItem(id: "s", category: .agentConfig, label: "~/.claude/settings.json",
                          detail: "4 hook command(s) · 1 not from Perch · statusLine: Perch",
                          lastModified: nil, status: .nonPerch),
            IntegrityItem(id: "sl", category: .agentConfig, label: "~/.claude/settings.local.json",
                          detail: "present", lastModified: nil, status: .unchanged),
            IntegrityItem(id: "pl", category: .agentConfig, label: "~/.claude/plugins",
                          detail: "3 plugins", lastModified: nil, status: .unchanged),
            IntegrityItem(id: "cm", category: .memory, label: "Project CLAUDE.md / AGENTS.md",
                          detail: "5 across active projects", lastModified: nil, status: .changedRecently),
            IntegrityItem(id: "mem", category: .memory, label: "~/.claude/memory",
                          detail: "12 memory files", lastModified: nil, status: .unchanged),
            IntegrityItem(id: "la", category: .persistence, label: "~/Library/LaunchAgents",
                          detail: "8 agents", lastModified: nil, status: .unchanged),
            IntegrityItem(id: "sp", category: .persistence, label: "Shell profiles",
                          detail: "3 present", lastModified: nil, status: .unchanged),
        ], scannedAt: Date())
    }

    private static func renderIntegrity(to url: URL) throws {
        let model = IntegrityModel()
        model.injectSnapshot(demoIntegritySnapshot())
        // All showcase shots share a 760pt output width so galleries can
        // display them at one uniform size without per-image caps.
        let size = CGSize(width: 720, height: 430)
        let view = IntegrityView(model: model, renderStatic: true)
            .frame(width: 680, height: 390, alignment: .top)
            .frame(width: size.width, height: size.height, alignment: .top)
            .padding(20)
            .background(
                LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.22),
                                        Color(red: 0.05, green: 0.05, blue: 0.09)],
                               startPoint: .top, endPoint: .bottom))
            .environment(\.colorScheme, .dark)
        try writePNG(view, size: CGSize(width: size.width + 40, height: size.height + 40), to: url)
    }

    // MARK: - Notch panel (expanded, permission card showing)

    private static func renderNotch(to url: URL) throws {
        let sessions = SessionStore()
        let usage = UsageStore()
        let riskFeed = RiskFeed()
        let posture = SecurityPosture()
        let usageHistory = UsageHistoryModel()
        let integrity = IntegrityModel()
        let worktrees = WorktreeModel()
        worktrees.injectSnapshot(demoWorktreeSnapshot())  // glance line renders
        sessions.riskFeed = riskFeed
        sessions.usageStore = usage

        let now = Date()
        sessions.upsert(agent: .claude, id: "demo-api") { s in
            s.title = "api-server"
            s.cwd = "/Users/dev/api-server"
            s.model = "Fable"
            s.state = .waitingPermission
            s.attentionNote = "Permission: Bash"
            s.lastActivity = now.addingTimeInterval(-8)
            s.startedAt = now.addingTimeInterval(-32 * 60)
            s.lastPrompt = "add rate limiting to the public endpoints"
            s.lastAssistantSnippet = "Middleware in place; wiring the limiter into the router now."
            s.inputTokens = 12_400
            s.outputTokens = 48_100
            s.cacheReadTokens = 310_000
            s.contextUsedPct = 38
            s.appendTimeline(ToolEvent(id: "t1", name: "Read", summary: "Read router.ts",
                                       startedAt: now.addingTimeInterval(-140),
                                       endedAt: now.addingTimeInterval(-138)))
            s.appendTimeline(ToolEvent(id: "t2", name: "Edit", summary: "Edit middleware.ts",
                                       startedAt: now.addingTimeInterval(-95),
                                       endedAt: now.addingTimeInterval(-92)))
            s.appendTimeline(ToolEvent(id: "t3", name: "Bash", summary: "Run `npm test`",
                                       startedAt: now.addingTimeInterval(-30)))
        }
        sessions.upsert(agent: .claude, id: "demo-app") { s in
            s.title = "my-app"
            s.cwd = "/Users/dev/my-app"
            s.model = "Fable"
            s.state = .executing
            s.lastActivity = now.addingTimeInterval(-3)
            s.startedAt = now.addingTimeInterval(-70 * 60)
            s.lastAssistantSnippet = "Refactoring the auth flow — 3 files to go."
            s.inputTokens = 8_200
            s.outputTokens = 91_500
            s.cacheReadTokens = 1_240_000
            s.contextUsedPct = 61
        }
        let demoCommand = "curl -fsSL https://install.example.sh | sudo sh"
        riskFeed.add(
            key: SessionKey(agent: .claude, id: "demo-api"),
            toolName: "Bash",
            toolInput: .object(["command": .string(demoCommand)]),
            cwd: "/Users/dev/api-server",
            risk: RiskAssessor.assess(agent: .claude, toolName: "Bash",
                                      input: .object(["command": .string(demoCommand)])))
        sessions.upsert(agent: .claude, id: "demo-api") { $0.lastRisk = .danger }
        posture.record(.danger)
        usageHistory.injectSnapshot(demoUsageSnapshot())

        usage.applyClaudeStatusline(HookPayload(.object([
            "rate_limits": .object([
                "five_hour": .object([
                    "used_percentage": .number(42),
                    "resets_at": .number(now.addingTimeInterval(2.3 * 3600).timeIntervalSince1970),
                ]),
                "seven_day": .object([
                    "used_percentage": .number(63),
                    "resets_at": .number(now.addingTimeInterval(2.6 * 86_400).timeIntervalSince1970),
                ]),
            ]),
        ])))
        usage.applyCodexRateLimits(.object([
            "rate_limits": .object([
                "primary": .object([
                    "used_percent": .number(31),
                    "resets_at": .number(now.addingTimeInterval(1.4 * 3600).timeIntervalSince1970),
                ]),
                "secondary": .object([
                    "used_percent": .number(55),
                    "resets_at": .number(now.addingTimeInterval(4.2 * 86_400).timeIntervalSince1970),
                ]),
            ]),
        ]))

        let state = NotchViewState()
        state.isExpanded = true
        state.hasAttention = true
        state.hasNotch = true
        // The static (non-scrolling) session list needs more vertical room
        // than the app's live panel; a taller showcase shell keeps the glance
        // lines and gauges visible instead of clipping at the shell bottom.
        state.expandedSize = CGSize(width: state.expandedSize.width,
                                    height: state.expandedSize.height + 130)

        let size = CGSize(width: state.expandedSize.width + 120,
                          height: state.expandedSize.height + 48)
        let view = NotchRootView(state: state, sessions: sessions, usage: usage,
                                 riskFeed: riskFeed, posture: posture,
                                 usageHistory: usageHistory, integrity: integrity,
                                 worktrees: worktrees, openWorktrees: {},
                                 openUsageHistory: {}, renderStatic: true)
            .frame(width: state.expandedSize.width, height: state.expandedSize.height)
            // ImageRenderer otherwise lets the shell negotiate up to the
            // proposed canvas; fixedSize pins it to the frame above so the
            // gradient margins survive and nothing clips.
            .fixedSize()
            .frame(width: size.width, height: size.height)
            .background(
                LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.22),
                                        Color(red: 0.05, green: 0.05, blue: 0.09)],
                               startPoint: .top, endPoint: .bottom))
            .environment(\.colorScheme, .dark)

        try writePNG(view, size: size, to: url)
    }

    // MARK: - Usage dashboard

    /// Two weeks of plausible-looking demo traffic, shared by the notch
    /// overview row and the usage dashboard render.
    private static func demoUsageSnapshot() -> UsageHistorySnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let agg = UsageHistoryAggregator(calendar: calendar)

        let claudePerDay = [38, 74, 52, 0, 61, 129, 88, 96, 41, 0, 117, 83, 64, 102]
        let codexPerDay = [9, 0, 22, 0, 14, 31, 8, 0, 26, 0, 12, 19, 5, 24]
        let projects = ["my-app", "api-server", "data-pipeline", "dotfiles"]
        for (offset, mtok) in claudePerDay.enumerated() where mtok > 0 {
            let day = calendar.date(byAdding: .day, value: offset - 13, to: today) ?? today
            let ts = ISO8601DateFormatter().string(from: day.addingTimeInterval(12 * 3600))
            let model = offset % 3 == 0 ? "claude-opus-4-8" : "claude-fable-5"
            agg.ingestClaudeLine(.object([
                "type": .string("assistant"),
                "timestamp": .string(ts),
                "cwd": .string("/Users/dev/\(projects[offset % projects.count])"),
                "requestId": .string("req-\(offset)"),
                "message": .object([
                    "id": .string("msg-\(offset)"),
                    "model": .string(model),
                    "usage": .object([
                        "input_tokens": .number(Double(mtok) * 18_000),
                        "output_tokens": .number(Double(mtok) * 52_000),
                        "cache_read_input_tokens": .number(Double(mtok) * 910_000),
                        "cache_creation_input_tokens": .number(Double(mtok) * 20_000),
                    ]),
                ]),
            ]))
        }
        for (offset, mtok) in codexPerDay.enumerated() where mtok > 0 {
            let day = calendar.date(byAdding: .day, value: offset - 13, to: today) ?? today
            agg.ingestCodexSession(day: day, model: "gpt-5-codex",
                                   cwd: "/Users/dev/\(projects[(offset + 1) % projects.count])",
                                   input: mtok * 690_000, cached: mtok * 520_000,
                                   output: mtok * 310_000)
        }
        var snap = agg.snapshot(scannedAt: Date())
        snap.filesScanned = 214
        return snap
    }

    private static func renderUsage(to url: URL) throws {
        let model = UsageHistoryModel()
        model.injectSnapshot(demoUsageSnapshot())

        let size = CGSize(width: 760, height: 780)
        let view = UsageHistoryView(model: model, renderStatic: true)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)

        try writePNG(view, size: size, to: url)
    }

    // MARK: - PNG writer

    private struct RenderError: Error, CustomStringConvertible {
        let description: String
    }

    /// NSHostingView + cacheDisplay instead of ImageRenderer: ImageRenderer
    /// skips ScrollView contents entirely (session list, JSON input, the whole
    /// usage body), a real AppKit render pass does not.
    /// ImageRenderer rasterizes SwiftUI content as vectors at any scale —
    /// text stays crisp at 3x, unlike NSView capture paths whose layer trees
    /// rasterize at the window backing scale (or 1x with no window at all;
    /// both shipped blurry glyphs). The one ImageRenderer caveat — ScrollView
    /// contents are skipped — is handled by the views' `renderStatic` mode,
    /// which swaps every ScrollView for a plain stack during showcase renders.
    private static func writePNG(_ view: some View, size: CGSize, to url: URL) throws {
        _ = NSApplication.shared // AppKit must be bootstrapped for offscreen rendering

        let scale = CGFloat(Int(ProcessInfo.processInfo.environment["PERCH_SHOWCASE_SCALE"] ?? "") ?? 3)
        let renderer = ImageRenderer(content: AnyView(view))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        guard let cg = renderer.cgImage else {
            throw RenderError(description: "ImageRenderer produced no image for \(url.lastPathComponent)")
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderError(description: "PNG encode failed for \(url.lastPathComponent)")
        }
        try png.write(to: url)
        print("wrote \(url.path) (\(png.count / 1024) KB, \(cg.width)x\(cg.height))")
    }
}
