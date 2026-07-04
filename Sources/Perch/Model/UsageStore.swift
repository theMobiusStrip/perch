import Foundation
import PerchCore

/// Account-level usage gauges. Claude: statusline `rate_limits` payload.
/// Codex: passive `token_count` events from rollout files.
@MainActor
final class UsageStore: ObservableObject {
    struct RateWindow: Equatable {
        var usedPercentage: Double
        var resetsAt: Date?
        var windowMinutes: Int?
        var updatedAt: Date
    }

    @Published private(set) var claudeFiveHour: RateWindow?
    @Published private(set) var claudeSevenDay: RateWindow?
    @Published private(set) var codexPrimary: RateWindow?
    @Published private(set) var codexSecondary: RateWindow?

    /// (gauge label, used percentage) — fired once when crossing the threshold.
    var onThreshold: ((String, Double) -> Void)?
    private var thresholdArmed: [String: Bool] = [:]
    private let thresholdPct: Double = 80

    // MARK: - Claude (statusline payload)

    func applyClaudeStatusline(_ payload: HookPayload) {
        let limits = payload.json["rate_limits"]
        if let window = Self.parseWindow(limits?["five_hour"]) {
            claudeFiveHour = window
            checkThreshold(label: "Claude 5h", window: window)
        }
        if let window = Self.parseWindow(limits?["seven_day"]) {
            claudeSevenDay = window
            checkThreshold(label: "Claude 7d", window: window)
        }
    }

    // MARK: - Codex (token_count event payload)

    func applyCodexRateLimits(_ payload: JSONValue) {
        let limits = payload["rate_limits"]
        if let window = Self.parseWindow(limits?["primary"]) {
            codexPrimary = window
            checkThreshold(label: "Codex 5h", window: window)
        }
        if let window = Self.parseWindow(limits?["secondary"]) {
            codexSecondary = window
            checkThreshold(label: "Codex weekly", window: window)
        }
    }

    // MARK: - Parsing

    /// Tolerates both naming families: `used_percentage`/`used_percent`,
    /// `resets_at` (unix seconds or ISO8601 string) / `resets_in_seconds`.
    static func parseWindow(_ json: JSONValue?) -> RateWindow? {
        guard let json, !json.isNull else { return nil }
        guard let pct = json.first(of: ["used_percentage", "used_percent"])?.double else { return nil }
        var resetsAt: Date?
        if let v = json.first(of: ["resets_at", "reset_at"]) {
            if let ts = v.double, ts > 1_000_000_000 {
                // Heuristic: ms vs seconds.
                resetsAt = ts > 100_000_000_000
                    ? Date(timeIntervalSince1970: ts / 1000)
                    : Date(timeIntervalSince1970: ts)
            } else if let s = v.string {
                resetsAt = ISO8601DateFormatter().date(from: s)
                    ?? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s) }()
            }
        } else if let secs = json["resets_in_seconds"]?.double {
            resetsAt = Date().addingTimeInterval(secs)
        }
        let windowMinutes = json["window_minutes"]?.int
        return RateWindow(usedPercentage: pct, resetsAt: resetsAt,
                          windowMinutes: windowMinutes, updatedAt: Date())
    }

    private func checkThreshold(label: String, window: RateWindow) {
        let armed = thresholdArmed[label, default: true]
        if window.usedPercentage >= thresholdPct, armed {
            thresholdArmed[label] = false
            onThreshold?(label, window.usedPercentage)
        } else if window.usedPercentage < thresholdPct - 5 {
            thresholdArmed[label] = true
        }
    }
}
