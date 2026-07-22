import Foundation
import PerchCore
import UserNotifications

/// A danger notification and the permission-attention event for that same call
/// arrive back-to-back. Keep the useful danger alert and suppress only the
/// redundant attention banner; if danger alerts are disabled, no risk is
/// recorded here and the attention notification still fires.
struct NotificationCoalescer {
    static let overlapWindow: TimeInterval = 5
    private var recentRiskBySession: [SessionKey: Date] = [:]

    mutating func recordRisk(for key: SessionKey, at date: Date = Date()) {
        prune(now: date)
        recentRiskBySession[key] = date
    }

    mutating func shouldSuppressAttention(for key: SessionKey,
                                          at date: Date = Date()) -> Bool {
        prune(now: date)
        guard let riskAt = recentRiskBySession[key] else { return false }
        return date.timeIntervalSince(riskAt) <= Self.overlapWindow
    }

    private mutating func prune(now: Date) {
        recentRiskBySession = recentRiskBySession.filter {
            now.timeIntervalSince($0.value) <= Self.overlapWindow
        }
    }
}

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
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private enum Route: String {
        case detections
        case sessions
        case usage
    }

    private enum NotificationID {
        static let riskCategory = "PERCH_RISK"
        static let sessionCategory = "PERCH_SESSION"
        static let usageCategory = "PERCH_USAGE"
        static let openDetections = "PERCH_OPEN_DETECTIONS"
        static let openSessions = "PERCH_OPEN_SESSIONS"
        static let openUsage = "PERCH_OPEN_USAGE"
        static let routeKey = "perchRoute"
        static let agentKey = "perchAgent"
        static let sessionKey = "perchSession"
        static let detectionKey = "perchDetection"
    }

    private let sessions: SessionStore
    private let preferences: NotificationPreferences
    var onOpenDetections: ((UUID?) -> Void)?
    var onOpenSessions: ((SessionKey?) -> Void)?
    var onOpenUsage: (() -> Void)?

    /// Dedupe: fingerprint → last fired. Same fingerprint within
    /// `dedupeWindow` is skipped.
    private var recentlyFired: [String: Date] = [:]
    private let dedupeWindow: TimeInterval = 30
    private var coalescer = NotificationCoalescer()

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
        super.init()
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
        } else {
            configureNotificationCenter()
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
        guard !coalescer.shouldSuppressAttention(for: session.key) else {
            PerchLog.info("Coalesced attention behind danger alert for \(session.key.id)",
                          category: "notify")
            return
        }
        let fingerprint = "attention|\(session.key.agent.rawValue)|\(session.key.id)|\(reason)"
        guard shouldFire(fingerprint) else { return }
        post(title: "\(session.displayTitle) needs attention",
             body: reason,
             threadId: session.key.id,
             route: .sessions,
             sessionKey: session.key,
             category: NotificationID.sessionCategory)
    }

    /// Danger-level detection: fires regardless of whether the agent will
    /// prompt (a whitelisted or auto-approved dangerous call is exactly the
    /// one you must hear about).
    func notifyRisk(session: Session, entry: RiskFeed.Entry) {
        guard preferences.dangerousCalls else { return }
        // RiskFeed has already collapsed duplicate hook callbacks into one
        // retained entry. Key this final guard by that entry so two distinct
        // dangerous calls with the same tool/findings are never conflated.
        let fingerprint = "risk|\(entry.id.uuidString)"
        guard shouldFire(fingerprint) else { return }
        coalescer.recordRisk(for: session.key)
        let detail = entry.risk.findings.map(\.message).joined(separator: "; ")
        post(title: "\(session.displayTitle): dangerous \(entry.toolName) call",
             body: detail.isEmpty ? "Flagged by Perch's risk detector." : detail,
             threadId: session.key.id,
             route: .detections,
             sessionKey: session.key,
             detectionID: entry.id,
             category: NotificationID.riskCategory)
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
             threadId: session.key.id,
             route: .sessions,
             sessionKey: session.key,
             detectionID: nil,
             category: NotificationID.sessionCategory)
    }

    func notifyUsageThreshold(label: String, pct: Double) {
        guard preferences.usageThresholds else { return }
        let fingerprint = "usage|\(label)"
        guard shouldFire(fingerprint) else { return }
        post(title: "\(label) usage at \(Int(pct.rounded()))%",
             body: "The \(label) rate-limit window is \(Int(pct.rounded()))% used.",
             threadId: "usage",
             route: .usage,
             sessionKey: nil,
             detectionID: nil,
             category: NotificationID.usageCategory)
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

    private func post(title: String, body: String, threadId: String,
                      route: Route, sessionKey: SessionKey?, detectionID: UUID? = nil,
                      category: String) {
        guard notificationsAvailable else {
            PerchLog.info("NOTIFY (log-only): \(title) — \(body)", category: "notify")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = preferences.sounds ? .default : nil
        content.threadIdentifier = threadId
        content.categoryIdentifier = category
        var userInfo: [String: String] = [NotificationID.routeKey: route.rawValue]
        if let sessionKey {
            userInfo[NotificationID.agentKey] = sessionKey.agent.rawValue
            userInfo[NotificationID.sessionKey] = sessionKey.id
        }
        if let detectionID {
            userInfo[NotificationID.detectionKey] = detectionID.uuidString
        }
        content.userInfo = userInfo
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

    private func configureNotificationCenter() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let risk = UNNotificationCategory(
            identifier: NotificationID.riskCategory,
            actions: [UNNotificationAction(identifier: NotificationID.openDetections,
                                           title: "Open Detection", options: [.foreground])],
            intentIdentifiers: [])
        let session = UNNotificationCategory(
            identifier: NotificationID.sessionCategory,
            actions: [UNNotificationAction(identifier: NotificationID.openSessions,
                                           title: "Open Sessions", options: [.foreground])],
            intentIdentifiers: [])
        let usage = UNNotificationCategory(
            identifier: NotificationID.usageCategory,
            actions: [UNNotificationAction(identifier: NotificationID.openUsage,
                                           title: "Open Usage", options: [.foreground])],
            intentIdentifiers: [])
        center.setNotificationCategories([risk, session, usage])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let options: UNNotificationPresentationOptions = notification.request.content.sound == nil
            ? [.banner, .list]
            : [.banner, .list, .sound]
        completionHandler(options)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else {
            completionHandler()
            return
        }
        let info = response.notification.request.content.userInfo
        let route = info[NotificationID.routeKey] as? String
        let agent = (info[NotificationID.agentKey] as? String).flatMap(AgentKind.init(rawValue:))
        let sessionID = info[NotificationID.sessionKey] as? String
        let detectionID = (info[NotificationID.detectionKey] as? String).flatMap(UUID.init(uuidString:))
        completionHandler()

        Task { @MainActor [weak self] in
            let key = agent.flatMap { agent in
                sessionID.map { SessionKey(agent: agent, id: $0) }
            }
            switch route.flatMap(Route.init(rawValue:)) {
            case .detections: self?.onOpenDetections?(detectionID)
            case .sessions: self?.onOpenSessions?(key)
            case .usage: self?.onOpenUsage?()
            case nil: break
            }
        }
    }
}
