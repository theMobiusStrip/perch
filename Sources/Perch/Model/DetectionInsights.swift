import Combine
import Foundation
import PerchCore

enum InsightsRange: String, CaseIterable, Hashable, Identifiable, Sendable {
    case hours24 = "24H"
    case days7 = "7D"
    case days30 = "30D"

    var id: String { rawValue }

    var accessibilityLabel: String {
        switch self {
        case .hours24: return "Past 24 hours"
        case .days7: return "Past 7 calendar days"
        case .days30: return "Past 30 calendar days"
        }
    }

    func bucketDefinitions(now: Date, calendar: Calendar) -> [InsightsBucketDefinition] {
        switch self {
        case .hours24:
            return hourlyDefinitions(now: now, calendar: calendar)
        case .days7:
            return dailyDefinitions(days: 7, now: now, calendar: calendar)
        case .days30:
            return dailyDefinitions(days: 30, now: now, calendar: calendar)
        }
    }

    private func hourlyDefinitions(now: Date,
                                   calendar: Calendar) -> [InsightsBucketDefinition] {
        let start = now.addingTimeInterval(-24 * 60 * 60)
        let starts = (0..<24).map {
            start.addingTimeInterval(TimeInterval($0) * 60 * 60)
        }

        let baseFormatter = DateFormatter()
        baseFormatter.calendar = calendar
        baseFormatter.locale = Locale(identifier: "en_US_POSIX")
        baseFormatter.timeZone = calendar.timeZone
        baseFormatter.dateFormat = "h a"
        let baseLabels = starts.map(baseFormatter.string)
        let frequencies = Dictionary(grouping: baseLabels, by: { $0 })
            .mapValues(\.count)

        let zonedFormatter = DateFormatter()
        zonedFormatter.calendar = calendar
        zonedFormatter.locale = Locale(identifier: "en_US_POSIX")
        zonedFormatter.timeZone = calendar.timeZone
        zonedFormatter.dateFormat = "h a zzz"

        return starts.enumerated().map { index, bucketStart in
            let bucketEnd = index == starts.count - 1
                ? now
                : starts[index + 1]
            let base = baseLabels[index]
            let label = frequencies[base, default: 0] > 1
                ? zonedFormatter.string(from: bucketStart)
                : base
            return InsightsBucketDefinition(
                start: bucketStart,
                end: bucketEnd,
                label: label,
                includesEnd: index == starts.count - 1)
        }
    }

    private func dailyDefinitions(days: Int, now: Date,
                                  calendar: Calendar) -> [InsightsBucketDefinition] {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: today)
        else { return [] }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"

        return (0..<days).compactMap { index in
            guard let start = calendar.date(byAdding: .day, value: index, to: first)
            else { return nil }
            let end: Date
            if index == days - 1 {
                end = now
            } else {
                guard let next = calendar.date(byAdding: .day, value: 1, to: start)
                else { return nil }
                end = next
            }
            return InsightsBucketDefinition(
                start: start,
                end: end,
                label: formatter.string(from: start),
                includesEnd: index == days - 1)
        }
    }
}

struct InsightsBucketDefinition: Equatable, Sendable {
    let start: Date
    let end: Date
    let label: String
    let includesEnd: Bool

    func contains(_ date: Date) -> Bool {
        date >= start && (date < end || (includesEnd && date <= end))
    }
}

struct DetectionTimelineBucket: Identifiable, Equatable, Sendable {
    let start: Date
    let end: Date
    let label: String
    var cautionCount: Int
    var dangerCount: Int

    var id: Date { start }
    var totalCount: Int { cautionCount + dangerCount }
}

struct DetectionFindingAggregate: Identifiable, Equatable, Sendable {
    let code: String
    let level: RiskLevel
    var count: Int

    var id: String { "\(code)|\(level.label)" }
}

struct DetectionAgentAggregate: Identifiable, Equatable, Sendable {
    let agent: AgentKind
    var cautionCount: Int
    var dangerCount: Int

    var id: String { agent.rawValue }
    var detectionCount: Int { cautionCount + dangerCount }
}

struct DetectionToolAggregate: Identifiable, Equatable, Sendable {
    let toolName: String
    var cautionCount: Int
    var dangerCount: Int

    var id: String { toolName }
    var detectionCount: Int { cautionCount + dangerCount }
}

