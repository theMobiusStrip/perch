import Foundation
import PerchCore

extension Selftest {
    @MainActor
    static func runLifecycleCompatibilityTests(_ t: Checker) {
        lifecycleFailurePayload(t)
        lifecycleClaudeFailure(t)
        lifecycleSubagentFailure(t)
        lifecycleCodexTermination(t)
        lifecyclePatchUsesSessionDirectory(t)
        lifecycleClaudeInstallation(t)
    }

    @MainActor
    private static func lifecycleFailurePayload(_ t: Checker) {
        t.suite("Lifecycle.failurePayload")
        let payload = HookPayload(.object([
            "hook_event_name": .string("StopFailure"),
            "error": .string("rate_limit"),
            "error_details": .string("429 Too Many Requests"),
        ]))
        t.expectEqual(payload.eventName, .stopFailure, "recognizesFailure")
        t.expectEqual(payload.errorMessage, "rate_limit", "category")
        t.expectEqual(payload.errorDetails, "429 Too Many Requests", "optionalDetails")
        t.expectEqual(HookPayload(.object(["hook_event_name": .string("Interrupt")])).eventName,
                      .interrupt, "recognizesInterrupt")
    }

    @MainActor
    private static func lifecycleClaudeFailure(_ t: Checker) {
        t.suite("Lifecycle.claudeFailure")
        let store = SessionStore()
        let replies = LifecycleReplies()
        var completions = 0
        var attention: [String] = []
        store.onTaskComplete = { _, _ in completions += 1 }
        store.onAttention = { _, reason in attention.append(reason) }
        store.upsert(agent: .claude, id: "lifecycle") { $0.lastAssistantSnippet = "Prior answer" }
        lifecycleSend(store, replies, "UserPromptSubmit", at: 100)
        lifecycleSend(store, replies, "PreToolUse", at: 101, extra: [
            "tool_name": .string("Read"), "tool_use_id": .string("tool-1"),
        ])
        lifecycleSend(store, replies, "StopFailure", at: 103, extra: [
            "error": .string("rate_limit"), "last_assistant_message": .string("API Error: quota exhausted"),
        ])
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.state, .waitingInput, "failureNeedsInput")
        t.expectEqual(attention, ["API error: rate_limit"], "failureAttention")
        t.expectEqual(completions, 0, "failureNotCompletion")
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.lastAssistantSnippet,
                      "Prior answer", "errorDoesNotReplaceAnswer")
        lifecycleSend(store, replies, "PostToolUse", at: 102, extra: ["tool_use_id": .string("tool-1")])
        lifecycleSend(store, replies, "PostToolUseFailure", at: 104, extra: ["tool_use_id": .string("tool-1")])
        lifecycleSend(store, replies, "Stop", at: 104)
        let failed = store.find(agent: .claude, id: "lifecycle")
        t.expectEqual(failed?.state, .waitingInput, "lateResultsCannotRestartFailure")
        t.expectEqual(failed?.timeline.first?.endedAt != nil, true, "lateResultStillCompletesTimeline")
        t.expectEqual(failed?.isLive, true, "failedTurnKeepsSessionLive")
        store.applyClaudeLiveness([ClaudeLiveInfo(pid: 123, sessionId: "lifecycle")])
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.state, .waitingInput, "livenessPreservesFailure")
        store.handleEnvelope(BridgeEnvelope(kind: .statusline, agent: .claude, receivedAtMs: 104_000,
            payload: .object(["session_id": .string("lifecycle")]))) { replies.append($0) }
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.state, .waitingInput, "statuslinePreservesFailure")
        lifecycleSend(store, replies, "UserPromptSubmit", at: 105)
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.state, .executing, "newPromptRestarts")
        t.expectNil(store.find(agent: .claude, id: "lifecycle")?.attentionNote, "newPromptClearsAttention")
        lifecycleSend(store, replies, "StopFailure", at: 106)
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.attentionNote,
                      "API error: unknown", "missingErrorTolerated")
        lifecycleSend(store, replies, "PostCompact", at: 107)
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.timeline.last?.summary,
                      "Context compacted", "postCompactRecorded")
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.state, .waitingInput, "compactPreservesState")
        t.expectTrue(replies.values.allSatisfy { $0.stdout == nil }, "allRepliesEmpty")
        t.expectEqual(replies.values.count, 10, "eachEnvelopeReplied")
    }

    @MainActor
    private static func lifecycleSubagentFailure(_ t: Checker) {
        t.suite("Lifecycle.subagentFailure")
        let store = SessionStore()
        let replies = LifecycleReplies()
        var attentions = 0
        var completions = 0
        store.onAttention = { _, _ in attentions += 1 }
        store.onTaskComplete = { _, _ in completions += 1 }
        lifecycleSend(store, replies, "UserPromptSubmit", at: 100)
        lifecycleSend(store, replies, "SubagentStart", at: 101, extra: ["agent_id": .string("child")])
        lifecycleSend(store, replies, "StopFailure", at: 102, extra: [
            "agent_id": .string("child"), "error": .string("authentication_failed"),
        ])
        lifecycleSend(store, replies, "Stop", at: 103, extra: ["agent_id": .string("child")])
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.state, .executing, "childDoesNotStopParent")
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.subagentCount, 1, "failureDoesNotDoubleDecrement")
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.timeline.last?.isError, true, "childFailureRecorded")
        t.expectEqual(attentions, 0, "parentNotWaitingForInput")
        t.expectEqual(completions, 0, "childNotParentCompletion")
        lifecycleSend(store, replies, "SubagentStop", at: 104, extra: ["agent_id": .string("child")])
        t.expectEqual(store.find(agent: .claude, id: "lifecycle")?.subagentCount, 0, "subagentStopOwnsCount")
    }

    @MainActor
    private static func lifecycleCodexTermination(_ t: Checker) {
        t.suite("Lifecycle.codexTermination")
        let store = SessionStore()
        let replies = LifecycleReplies()
        var completions = 0
        store.onTaskComplete = { _, _ in completions += 1 }
        lifecycleSend(store, replies, "UserPromptSubmit", agent: .codex, at: 100,
                      extra: ["turn_id": .string("turn-1")])
        lifecycleSend(store, replies, "Interrupt", agent: .codex, at: 101,
                      extra: ["turn_id": .string("turn-1")])
        lifecycleSend(store, replies, "PostToolUse", agent: .codex, at: 102)
        lifecycleSend(store, replies, "Stop", agent: .codex, at: 103,
                      extra: ["turn_id": .string("turn-1")])
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.state, .idle, "interruptStaysIdle")
        t.expectEqual(completions, 0, "interruptNeverCompletes")
        lifecycleSend(store, replies, "UserPromptSubmit", agent: .codex, at: 104,
                      extra: ["turn_id": .string("turn-2")])
        lifecycleSend(store, replies, "PreToolUse", agent: .codex, at: 105,
                      extra: ["turn_id": .string("turn-1"), "tool_name": .string("Read")])
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.activeTurnId,
                      "turn-2", "latePreToolCannotReplaceTurn")
        lifecycleSend(store, replies, "Interrupt", agent: .codex, at: 105,
                      extra: ["turn_id": .string("turn-1")])
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.state, .executing, "oldInterruptIgnored")
        lifecycleSend(store, replies, "SessionEnd", agent: .codex, at: 106)
        store.setCodexLive(id: "lifecycle", live: true)
        store.upsert(agent: .codex, id: "lifecycle") { s in
            s.isLive = true
            s.state = .idle
        }
        lifecycleSend(store, replies, "PostToolUse", agent: .codex, at: 107)
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.state, .ended, "explicitEndBeatsLateResults")
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.isLive, false, "explicitEndBeatsFreshness")
        t.expectEqual(store.sessions.count, 0, "endedCodexHidden")
        let tailer = CodexRolloutTailer(store: store, usage: UsageStore())
        func rolloutStart(_ seconds: Int, _ turn: String) -> JSONValue {
            .object([
                "type": .string("event_msg"),
                "timestamp": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(seconds)))),
                "payload": .object(["type": .string("task_started"), "turn_id": .string(turn)]),
            ])
        }
        tailer.ingestLineForSelftest(rolloutStart(104, "turn-2"), sessionID: "lifecycle")
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.state, .ended, "oldRolloutCannotReopen")
        tailer.ingestLineForSelftest(rolloutStart(108, "turn-3"), sessionID: "lifecycle")
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.state, .executing, "newRolloutReopens")
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.isLive, true, "newRolloutIsLive")
        lifecycleSend(store, replies, "SessionEnd", agent: .codex, at: 109)
        lifecycleSend(store, replies, "SessionStart", agent: .codex, at: 110,
                      extra: ["source": .string("resume")])
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.state, .idle, "explicitResumeReopens")
        tailer.ingestLineForSelftest(rolloutStart(108, "turn-3"), sessionID: "lifecycle")
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.state, .idle, "resumeRejectsOldRollout")
        tailer.ingestLineForSelftest(rolloutStart(111, "turn-4"), sessionID: "lifecycle")
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.state, .executing, "resumeAcceptsNewRollout")
        t.expectTrue(replies.values.allSatisfy { $0.stdout == nil }, "allRepliesEmpty")
    }

    @MainActor
    private static func lifecyclePatchUsesSessionDirectory(_ t: Checker) {
        t.suite("Lifecycle.patchDirectory")
        let store = SessionStore()
        let replies = LifecycleReplies()
        let feed = RiskFeed()
        store.riskFeed = feed
        lifecycleSend(store, replies, "UserPromptSubmit", agent: .codex, at: 100,
                      extra: ["cwd": .string("/workspace/.codex")])
        lifecycleSend(store, replies, "PreToolUse", agent: .codex, at: 101, extra: [
            "tool_name": .string("apply_patch"), "tool_use_id": .string("relative-hook-patch"),
            "tool_input": .object(["command": .string("*** Begin Patch\n*** Add File: hooks.json\n+{}\n*** End Patch")]),
        ])
        t.expectEqual(store.find(agent: .codex, id: "lifecycle")?.lastRisk, .danger,
                      "relativeHookPatchUsesSessionCwd")
        t.expectFalse(feed.isEmpty, "relativeHookPatchSurfaced")
    }

    @MainActor
    private static func lifecycleClaudeInstallation(_ t: Checker) {
        t.suite("Lifecycle.claudeInstallation")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perch-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let settings = dir.appendingPathComponent("settings.json")
            _ = try ClaudeHookInstaller.install(settingsPath: settings, bridgePath: "/tmp/perch-bridge")
            let root = try InstallSupport.readObjectFile(at: settings).object
            for event in ["StopFailure", "PostCompact"] {
                let hook = root["hooks"]?[event]?.arrayValue?.first?["hooks"]?.arrayValue?.first
                t.expectEqual(hook?["async"]?.boolValue, true, "\(event)AsyncInstalled")
            }
            t.expectEqual(ClaudeHookInstaller.installationStatus(settingsPath: settings).state, .ready, "installationReady")
            let repeatInstall = try ClaudeHookInstaller.install(settingsPath: settings, bridgePath: "/tmp/perch-bridge")
            t.expectFalse(repeatInstall.changed, "installationIdempotent")
        } catch {
            t.expectTrue(false, "installationFailed: \(error)")
        }
    }

    @MainActor
    private static func lifecycleSend(_ store: SessionStore, _ replies: LifecycleReplies,
                                      _ event: String, agent: AgentKind = .claude, at seconds: Int64,
                                      extra: [String: JSONValue] = [:]) {
        var payload = extra
        payload["hook_event_name"] = .string(event)
        payload["session_id"] = .string("lifecycle")
        store.handleEnvelope(BridgeEnvelope(kind: .hook, agent: agent, receivedAtMs: seconds * 1000,
                                            payload: .object(payload))) { replies.append($0) }
    }
}

private final class LifecycleReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [BridgeReply] = []
    func append(_ reply: BridgeReply) {
        lock.lock()
        defer { lock.unlock() }
        replies.append(reply)
    }
    var values: [BridgeReply] {
        lock.lock()
        defer { lock.unlock() }
        return replies
    }
}
