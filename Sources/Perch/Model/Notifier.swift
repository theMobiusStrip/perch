import Foundation
import PerchCore
import UserNotifications

enum NotificationAuthorizationState: String, Sendable {
    case unavailable
    case notRequested
    case denied
    case allowed
    case provisional
    case unknown

    var label: String {
        switch self {
        case .unavailable: return "Unavailable outside Perch.app"
        case .notRequested: return "Not requested"
        case .denied: return "Blocked in System Settings"
        case .allowed: return "Allowed"
        case .provisional: return "Allowed quietly"
        case .unknown: return "Unknown"
        }
    }
}

/// User-notification fan-out: risk detected / session needs input, task
/// complete, usage thresholds, and a stuck-session sweep.
///
/// UN-framework guard: `UNUserNotificationCenter.current()` throws an ObjC
/// exception (uncatchable from Swift) when the process is not a real `.app`
/// bundle — e.g. under `swift run` or the bare SwiftPM binary. Every UN API
/// call is therefore gated behind a bundle check; outside a bundle we fall
/// back to PerchLog only.
@MainActor
final class Notifier {
    private let sessions: SessionStore
    private let preferences: NotificationPreferences

    /// Dedupe: fingerprint → last fired. Same fingerprint within
    /// `dedupeWindow` is skipped.
    private var recentlyFired: [String: Date] = [:]
    private let dedupeWindow: TimeInterval = 30

    /// Stuck detection: sessions already notified for the current
    /// waiting episode. Cleared when the session leaves a waiting state.
    private var stuckNotified: Set<SessionKey> = []
    private let stuckThreshold: TimeInterval = 5 * 60
    private var stuckTimer: Timer?

    /// True only when running from a real .app bundle — the precondition for
    /// touching any UserNotifications API.
    private let notificationsAvailable: Bool =
        Bundle.main.bundlePath.hasSuffix(".app") && Bundle.main.bundleIdentifier != nil

    init(sessions: SessionStore, preferences: NotificationPreferences) {
        self.sessions = sessions
        self.preferences = preferences
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sweepStuckSessions()
            }
        }
        timer.tolerance = 10
        stuckTimer = timer
        if !notificationsAvailable {
            PerchLog.info("Not running from a .app bundle — notifications are log-only",
                          category: "notify")
        }
    }

    deinit {
        stuckTimer?.invalidate()
    }

    // MARK: - Authorization

    func requestAuthorization(completion: ((NotificationAuthorizationState) -> Void)? = nil) {
        guard notificationsAvailable else {
            PerchLog.info("Skipping notification authorization (no .app bundle)", category: "notify")
            completion?(.unavailable)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                if let error {
                    PerchLog.warn("Notification authorization failed: \(error.localizedDescription)",
                                  category: "notify")
                    completion?(.unknown)
                    return
                }
                PerchLog.info("Notification authorization granted=\(granted)", category: "notify")
                completion?(granted ? .allowed : .denied)
            }
        }
    }

    func authorizationState(completion: @escaping (NotificationAuthorizationState) -> Void) {
        guard notificationsAvailable else {
            completion(.unavailable)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: NotificationAuthorizationState
            switch settings.authorizationStatus {
            case .notDetermined: state = .notRequested
            case .denied: state = .denied
            case .authorized, .ephemeral: state = .allowed
            case .provisional: state = .provisional
            @unknown default: state = .unknown
            }
            Task { @MainActor in completion(state) }
        }
    }

    // MARK: - Public notification entry points

    func notifyAttention(session: Session, reason: String) {
        guard preferences.attention else { return }
        let fingerprint = "attention|\(session.key.agent.rawValue)|\(session.key.id)|\(reason)"
        guard shouldFire(fingerprint) else { return }
        post(title: "\(session.displayTitle) needs attention",
             body: reason,
             threadId: session.key.id)
    }

    /// Danger-level detection: fires regardless of whether the agent will
    /// prompt (a whitelisted or auto-approved dangerous call is exactly the
    /// one you must hear about).
    func notifyRisk(session: Session, toolName: String, risk: RiskAssessment) {
        guard preferences.dangerousCalls else { return }
        let codes = risk.findings.map(\.code).joined(separator: ",")
        let fingerprint = "risk|\(session.key.agent.rawValue)|\(session.key.id)|\(toolName)|\(codes)"
        guard shouldFire(fingerprint) else { return }
        let detail = risk.findings.map(\.message).joined(separator: "; ")
        post(title: "\(session.displayTitle): dangerous \(toolName) call",
             body: detail.isEmpty ? "Flagged by Perch's risk detector." : detail,
             threadId: session.key.id)
    }

    func notifyTaskComplete(session: Session, message: String?) {
        guard preferences.taskCompletion else { return }
        let fingerprint = "complete|\(session.key.agent.rawValue)|\(session.key.id)"
        guard shouldFire(fingerprint) else { return }
        let body: String
        if let message, !message.isEmpty {
            body = String(message.prefix(200))
        } else {
            body = "Task complete."
        }
        post(title: "\(session.displayTitle) finished",
             body: body,
             threadId: session.key.id)
    }

    func notifyUsageThreshold(label: String, pct: Double) {
        guard preferences.usageThresholds else { return }
        let fingerprint = "usage|\(label)"
        guard shouldFire(fingerprint) else { return }
        post(title: "\(label) usage at \(Int(pct.rounded()))%",
             body: "The \(label) rate-limit window is \(Int(pct.rounded()))% used.",
             threadId: "usage")
    }

    // MARK: - Stuck-session sweep (60s timer)

    /// A session sitting in waitingPermission/waitingInput for more than
    /// 5 minutes gets exactly one "still waiting" nudge per episode.
    private func sweepStuckSessions() {
        let now = Date()
        var stillWaiting = Set<SessionKey>()
        for session in sessions.sessions where session.state.needsAttention {
            stillWaiting.insert(session.key)
            guard now.timeIntervalSince(session.lastActivity) > stuckThreshold else { continue }
            guard !stuckNotified.contains(session.key) else { continue }
            stuckNotified.insert(session.key)
            notifyAttention(session: session, reason: "Still waiting after 5 minutes…")
        }
        // Sessions that resumed (or vanished) end their episode; a fresh
        // wait period can notify again.
        stuckNotified.formIntersection(stillWaiting)
    }

    // MARK: - Internals

    private func shouldFire(_ fingerprint: String) -> Bool {
        let now = Date()
        // Prune stale fingerprints so the map never grows unbounded.
        recentlyFired = recentlyFired.filter { now.timeIntervalSince($0.value) < 600 }
        if let last = recentlyFired[fingerprint], now.timeIntervalSince(last) < dedupeWindow {
            return false
        }
        recentlyFired[fingerprint] = now
        return true
    }

    private func post(title: String, body: String, threadId: String) {
        guard notificationsAvailable else {
            PerchLog.info("NOTIFY (log-only): \(title) — \(body)", category: "notify")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = preferences.sounds ? .default : nil
        content.threadIdentifier = threadId
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                PerchLog.warn("Notification delivery failed: \(error.localizedDescription)",
                              category: "notify")
            }
        }
    }
}