struct DetectionSessionAggregate: Identifiable, Equatable, Sendable {
    let agent: AgentKind
    let sessionID: String
    let firstObservedAt: Date
    let lastObservedAt: Date
    let detectionCount: Int
    let highestLevel: RiskLevel
    let tools: [String]
    let findings: [DetectionFindingAggregate]

    var id: String { "\(agent.rawValue)|\(sessionID)" }
}

struct DetectionInsightsSnapshot: Equatable, Sendable {
    let range: InsightsRange
    let generatedAt: Date
    let startAt: Date
    let endAt: Date
    let timeZoneIdentifier: String
    let timeline: [DetectionTimelineBucket]
    let findings: [DetectionFindingAggregate]
    let agents: [DetectionAgentAggregate]
    let tools: [DetectionToolAggregate]
    let sessions: [DetectionSessionAggregate]

    var cautionCount: Int { timeline.reduce(0) { $0 + $1.cautionCount } }
    var dangerCount: Int { timeline.reduce(0) { $0 + $1.dangerCount } }
    var detectionCount: Int { cautionCount + dangerCount }
    var isEmpty: Bool { detectionCount == 0 }

    static func aggregate(rows: [DetectionInsightsSourceRow],
                          range: InsightsRange,
                          now: Date,
                          calendar: Calendar) -> DetectionInsightsSnapshot {
        let definitions = range.bucketDefinitions(now: now, calendar: calendar)
        var timeline = definitions.map {
            DetectionTimelineBucket(
                start: $0.start,
                end: $0.end,
                label: $0.label,
                cautionCount: 0,
                dangerCount: 0)
        }

        var seenEvents: Set<String> = []
        var findingCounts: [String: DetectionFindingAggregate] = [:]
        var agentCounts: [String: DetectionAgentAggregate] = [:]
        var toolCounts: [String: DetectionToolAggregate] = [:]
        var sessionBuilders: [String: DetectionSessionBuilder] = [:]

        for row in rows {
            guard let bucketIndex = definitions.firstIndex(where: {
                $0.contains(row.observedAt)
            }) else { continue }

            let sessionKey = "\(row.agent.rawValue)|\(row.sessionID)"
            if seenEvents.insert(row.eventID).inserted {
                switch row.riskLevel {
                case .caution:
                    timeline[bucketIndex].cautionCount += 1
                case .danger:
                    timeline[bucketIndex].dangerCount += 1
                case .safe:
                    continue
                }

                var agent = agentCounts[row.agent.rawValue]
                    ?? DetectionAgentAggregate(
                        agent: row.agent,
                        cautionCount: 0,
                        dangerCount: 0)
                agent.record(row.riskLevel)
                agentCounts[row.agent.rawValue] = agent

                var tool = toolCounts[row.toolName]
                    ?? DetectionToolAggregate(
                        toolName: row.toolName,
                        cautionCount: 0,
                        dangerCount: 0)
                tool.record(row.riskLevel)
                toolCounts[row.toolName] = tool

                var session = sessionBuilders[sessionKey]
                    ?? DetectionSessionBuilder(
                        agent: row.agent,
                        sessionID: row.sessionID,
                        observedAt: row.observedAt,
                        level: row.riskLevel)
                session.recordDetection(
                    observedAt: row.observedAt,
                    level: row.riskLevel,
                    toolName: row.toolName)
                sessionBuilders[sessionKey] = session
            }

            let findingKey = "\(row.findingCode)|\(row.findingLevel.label)"
            var finding = findingCounts[findingKey]
                ?? DetectionFindingAggregate(
                    code: row.findingCode,
                    level: row.findingLevel,
                    count: 0)
            finding.count += 1
            findingCounts[findingKey] = finding

            if var session = sessionBuilders[sessionKey] {
                session.recordFinding(code: row.findingCode, level: row.findingLevel)
                sessionBuilders[sessionKey] = session
            }
        }

        let findings = findingCounts.values.sorted(by: Self.findingOrder)
        let agents = agentCounts.values.sorted {
            if $0.detectionCount != $1.detectionCount {
                return $0.detectionCount > $1.detectionCount
            }
            return $0.agent.insightsDisplayName < $1.agent.insightsDisplayName
        }
        let tools = toolCounts.values.sorted {
            if $0.detectionCount != $1.detectionCount {
                return $0.detectionCount > $1.detectionCount
            }
            return $0.toolName.localizedCaseInsensitiveCompare($1.toolName) == .orderedAscending
        }
        let sessions = sessionBuilders.values
            .map(\.aggregate)
            .sorted {
                if $0.lastObservedAt != $1.lastObservedAt {
                    return $0.lastObservedAt > $1.lastObservedAt
                }
                if $0.agent != $1.agent {
                    return $0.agent.insightsDisplayName < $1.agent.insightsDisplayName
                }
                return $0.sessionID < $1.sessionID
            }

        return DetectionInsightsSnapshot(
            range: range,
            generatedAt: now,
            startAt: definitions.first?.start ?? now,
            endAt: definitions.last?.end ?? now,
            timeZoneIdentifier: calendar.timeZone.identifier,
            timeline: timeline,
            findings: findings,
            agents: agents,
            tools: tools,
            sessions: sessions)
    }

