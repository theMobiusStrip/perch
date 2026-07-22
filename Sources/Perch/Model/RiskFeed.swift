import Foundation
import PerchCore

/// Read-only feed of flagged (caution/danger) tool calls for the notch card.
/// Perch never answers the agent — entries are purely informational: the
/// decision happens in the terminal, the card just makes the risk impossible
/// to miss. Dismissing an entry only clears the card.
@MainActor
final class RiskFeed: ObservableObject {
    /// How long an unattended entry stays in the feed. A flagged call the
    /// user hasn't looked at in 5 minutes is stale — the terminal prompt has
    /// long been answered (or the tool has long run).
    static let entryTTL: TimeInterval = 300

    /// Retained detection history backs the posture explanation. Dismissing a
    /// transient card never erases this audit trail; it ages out with the
    /// posture score after one hour.
    static let recentWindow: TimeInterval = SecurityPosture.window

    /// Window in which an identical (session, tool, input) event is treated
    /// as a duplicate. PreToolUse and PermissionRequest both fire for the
    /// same call; one card is enough.
    static let dedupeWindow: TimeInterval = 10

    struct Entry: Identifiable {
        let id: UUID
        let key: SessionKey
        let toolName: String
        let toolInput: JSONValue
        let cwd: String?
        let receivedAt: Date
        let risk: RiskAssessment
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var recent: [Entry] = []
    @Published private(set) var focusedIndex: Int = 0

    var onAdd: ((Entry) -> Void)?
    var onEmpty: (() -> Void)?

    var focused: Entry? {
        entries.indices.contains(focusedIndex) ? entries[focusedIndex] : entries.first
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// Adds a flagged call to the feed. Safe (unflagged) calls and near-term
    /// duplicates are ignored. Returns true only for a genuinely new event —
    /// callers use this to count each real-world call exactly once even
    /// though PreToolUse and PermissionRequest both fire for it.
    @discardableResult
    func add(key: SessionKey, toolName: String, toolInput: JSONValue,
             cwd: String?, risk: RiskAssessment, receivedAt: Date = Date()) -> Bool {
        guard !risk.isEmpty else { return false }
        pruneRecent(now: receivedAt)
        if recent.contains(where: {
            $0.key == key && $0.toolName == toolName && $0.toolInput == toolInput
                && receivedAt.timeIntervalSince($0.receivedAt) < Self.dedupeWindow
        }) {
            return false
        }
        let entry = Entry(id: UUID(), key: key, toolName: toolName, toolInput: toolInput,
                          cwd: cwd, receivedAt: receivedAt, risk: risk)
        entries.append(entry)
        recent.append(entry)
        if entries.count == 1 { focusedIndex = 0 }
        PerchLog.info("Flagged \(risk.level.label) \(toolName) for \(key.agent.rawValue):\(key.id) (\(risk.findings.map(\.code).joined(separator: ",")))",
                      category: "detect")
        scheduleExpiry(for: entry.id)
        scheduleRecentExpiry(for: entry.id)
        onAdd?(entry)
        return true
    }

    func dismissFocused() {
        guard let entry = focused else { return }
        dismiss(id: entry.id)
    }

    func dismiss(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: idx)
        clampFocus()
        if entries.isEmpty { onEmpty?() }
    }

    func dismissAll(for key: SessionKey) {
        guard entries.contains(where: { $0.key == key }) else { return }
        entries.removeAll { $0.key == key }
        clampFocus()
        if entries.isEmpty { onEmpty?() }
    }

    func focusNext() {
        guard !entries.isEmpty else { return }
        focusedIndex = (focusedIndex + 1) % entries.count
    }

    func focusPrevious() {
        guard !entries.isEmpty else { return }
        focusedIndex = (focusedIndex - 1 + entries.count) % entries.count
    }

    func pruneRecent(now: Date = Date()) {
        recent.removeAll { now.timeIntervalSince($0.receivedAt) > Self.recentWindow }
    }

    /// Wall-clock expiry (Task.sleep pauses across system sleep, so re-check
    /// the true age on fire and re-arm for the remainder).
    private func scheduleExpiry(for id: UUID) {
        Task { [weak self] in
            while true {
                guard let self, let entry = self.entries.first(where: { $0.id == id }) else { return }
                let remaining = Self.entryTTL - Date().timeIntervalSince(entry.receivedAt)
                if remaining <= 0 {
                    self.dismiss(id: id)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    private func scheduleRecentExpiry(for id: UUID) {
        Task { [weak self] in
            while true {
                guard let self,
                      let entry = self.recent.first(where: { $0.id == id }) else { return }
                let remaining = Self.recentWindow - Date().timeIntervalSince(entry.receivedAt)
                if remaining <= 0 {
                    self.pruneRecent()
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    private func clampFocus() {
        if focusedIndex >= entries.count { focusedIndex = max(0, entries.count - 1) }
    }
}
