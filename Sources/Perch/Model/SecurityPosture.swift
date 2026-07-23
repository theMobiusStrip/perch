import Foundation
import PerchCore

/// Rolling security-risk score for everything Perch has watched recently.
/// Transparent by design: start at 100, subtract 25 per danger-level and 5
/// per caution-level detection in the last hour, floor at 0. Events age out
/// of the window and the score recovers — a quiet hour heals the posture.
/// Purely informational, like everything else in Perch.
@MainActor
final class SecurityPosture: ObservableObject {
    nonisolated static let window: TimeInterval = 3600
    static let dangerPenalty = 25
    static let cautionPenalty = 5

    enum Grade: String {
        case ok = "OK"
        case elevated = "Elevated"
        case high = "High risk"
    }

    @Published private(set) var score = 100
    @Published private(set) var dangerCount = 0
    @Published private(set) var cautionCount = 0

    private struct Event {
        let level: RiskLevel
        let at: Date
    }

    private var events: [Event] = []
    private var decayTimer: Timer?

    init() {
        // Events aging out of the window raise the score back up; a timer is
        // the only way that happens without a new detection arriving.
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recompute()
            }
        }
        timer.tolerance = 10
        decayTimer = timer
    }

    deinit {
        decayTimer?.invalidate()
    }

    var grade: Grade { Self.grade(for: score) }

    func record(_ level: RiskLevel, at date: Date = Date()) {
        guard level != .safe else { return }
        events.append(Event(level: level, at: date))
        recompute(now: date)
    }

    /// Restores only the rolling counters after launch. Historical rows never
    /// become cards, notifications, or attention events.
    func hydrate(_ restored: [DetectionPostureEvent], now: Date = Date()) {
        events.append(contentsOf: restored.map {
            Event(level: $0.level, at: $0.observedAt)
        })
        recompute(now: now)
    }

    func recompute(now: Date = Date()) {
        events.removeAll { now.timeIntervalSince($0.at) > Self.window }
        let dangers = events.filter { $0.level == .danger }.count
        let cautions = events.count - dangers
        let newScore = Self.score(dangerCount: dangers, cautionCount: cautions)
        if newScore != score || dangers != dangerCount || cautions != cautionCount {
            score = newScore
            dangerCount = dangers
            cautionCount = cautions
        }
    }

    // MARK: - Pure scoring (selftested)

    static func score(dangerCount: Int, cautionCount: Int) -> Int {
        max(0, 100 - dangerCount * dangerPenalty - cautionCount * cautionPenalty)
    }

    static func grade(for score: Int) -> Grade {
        switch score {
        case 90...: return .ok
        case 60..<90: return .elevated
        default: return .high
        }
    }
}