    fileprivate static func findingOrder(_ lhs: DetectionFindingAggregate,
                                         _ rhs: DetectionFindingAggregate) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        if lhs.code != rhs.code { return lhs.code < rhs.code }
        return lhs.level > rhs.level
    }
}

struct DetectionInsightsSourceRow: Equatable, Sendable {
    let eventID: String
    let observedAt: Date
    let agent: AgentKind
    let sessionID: String
    let toolName: String
    let riskLevel: RiskLevel
    let findingCode: String
    let findingLevel: RiskLevel
}

private struct DetectionSessionBuilder {
    let agent: AgentKind
    let sessionID: String
    var firstObservedAt: Date
    var lastObservedAt: Date
    var detectionCount: Int
    var highestLevel: RiskLevel
    var tools: Set<String>
    var findings: [String: DetectionFindingAggregate]

    init(agent: AgentKind, sessionID: String, observedAt: Date, level: RiskLevel) {
        self.agent = agent
        self.sessionID = sessionID
        self.firstObservedAt = observedAt
        self.lastObservedAt = observedAt
        self.detectionCount = 0
        self.highestLevel = level
        self.tools = []
        self.findings = [:]
    }

    mutating func recordDetection(observedAt: Date, level: RiskLevel,
                                  toolName: String) {
        firstObservedAt = min(firstObservedAt, observedAt)
        lastObservedAt = max(lastObservedAt, observedAt)
        detectionCount += 1
        highestLevel = max(highestLevel, level)
        tools.insert(toolName)
    }

    mutating func recordFinding(code: String, level: RiskLevel) {
        let key = "\(code)|\(level.label)"
        var finding = findings[key]
            ?? DetectionFindingAggregate(code: code, level: level, count: 0)
        finding.count += 1
        findings[key] = finding
    }

    var aggregate: DetectionSessionAggregate {
        DetectionSessionAggregate(
            agent: agent,
            sessionID: sessionID,
            firstObservedAt: firstObservedAt,
            lastObservedAt: lastObservedAt,
            detectionCount: detectionCount,
            highestLevel: highestLevel,
            tools: tools.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            },
            findings: findings.values.sorted(by: DetectionInsightsSnapshot.findingOrder))
    }
}

private extension DetectionAgentAggregate {
    mutating func record(_ level: RiskLevel) {
        switch level {
        case .caution: cautionCount += 1
        case .danger: dangerCount += 1
        case .safe: break
        }
    }
}

private extension DetectionToolAggregate {
    mutating func record(_ level: RiskLevel) {
        switch level {
        case .caution: cautionCount += 1
        case .danger: dangerCount += 1
        case .safe: break
        }
    }
}

extension AgentKind {
    var insightsDisplayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

@MainActor
final class InsightsModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case unavailable
    }

    @Published var selectedRange: InsightsRange = .hours24 {
        didSet {
            if selectedRange != oldValue { refresh() }
        }
    }
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var snapshot: DetectionInsightsSnapshot?

    private let store: DetectionStore
    private var generation = 0

    init(store: DetectionStore) {
        self.store = store
    }

    /// Showcase support: adopt a prebuilt snapshot without touching the store.
    func injectSnapshot(_ snap: DetectionInsightsSnapshot) {
        generation += 1  // invalidate any in-flight refresh
        snapshot = snap
        state = .loaded
    }

    func refresh(now: Date = Date()) {
        generation += 1
        let requestGeneration = generation
        let range = selectedRange
        state = .loading

        store.loadInsights(range: range, now: now) { [weak self] result in
            guard let self,
                  self.generation == requestGeneration,
                  self.selectedRange == range else { return }
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.state = .loaded
            case .failure:
                self.snapshot = nil
                self.state = .unavailable
            }
        }
    }
}
