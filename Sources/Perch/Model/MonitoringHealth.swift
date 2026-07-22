import Foundation
import PerchCore

enum MonitoringCheckState: String, Sendable {
    case checking
    case ready
    case needsAttention
    case unavailable
}

struct MonitoringCheck: Sendable {
    let title: String
    let state: MonitoringCheckState
    let summary: String
    let detail: String?

    var isReady: Bool { state == .ready }
}

enum HookInstallationState: Sendable {
    case missing
    case unreadable
    case partial
    case ready
}

/// Structured hook status shared by setup, monitoring health, and Doctor.
/// Keeping this separate from the rendered strings prevents those surfaces
/// from drifting into contradictory answers.
struct HookInstallationStatus: Sendable {
    let state: HookInstallationState
    let wiredEvents: Int
    let totalEvents: Int
    let summary: String

    var isReady: Bool { state == .ready }
}

struct MonitoringSnapshot: Sendable {
    let bridge: MonitoringCheck
    let socket: MonitoringCheck
    let claude: MonitoringCheck
    let codex: MonitoringCheck

    static let checking = MonitoringSnapshot(
        bridge: MonitoringCheck(title: "Bridge", state: .checking,
                                summary: "Checking…", detail: nil),
        socket: MonitoringCheck(title: "Runtime", state: .checking,
                                summary: "Checking…", detail: nil),
        claude: MonitoringCheck(title: "Claude Code", state: .checking,
                                summary: "Checking…", detail: nil),
        codex: MonitoringCheck(title: "Codex", state: .checking,
                               summary: "Checking…", detail: nil))

    var state: MonitoringCheckState {
        if bridge.state == .checking || socket.state == .checking { return .checking }
        guard bridge.isReady, socket.isReady else { return .unavailable }
        return claude.isReady || codex.isReady ? .ready : .needsAttention
    }

    var title: String {
        switch state {
        case .checking: return "Checking monitoring"
        case .ready: return "Monitoring configured"
        case .needsAttention: return "Setup needed"
        case .unavailable: return "Monitoring offline"
        }
    }

    var summary: String {
        guard bridge.isReady, socket.isReady else {
            return [bridge, socket].first(where: { !$0.isReady })?.summary
                ?? "Perch's local runtime is unavailable"
        }
        let active = [claude, codex].filter(\.isReady).map(\.title)
        if active.isEmpty { return "Install hooks for Claude Code or Codex" }
        return active.count == 2 ? "Claude Code and Codex covered" : "\(active[0]) covered"
    }

    var hasConfiguredAgent: Bool { claude.isReady || codex.isReady }

    func check(for agent: AgentKind) -> MonitoringCheck {
        switch agent {
        case .claude: return claude
        case .codex: return codex
        }
    }

    var configuredAgents: [AgentKind] {
        AgentKind.allCases.filter { check(for: $0).isReady }
    }
}

struct MonitoringPresentation: Sendable {
    let state: MonitoringCheckState
    let title: String
    let summary: String
}

enum MonitoringInspector {
    static func inspect(runtime: MonitoringCheck) -> MonitoringSnapshot {
        let bridge = Doctor.bridgeCheck()

        let claudeStatus = ClaudeHookInstaller.installationStatus()
        let claude = MonitoringCheck(
            title: "Claude Code",
            state: checkState(for: claudeStatus.state),
            summary: claudeStatus.summary,
            detail: "Hooks provide detections; the status line provides Claude usage gauges.")

        let codexStatus = CodexHookInstaller.installationStatus()
        let trustCount = CodexHookTrust.storedTrustRecordCount()
        let codexState: MonitoringCheckState
        let codexSummary: String
        if codexStatus.isReady, (trustCount ?? 0) > 0 {
            codexState = .ready
            codexSummary = "Hooks installed and trusted"
        } else if codexStatus.isReady {
            codexState = .needsAttention
            codexSummary = "Hooks installed; trust is missing"
        } else {
            codexState = checkState(for: codexStatus.state)
            codexSummary = codexStatus.summary
        }
        let codex = MonitoringCheck(
            title: "Codex",
            state: codexState,
            summary: codexSummary,
            detail: "Session rollouts may still appear without hooks, but tool-risk coverage needs trusted hooks.")

        return MonitoringSnapshot(bridge: bridge, socket: runtime,
                                  claude: claude, codex: codex)
    }

    private static func checkState(for state: HookInstallationState) -> MonitoringCheckState {
        switch state {
        case .ready: return .ready
        case .missing, .partial: return .needsAttention
        case .unreadable: return .unavailable
        }
    }
}

