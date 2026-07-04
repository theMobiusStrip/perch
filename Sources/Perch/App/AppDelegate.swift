import AppKit
import Combine
import PerchCore

/// Menu-bar / notch actions surfaced by StatusItemController. Closures
/// returning String produce a human-readable result shown in an alert.
struct AppActions {
    var installClaudeHooks: () -> String
    var installCodexHooks: () -> String
    var uninstallClaudeHooks: () -> String
    var uninstallCodexHooks: () -> String
    var doctorReport: () -> String
    var toggleNotch: () -> Void
    var openDebugWindow: () -> Void
    var openUsageHistory: () -> Void
    var quit: () -> Void
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sessionStore = SessionStore()
    let usageStore = UsageStore()
    let riskFeed = RiskFeed()
    let securityPosture = SecurityPosture()

    private var socketServer: UnixSocketServer?
    private var livenessMonitor: LivenessMonitor?
    private var claudeTailer: ClaudeTranscriptTailer?
    private var codexTailer: CodexRolloutTailer?
    private var notch: NotchController?
    private var statusItem: StatusItemController?
    private var notifier: Notifier?
    private var debugWindow: DebugWindowController?
    private let usageHistory = UsageHistoryModel()
    private let integrityModel = IntegrityModel()
    private var usageRefreshTimer: Timer?
    private var integrityRefreshTimer: Timer?
    private var usageHistoryWindow: UsageHistoryWindowController?
    private var cancellables = Set<AnyCancellable>()
    /// True while the notch is showing attention we raised via onAttention.
    /// Lets the session-publish observer clear notification-driven
    /// (waiting-input) attention, which has no RiskFeed entry and
    /// therefore never triggers onEmpty.
    private var attentionPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        PerchLog.info("Perch launching")
        do {
            try PerchPaths.ensureAppSupportDir()
        } catch {
            PerchLog.error("Cannot create app support dir: \(error)")
        }

        // User-declared regenerable scratch dirs downgrade recursive-delete
        // notifications; load once (sanitized to safe basenames) so the risk
        // assessor sees them.
        RiskAssessor.userScratchDirs = RiskAssessor.sanitizedScratchDirs(PerchConfig.load().scratchDirs)

        sessionStore.riskFeed = riskFeed
        sessionStore.usageStore = usageStore
        sessionStore.securityPosture = securityPosture

        let notifier = Notifier(sessions: sessionStore)
        self.notifier = notifier
        notifier.requestAuthorization()

        // Keep the bundled bridge at its stable hook-command path. Writes only
        // inside our own app-support dir — safe to do on every launch.
        do {
            let deployed = try BridgeDeployer.deploy()
            PerchLog.info("Bridge deployed at \(deployed.path)")
        } catch {
            PerchLog.warn("Bridge deploy failed: \(error)")
        }

        let store = sessionStore
        let server = UnixSocketServer { envelope, reply in
            Task { @MainActor in
                store.handleEnvelope(envelope, reply: reply)
            }
        }
        do {
            try server.start()
            PerchLog.info("Socket server listening at \(PerchPaths.socketPath)")
        } catch {
            PerchLog.error("Socket server failed to start: \(error)")
        }
        socketServer = server

        livenessMonitor = LivenessMonitor(store: sessionStore)
        livenessMonitor?.start()
        claudeTailer = ClaudeTranscriptTailer(store: sessionStore)
        claudeTailer?.start()
        codexTailer = CodexRolloutTailer(store: sessionStore, usage: usageStore)
        codexTailer?.start()

        // Per-project instruction files (CLAUDE.md/AGENTS.md) live in the
        // session cwds, so feed the current set to the integrity scanner.
        integrityModel.projectDirsProvider = { [weak self] in
            guard let self else { return [] }
            let paths = Set(self.sessionStore.sessions.compactMap { $0.cwd })
            return paths.map { URL(fileURLWithPath: $0) }
        }
        let notchController = NotchController(sessions: sessionStore, usage: usageStore,
                                              riskFeed: riskFeed, posture: securityPosture,
                                              usageHistory: usageHistory, integrity: integrityModel)
        notchController.show()
        notch = notchController

