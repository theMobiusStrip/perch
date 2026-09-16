import Combine
import PerchCore

/// Connects observed events to optional interruptions without changing the
/// session, risk-feed, or persisted detection state that produced them.
@MainActor
final class AlertRouting {
    private let riskFeed: RiskFeed
    private let preferences: NotificationPreferences
    private let notifier: Notifier
    private let showAttention: () -> Void
    private let clearAttention: (Bool) -> Void
    private var attentionPending = false
    private var cancellables = Set<AnyCancellable>()

    init(sessions: SessionStore, usage: UsageStore, riskFeed: RiskFeed,
         preferences: NotificationPreferences, notifier: Notifier,
         showAttention: @escaping () -> Void,
         clearAttention: @escaping (Bool) -> Void) {
        self.riskFeed = riskFeed
        self.preferences = preferences
        self.notifier = notifier
        self.showAttention = showAttention
        self.clearAttention = clearAttention

        sessions.onAttention = { [weak self] session, reason in
            self?.raiseAttention()
            self?.notifier.notifyAttention(session: session, reason: reason)
        }
        sessions.onTaskComplete = { [weak self] session, message in
            self?.notifier.notifyTaskComplete(session: session, message: message)
        }
        sessions.onRiskDetected = { [weak self] session, entry in
            self?.raiseAttention()
            self?.notifier.notifyRisk(session: session, entry: entry)
        }
        usage.onThreshold = { [weak self] label, pct in
            self?.notifier.notifyUsageThreshold(label: label, pct: pct)
        }
        preferences.$alertsDisabled
            .dropFirst()
            .sink { [weak self] disabled in
                if disabled { self?.clear(immediately: true) }
            }
            .store(in: &cancellables)
        riskFeed.onEmpty = { [weak self] in
            self?.clear(immediately: false)
        }
        // Waiting-input attention has no risk card. Clear it when the
        // session resumes, while retaining attention for any remaining risk.
        sessions.$sessions
            .sink { [weak self] sessions in
                MainActor.assumeIsolated {
                    guard let self, self.attentionPending,
                          self.riskFeed.isEmpty,
                          !sessions.contains(where: { $0.needsAttention }) else { return }
                    self.clear(immediately: false)
                }
            }
            .store(in: &cancellables)
    }

    private func raiseAttention() {
        guard !preferences.alertsDisabled else { return }
        attentionPending = true
        showAttention()
    }

    private func clear(immediately: Bool) {
        attentionPending = false
        clearAttention(immediately)
    }
}
