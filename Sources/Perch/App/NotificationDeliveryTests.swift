import Foundation
import PerchCore
import UserNotifications

extension Selftest {
    @MainActor
    static func runNotificationDeliveryTests(_ t: Checker) {
        notificationCategoryMatrix(t)
        notificationMuteTransitions(t)
        notificationStuckReminder(t)
    }

    @MainActor
    private static func notificationCategoryMatrix(_ t: Checker) {
        t.suite("Notifications.categoryMatrix")
        for mask in 0..<16 {
            for muted in [false, true] {
                var config = PerchConfig()
                config.alertsDisabled = muted
                config.notifyAttention = mask & 1 != 0
                config.notifyDangerousCalls = mask & 2 != 0
                config.notifyTaskCompletion = mask & 4 != 0
                config.notifyUsageThresholds = mask & 8 != 0
                let fixture = NotificationFixture(config: config)
                fixture.sendAll()
                let expected = muted ? 0 : mask.nonzeroBitCount
                t.expectEqual(fixture.requests.count, expected, "categories \(mask), muted \(muted)")
                let categories = fixture.requests.map { $0.content.categoryIdentifier }
                t.expectEqual(categories.filter { $0 == "PERCH_RISK" }.count,
                              !muted && config.notifyDangerousCalls ? 1 : 0, "risk category \(mask)/\(muted)")
                t.expectEqual(categories.filter { $0 == "PERCH_USAGE" }.count,
                              !muted && config.notifyUsageThresholds ? 1 : 0, "usage category \(mask)/\(muted)")
            }
        }
    }

    @MainActor
    private static func notificationMuteTransitions(_ t: Checker) {
        t.suite("Notifications.muteTransitions")
        let fixture = NotificationFixture()
        fixture.preferences.alertsDisabled = true
        t.expectEqual(fixture.cancellations, 1, "mute cancels pending requests immediately")
        fixture.sendAll()
        t.expectTrue(fixture.requests.isEmpty, "muted entry points produce no requests")
        fixture.preferences.alertsDisabled = false
        t.expectTrue(fixture.requests.isEmpty, "unmute does not replay missed notifications")
        fixture.sendAll()
        t.expectEqual(fixture.requests.count, 4, "muted calls did not consume dedupe or coalescing")
        fixture.sendAll()
        t.expectEqual(fixture.requests.count, 4, "enabled duplicate calls stay deduplicated")
        guard let risk = t.unwrap(fixture.requests.first { $0.content.categoryIdentifier == "PERCH_RISK" },
                                 "risk request") else { return }
        t.expectEqual(risk.content.userInfo["perchDetection"] as? String, fixture.entry.id.uuidString,
                      "request opens exact retained detection")
        t.expectEqual(risk.content.userInfo["perchSession"] as? String, fixture.session.key.id,
                      "request preserves session route")
        t.expectEqual(risk.content.userInfo["perchAgent"] as? String, "claude", "request preserves agent route")
        t.expectTrue(risk.content.sound != nil, "default notification carries sound")
        t.expectEqual(fixture.notifier.presentationOptions(hasSound: true), [.banner, .list, .sound],
                      "enabled foreground delivery presents banner and sound")
        fixture.preferences.sounds = false
        t.expectEqual(fixture.notifier.presentationOptions(hasSound: true), [.banner, .list],
                      "in-flight request respects newly disabled sound")
        fixture.preferences.alertsDisabled = true
        t.expectEqual(fixture.cancellations, 2, "second mute cancels new pending requests")
        t.expectTrue(fixture.pending.isEmpty, "submitted but undelivered requests removed")
        t.expectTrue(fixture.notifier.presentationOptions(hasSound: true).isEmpty,
                     "in-flight foreground request cannot present after mute")
        t.expectTrue(fixture.notifier.presentationOptions(hasSound: false).isEmpty,
                     "silent foreground request cannot present after mute")
        fixture.preferences.alertsDisabled = true
        t.expectEqual(fixture.cancellations, 2, "identical preference does not repeat cancellation")
        fixture.preferences.alertsDisabled = false
        fixture.notifier.notifyAttention(session: fixture.session, reason: "new input")
        // A recent risk notification still coalesces this same-session input.
        t.expectEqual(fixture.requests.count, 4, "mute does not erase existing coalescing")
        let next = Session(key: SessionKey(agent: .codex, id: "next-session"))
        fixture.notifier.notifyAttention(session: next, reason: "new input")
        t.expectEqual(fixture.requests.count, 5, "new event resumes after unmute")
        t.expectNil(fixture.requests.last?.content.sound, "new request respects saved sound choice")
        t.expectEqual(fixture.notifier.presentationOptions(hasSound: false), [.banner, .list],
                      "silent request stays silent after unmute")

        var disabled = PerchConfig()
        disabled.alertsDisabled = true
        let restored = NotificationFixture(config: disabled)
        t.expectEqual(restored.cancellations, 1, "muted launch clears previously pending requests")
        restored.sendAll()
        t.expectTrue(restored.requests.isEmpty, "restored mute suppresses every category")

        var riskOff = PerchConfig()
        riskOff.notifyDangerousCalls = false
        let attentionOnly = NotificationFixture(config: riskOff)
        attentionOnly.notifier.notifyRisk(session: attentionOnly.session, entry: attentionOnly.entry)
        attentionOnly.notifier.notifyAttention(session: attentionOnly.session, reason: "input")
        t.expectEqual(attentionOnly.requests.count, 1, "disabled danger never suppresses attention")
    }

