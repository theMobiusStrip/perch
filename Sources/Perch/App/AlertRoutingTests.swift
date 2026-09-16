import Foundation
import PerchCore
import UserNotifications

extension Selftest {
    @MainActor
    static func runAlertRoutingTests(_ t: Checker) {
        t.suite("AlertRouting.muteAndResume")
        var config = PerchConfig()
        config.alertsDisabled = true
        let preferences = NotificationPreferences(config: config,
            loadConfig: { config }, saveConfig: { config = $0 })
        let sessions = SessionStore()
        let usage = UsageStore()
        let feed = RiskFeed()
        let posture = SecurityPosture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-alert-routing-\(UUID().uuidString)")
        let durable = DetectionStore(databaseURL: root.appendingPathComponent("detections.sqlite3"),
            identity: DetectionIdentity(endpointUser: "test-user", endpointHost: "test-host",
                                        producerVersion: "v-test"))
        defer {
            durable.close()
            try? FileManager.default.removeItem(at: root)
        }
        guard t.unwrap(try? durable.startSynchronously(), "temporaryStoreStarted") != nil else { return }
        sessions.riskFeed = feed
        sessions.usageStore = usage
        sessions.securityPosture = posture
        sessions.detectionStore = durable
        var delivered: [UNNotificationRequest] = []
        let notifier = Notifier(sessions: sessions, preferences: preferences,
            delivery: .init(send: { delivered.append($0) }, removePending: {}), startTimer: false)
        var attentionCount = 0
        var cleared: [Bool] = []
        let routing = AlertRouting(sessions: sessions, usage: usage, riskFeed: feed,
            preferences: preferences, notifier: notifier,
            showAttention: { attentionCount += 1 }, clearAttention: { cleared.append($0) })
        defer { withExtendedLifetime(routing) {} }
        let replies = AlertRoutingReplies()
        func hook(_ event: String, session: String, extra: [String: JSONValue] = [:]) {
            var payload = extra
            payload["hook_event_name"] = .string(event)
            payload["session_id"] = .string(session)
            sessions.handleEnvelope(BridgeEnvelope(kind: .hook, agent: .claude, receivedAtMs: 0,
                payload: .object(payload))) { replies.append($0) }
        }
        func quota(_ pct: Double) {
            sessions.handleEnvelope(BridgeEnvelope(kind: .statusline, agent: .claude, receivedAtMs: 0,
                payload: .object(["session_id": .string("quota"), "rate_limits": .object([
                    "five_hour": .object(["used_percentage": .number(pct)]),
                ])]))) { replies.append($0) }
        }
        let danger: [String: JSONValue] = ["tool_name": .string("Bash"),
            "tool_use_id": .string("danger-call"),
            "tool_input": .object(["command": .string("sudo shutdown -h now")])]
        hook("PreToolUse", session: "danger", extra: danger)
        hook("PermissionRequest", session: "danger", extra: danger)
        hook("Notification", session: "input", extra: ["message": .string("Choose an option")])
        hook("Stop", session: "complete")
        quota(90)
        durable.waitUntilIdle()
        t.expectEqual(attentionCount, 0, "mutedHooksNeverOpenNotch")
        t.expectTrue(delivered.isEmpty, "allMutedRoutesSuppressNotifications")
        t.expectEqual(sessions.find(agent: .claude, id: "danger")?.state, .waitingPermission,
                      "mutedPermissionStillMonitored")
        t.expectEqual(sessions.find(agent: .claude, id: "input")?.state, .waitingInput,
                      "mutedInputStillMonitored")
        t.expectEqual(sessions.find(agent: .claude, id: "complete")?.state, .idle,
                      "mutedCompletionStillMonitored")
        t.expectEqual(sessions.find(agent: .claude, id: "danger")?.lastRisk, .danger,
                      "mutedRiskBadgeRetained")
        t.expectEqual(usage.claudeFiveHour?.usedPercentage, 90, "mutedUsageStillUpdated")
        t.expectEqual(feed.count, 1, "mutedRiskCardRetainedAndDeduplicated")
        t.expectEqual(feed.recent.count, 1, "mutedRiskHistoryRetained")
        t.expectEqual(posture.dangerCount, 1, "mutedPostureUpdated")
        t.expectEqual(try? durable.startSynchronously().count, 1, "mutedDetectionPersisted")

        preferences.alertsDisabled = false
        t.expectEqual(attentionCount, 0, "unmuteDoesNotReplayNotch")
        t.expectTrue(delivered.isEmpty, "unmuteDoesNotReplayNotifications")
        hook("Notification", session: "resumed", extra: ["message": .string("New input")])
        t.expectEqual(attentionCount, 1, "newInputOpensNotch")
        t.expectEqual(delivered.count, 1, "newInputNotifies")
        hook("PreToolUse", session: "new-danger", extra: danger)
        t.expectEqual(attentionCount, 2, "newDangerOpensNotch")
        t.expectEqual(delivered.count, 2, "newDangerNotifies")
        hook("PermissionRequest", session: "permission", extra: ["tool_name": .string("Read")])
        t.expectEqual(attentionCount, 3, "safePermissionOpensNotch")
        t.expectEqual(delivered.count, 3, "safePermissionNotifies")
        hook("Stop", session: "new-complete")
        quota(50)
        quota(90)
        t.expectEqual(delivered.count, 5, "newCompletionAndThresholdNotify")

        preferences.alertsDisabled = true
        t.expectEqual(cleared, [true], "muteClearsAttentionImmediately")
        t.expectEqual(feed.count, 2, "muteRetainsOpenRiskCards")
        t.expectEqual(feed.recent.count, 2, "muteRetainsHistory")
        let deliveredBeforeResume = delivered.count
        preferences.alertsDisabled = false
        t.expectEqual(delivered.count, deliveredBeforeResume, "secondUnmuteHasNoReplay")
        preferences.attention = false
        preferences.dangerousCalls = false
        hook("Notification", session: "category-off", extra: ["message": .string("Still waiting")])
        hook("PreToolUse", session: "danger-category-off", extra: danger)
        t.expectEqual(attentionCount, 5, "categoryMuteDoesNotMuteNotch")
        t.expectEqual(delivered.count, deliveredBeforeResume, "categoryMuteSuppressesBanners")
        preferences.alertsDisabled = true
        preferences.alertsDisabled = false
        t.expectFalse(preferences.attention, "attentionCategorySurvivesMute")
        t.expectFalse(preferences.dangerousCalls, "dangerCategorySurvivesMute")

        // Feed exhaustion and a resumed waiting session keep ordinary cleanup.
        for entry in feed.entries { feed.dismiss(id: entry.id) }
        t.expectEqual(cleared.last, false, "feedCleanupIsNotImmediate")
        for session in sessions.sessions { sessions.remove(agent: session.key.agent, id: session.key.id) }
        hook("Notification", session: "cleanup")
        let clearsBeforeStop = cleared.count
        hook("Stop", session: "cleanup")
        t.expectEqual(cleared.count, clearsBeforeStop + 1, "completionClearsWaitingAttention")
        t.expectEqual(cleared.last, false, "sessionCleanupIsNotImmediate")
        t.expectEqual(replies.values.count, 15, "everyEnvelopeReplied")
        t.expectTrue(replies.values.allSatisfy { $0.stdout == nil }, "allRepliesRemainEmpty")
    }
}

private final class AlertRoutingReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BridgeReply] = []

    func append(_ reply: BridgeReply) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(reply)
    }

    var values: [BridgeReply] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