@MainActor
final class MonitoringHealth: ObservableObject {
    @Published private(set) var snapshot: MonitoringSnapshot = .checking
    @Published private(set) var notificationState: NotificationAuthorizationState = .unknown
    @Published private(set) var lastClaudeEventAt: Date?
    @Published private(set) var lastCodexEventAt: Date?
    @Published private(set) var isRefreshing = false
    private var runtimeCheck = MonitoringSnapshot.checking.socket
    private var lastPersistedClaudeEventAt: Date?
    private var lastPersistedCodexEventAt: Date?

    /// Hook events can be frequent; persist the first observation immediately,
    /// then at most once per minute per integration.
    private static let persistenceInterval: TimeInterval = 60

    init(config: PerchConfig = .load()) {
        lastClaudeEventAt = config.lastClaudeHookEventAt
        lastCodexEventAt = config.lastCodexHookEventAt
        lastPersistedClaudeEventAt = config.lastClaudeHookEventAt
        lastPersistedCodexEventAt = config.lastCodexHookEventAt
    }

    var presentation: MonitoringPresentation {
        let baseState = snapshot.state
        guard baseState == .ready else {
            return MonitoringPresentation(state: baseState, title: snapshot.title,
                                          summary: snapshot.summary)
        }

        let unverified = snapshot.configuredAgents.filter { lastEventAt(for: $0) == nil }
        guard unverified.isEmpty else {
            let names = unverified.map(Self.agentName).joined(separator: " and ")
            let summary = unverified.count == snapshot.configuredAgents.count
                ? "Start or restart \(names) to verify event delivery"
                : "\(names) still awaiting a hook event"
            return MonitoringPresentation(state: .needsAttention,
                                          title: "Verification needed", summary: summary)
        }

        let names = snapshot.configuredAgents.map(Self.agentName)
        let covered = names.count == 2 ? names.joined(separator: " and ") : names[0]
        return MonitoringPresentation(state: .ready, title: "Monitoring verified",
                                      summary: "\(covered) event delivery verified")
    }

    var lastEventAt: Date? {
        [lastClaudeEventAt, lastCodexEventAt].compactMap { $0 }.max()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let runtime = runtimeCheck
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = MonitoringInspector.inspect(runtime: runtime)
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = snapshot
                self.isRefreshing = false
            }
        }
    }

    func noteEvent(agent: AgentKind, at date: Date = Date()) {
        switch agent {
        case .claude: lastClaudeEventAt = date
        case .codex: lastCodexEventAt = date
        }

        let persisted = persistedEventAt(for: agent)
        if persisted.map({ date.timeIntervalSince($0) >= Self.persistenceInterval }) ?? true {
            persistVerification()
        }
    }

    func lastEventAt(for agent: AgentKind) -> Date? {
        switch agent {
        case .claude: return lastClaudeEventAt
        case .codex: return lastCodexEventAt
        }
    }

    func verificationState(for agent: AgentKind) -> MonitoringCheckState {
        let check = snapshot.check(for: agent)
        guard check.isReady else { return check.state }
        return lastEventAt(for: agent) == nil ? .needsAttention : .ready
    }

    /// Installing, repairing, or removing hooks invalidates an older delivery
    /// proof. The next real event must verify the newly configured path.
    func clearVerification(for agent: AgentKind) {
        switch agent {
        case .claude: lastClaudeEventAt = nil
        case .codex: lastCodexEventAt = nil
        }
        persistVerification()
    }

    func persistVerification() {
        var config = PerchConfig.load()
        config.lastClaudeHookEventAt = lastClaudeEventAt
        config.lastCodexHookEventAt = lastCodexEventAt
        do {
            try config.save()
            lastPersistedClaudeEventAt = lastClaudeEventAt
            lastPersistedCodexEventAt = lastCodexEventAt
        } catch {
            PerchLog.warn("Could not save monitoring verification: \(error.localizedDescription)",
                          category: "config")
        }
    }

    func updateRuntime(isRunning: Bool, error: String? = nil) {
        runtimeCheck = MonitoringCheck(
            title: "Runtime",
            state: isRunning ? .ready : .unavailable,
            summary: isRunning ? "Local event server is listening" : "Local event server failed to start",
            detail: error)
    }

    func updateNotificationState(_ state: NotificationAuthorizationState) {
        notificationState = state
    }

    /// Deterministic seam for selftests and static showcase rendering.
    func injectSnapshot(_ snapshot: MonitoringSnapshot) {
        self.snapshot = snapshot
        isRefreshing = false
    }

    /// Deterministic seam for selftests and static showcase rendering.
    func injectVerification(claude: Date?, codex: Date?) {
        lastClaudeEventAt = claude
        lastCodexEventAt = codex
    }

    private func persistedEventAt(for agent: AgentKind) -> Date? {
        switch agent {
        case .claude: return lastPersistedClaudeEventAt
        case .codex: return lastPersistedCodexEventAt
        }
    }

    private static func agentName(_ agent: AgentKind) -> String {
        agent == .claude ? "Claude Code" : "Codex"
    }
}