    @MainActor
    private static func notificationStuckReminder(_ t: Checker) {
        t.suite("Notifications.stuckReminder")
        let fixture = NotificationFixture()
        let now = Date(timeIntervalSince1970: 10_000)
        fixture.sessions.upsert(agent: .claude, id: "waiting") {
            $0.state = .waitingInput
            $0.lastActivity = now.addingTimeInterval(-301)
        }
        fixture.preferences.alertsDisabled = true
        fixture.notifier.sweepStuckSessions(at: now)
        t.expectTrue(fixture.requests.isEmpty, "timer reminder suppressed while muted")
        fixture.preferences.alertsDisabled = false
        fixture.notifier.sweepStuckSessions(at: now.addingTimeInterval(60))
        t.expectTrue(fixture.requests.isEmpty, "old waiting episode is not replayed after unmute")
        fixture.sessions.upsert(agent: .claude, id: "waiting") { $0.state = .executing }
        fixture.notifier.sweepStuckSessions(at: now.addingTimeInterval(61))
        fixture.sessions.upsert(agent: .claude, id: "waiting") { $0.state = .waitingPermission }
        fixture.notifier.sweepStuckSessions(at: now.addingTimeInterval(62))
        t.expectEqual(fixture.requests.count, 1, "new waiting episode can notify again")
        fixture.notifier.sweepStuckSessions(at: now.addingTimeInterval(122))
        t.expectEqual(fixture.requests.count, 1, "each waiting episode notifies only once")
    }
}

@MainActor
private final class NotificationFixture {
    let sessions = SessionStore()
    let preferences: NotificationPreferences
    private(set) var notifier: Notifier!
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var pending: [UNNotificationRequest] = []
    private(set) var cancellations = 0
    let session = Session(key: SessionKey(agent: .claude, id: "alert-session"))
    let entry: RiskFeed.Entry

    init(config: PerchConfig = PerchConfig()) {
        var saved = config
        preferences = NotificationPreferences(config: config, loadConfig: { saved }, saveConfig: { saved = $0 })
        entry = RiskFeed.Entry(id: UUID(), key: session.key, toolUseId: "tool", toolName: "Bash",
                               toolInput: .object([:]), cwd: nil, receivedAt: Date(),
                               risk: RiskAssessor.assess(agent: .claude, toolName: "Bash", input: .object([
                                "command": .string("sudo true"),
                               ])))
        notifier = Notifier(sessions: sessions, preferences: preferences,
                            delivery: .init(send: { [weak self] request in
                                self?.requests.append(request)
                                self?.pending.append(request)
                            }, removePending: { [weak self] in
                                self?.cancellations += 1
                                self?.pending.removeAll()
                            }), startTimer: false)
    }

    func sendAll() {
        notifier.notifyAttention(session: session, reason: "input")
        notifier.notifyRisk(session: session, entry: entry)
        notifier.notifyTaskComplete(session: session, message: "done")
        notifier.notifyUsageThreshold(label: "usage", pct: 85)
    }
}
