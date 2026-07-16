import AppKit
import PerchCore

// Headless maintenance commands (usable from Terminal without UI).
let cliArgs = Array(CommandLine.arguments.dropFirst())

func runInstaller(_ label: String, _ body: () throws -> InstallReport) -> Never {
    do {
        let report = try body()
        print(report.summaryText)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(label) failed: \(error)\n".utf8))
        exit(1)
    }
}

/// Hook commands (and the Claude statusline) point at
/// PerchPaths.bridgeInstallPath, but BridgeDeployer normally runs only on app
/// launch. Deploy the bridge before registering anything so a headless install
/// on a fresh machine never leaves hooks pointing at a nonexistent binary. If
/// this executable has no bridge to deploy, accept an already-deployed one;
/// otherwise refuse the install (nothing is registered, agents stay untouched).
func ensureBridgeDeployedForInstall() throws {
    do {
        try BridgeDeployer.deploy()
    } catch {
        if FileManager.default.isExecutableFile(atPath: PerchPaths.bridgeInstallPath.path) {
            return // an earlier deploy left a usable bridge in place
        }
        throw error
    }
}

if let command = cliArgs.first {
    switch command {
    case "--doctor":
        print(Doctor.report())
        exit(0)
    case "--usage-report":
        print(UsageHistoryScanner.scan(daysBack: 30).reportText)
        exit(0)
    case "--worktree-report":
        // Headless has no live SessionStore; read live cwds from Claude's pid
        // registry AND recent Codex rollouts (Codex has no registry) so the
        // `active` tier still recognises running sessions of both agents.
        let cfg = PerchConfig.load()
        let live = Set(IntegrityScanner.liveSessionProjectDirs().map(\.path))
            .union(WorktreeScanner.codexLiveCwds())
        let base = WorktreeScanner.scan(liveCwds: live, staleDays: cfg.worktreeStaleDays)
        print(WorktreeScanner.computeSizes(base).reportText)
        exit(0)
    case "--integrity-report":
        print(IntegrityScanner.scan(projectDirs: IntegrityScanner.liveSessionProjectDirs(),
                                    acks: IntegrityBaseline.load().acks).reportText)
        exit(0)
    case "--integrity-ack":
        // Record "reviewed at this state" for flagged items; the flag returns
        // when the surface actually changes (fingerprint mismatch).
        let target = cliArgs.count > 1 ? cliArgs[1] : "all"
        let snap = IntegrityScanner.scan(projectDirs: IntegrityScanner.liveSessionProjectDirs(),
                                         acks: IntegrityBaseline.load().acks)
        let flagged = snap.items.filter { ($0.status == .nonPerch || $0.status == .changedRecently)
            && !$0.fingerprint.isEmpty }
        let chosen = target == "all" ? flagged : flagged.filter { $0.id == target }
        if chosen.isEmpty {
            print(target == "all" ? "Nothing flagged to acknowledge."
                : "No flagged item with id '\(target)' — run --integrity-report for ids.")
            exit(0)
        }
        var baseline = IntegrityBaseline.load()
        for item in chosen { baseline.acks[item.id] = item.fingerprint }
        do {
            try baseline.save()
        } catch {
            FileHandle.standardError.write(Data("integrity-ack failed: \(error)\n".utf8))
            exit(1)
        }
        print("Acknowledged \(chosen.count) item(s): \(chosen.map(\.id).joined(separator: ", "))")
        print("Each stays quiet until it changes again.")
        exit(0)
    case "--render-showcase":
        let dir = URL(fileURLWithPath: cliArgs.count > 1 ? cliArgs[1] : "docs/img", isDirectory: true)
        do {
            try MainActor.assumeIsolated { try ShowcaseRenderer.render(to: dir) }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render-showcase failed: \(error)\n".utf8))
            exit(1)
        }
    case "--install-claude-hooks":
        runInstaller("Claude hook install") {
            try ensureBridgeDeployedForInstall()
            return try ClaudeHookInstaller.install()
        }
    case "--uninstall-claude-hooks":
        runInstaller("Claude hook uninstall") { try ClaudeHookInstaller.uninstall() }
    case "--install-codex-hooks":
        runInstaller("Codex hook install") {
            try ensureBridgeDeployedForInstall()
            var report = try CodexHookInstaller.install()
            report.notes += CodexHookTrust.ensureTrusted()
            return report
        }
    case "--uninstall-codex-hooks":
        runInstaller("Codex hook uninstall") { try CodexHookInstaller.uninstall() }
    case "--trust-codex-hooks":
        // Re-trust after a hook-config change (the trust hash binds the
        // registered command/timeout) without rewriting hooks.json.
        print(CodexHookTrust.ensureTrusted().joined(separator: "\n"))
        exit(0)
    case "--version":
        print("Perch \(AppVersion.string)")
        exit(0)
    case "--selftest":
        exit(Int32(min(MainActor.assumeIsolated { Selftest.run() }, 125)))
    case "--help", "-h":
        print("""
        Perch — notch monitor for Claude Code and Codex sessions.

        Usage: Perch [command]
          (no command)              run the app
          --version                 print the app version
          --doctor                  print integration status
          --usage-report            print 30-day token usage from transcripts/rollouts
          --worktree-report         print the cross-project stale-worktree audit (read-only)
          --integrity-report        print the current persistence-surface scan
          --integrity-ack [id|all]  mark flagged surface items as reviewed (re-flags on change)
          --selftest                run the built-in test suite
          --install-claude-hooks    register Perch hooks + statusline in ~/.claude/settings.json
          --uninstall-claude-hooks  remove Perch hooks, restore original statusline
          --install-codex-hooks     register Perch hooks in ~/.codex/hooks.json and trust them
          --uninstall-codex-hooks   remove Perch hooks from ~/.codex/hooks.json
          --trust-codex-hooks       re-trust registered Codex hooks (needed after hook changes)
        """)
        exit(0)
    default:
        if command.hasPrefix("--") {
            FileHandle.standardError.write(Data("Unknown command \(command); see --help\n".utf8))
            exit(2)
        }
        // e.g. process serial number args from LaunchServices — ignore, run app.
    }
}

// Top-level code here runs on the main thread, but is not statically
// main-actor-isolated; assumeIsolated bridges to the @MainActor AppKit APIs.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