        statusItem = StatusItemController(sessions: sessionStore, usage: usageStore,
                                          riskFeed: riskFeed, posture: securityPosture,
                                          actions: makeActions())

        wireCrossCutting()

        // Feed the notch usage overview: scan on launch, refresh every 15min
        // (background queue; ~seconds over a month of transcripts).
        usageHistory.refresh()
        let refresh = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.usageHistory.refresh()
            }
        }
        refresh.tolerance = 60
        usageRefreshTimer = refresh

        integrityModel.refresh()
        let integrityRefresh = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.integrityModel.refresh() }
        }
        integrityRefresh.tolerance = 20
        integrityRefreshTimer = integrityRefresh

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        socketServer?.stop()
        PerchLog.info("Perch terminated")
    }

    @objc private func screensChanged() {
        notch?.rebuildForScreenChange()
    }

    private func wireCrossCutting() {
        sessionStore.onAttention = { [weak self] session, reason in
            self?.attentionPending = true
            self?.notch?.attention()
            self?.notifier?.notifyAttention(session: session, reason: reason)
        }
        sessionStore.onTaskComplete = { [weak self] session, message in
            self?.notifier?.notifyTaskComplete(session: session, message: message)
        }
        sessionStore.onRiskDetected = { [weak self] session, toolName, risk in
            self?.attentionPending = true
            self?.notch?.attention()
            self?.notifier?.notifyRisk(session: session, toolName: toolName, risk: risk)
        }
        riskFeed.onEmpty = { [weak self] in
            self?.clearNotchAttention()
        }
        // Notification-driven attention (waiting-input) never adds a feed
        // entry, so onEmpty alone would leave the panel expanded, key, and
        // amber forever. Clear it once the session leaves its waiting state
        // (user answered / stop / session end).
        sessionStore.$sessions
            .sink { [weak self] sessions in
                MainActor.assumeIsolated {
                    self?.sessionsDidPublish(sessions)
                }
            }
            .store(in: &cancellables)
        usageStore.onThreshold = { [weak self] label, pct in
            self?.notifier?.notifyUsageThreshold(label: label, pct: pct)
        }
    }

    private func sessionsDidPublish(_ sessions: [Session]) {
        guard attentionPending,
              riskFeed.isEmpty,
              !sessions.contains(where: { $0.needsAttention }) else { return }
        clearNotchAttention()
    }

    private func clearNotchAttention() {
        attentionPending = false
        notch?.attentionCleared()
    }

    private func makeActions() -> AppActions {
        AppActions(
            installClaudeHooks: { Self.runReporting { try ClaudeHookInstaller.install() } },
            installCodexHooks: { Self.runReporting {
                var report = try CodexHookInstaller.install()
                report.notes += CodexHookTrust.ensureTrusted()
                return report
            } },
            uninstallClaudeHooks: { Self.runReporting { try ClaudeHookInstaller.uninstall() } },
            uninstallCodexHooks: { Self.runReporting { try CodexHookInstaller.uninstall() } },
            doctorReport: { Doctor.report() },
            toggleNotch: { [weak self] in self?.notch?.toggle() },
            openDebugWindow: { [weak self] in
                guard let self else { return }
                if self.debugWindow == nil {
                    self.debugWindow = DebugWindowController(sessions: self.sessionStore,
                                                             usage: self.usageStore)
                }
                self.debugWindow?.show()
            },
            openUsageHistory: { [weak self] in
                guard let self else { return }
                if self.usageHistoryWindow == nil {
                    self.usageHistoryWindow = UsageHistoryWindowController(model: self.usageHistory)
                }
                self.usageHistoryWindow?.show()
            },
            quit: { NSApp.terminate(nil) })
    }

    private static func runReporting(_ body: () throws -> InstallReport) -> String {
        do {
            return try body().summaryText
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }
}
