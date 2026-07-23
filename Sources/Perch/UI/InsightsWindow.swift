import AppKit
import Charts
import PerchCore
import SwiftUI

@MainActor
final class InsightsWindowController {
    private let model: InsightsModel
    private var window: NSWindow?

    init(model: InsightsModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let value = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            value.title = "Perch — Insights"
            value.isReleasedWhenClosed = false
            value.minSize = NSSize(width: 650, height: 500)
            value.center()
            value.contentViewController = NSHostingController(
                rootView: InsightsView(model: model))
            window = value
        }
        model.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct InsightsTimelinePoint: Identifiable {
    let id: String
    let bucket: String
    let severity: String
    let count: Int
}

struct InsightsView: View {
    @ObservedObject var model: InsightsModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            content
            Divider()
            disclosure
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 650, minHeight: 500)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Insights")
                .font(.title3.weight(.semibold))
            if let snapshot = model.snapshot {
                let refreshed = formattedTime(
                    snapshot.generatedAt,
                    timeZoneID: snapshot.timeZoneIdentifier)
                Text("refreshed \(refreshed)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.state == .loading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading Insights")
            }
            Picker("Time range", selection: $model.selectedRange) {
                ForEach(InsightsRange.allCases) { range in
                    Text(range.rawValue)
                        .tag(range)
                        .accessibilityLabel(range.accessibilityLabel)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            Button("Refresh") { model.refresh() }
                .disabled(model.state == .loading)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.state == .unavailable {
            unavailableState
        } else if let snapshot = model.snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary(snapshot)
                    timeline(snapshot)
                    if snapshot.isEmpty {
                        emptyState
                    } else {
                        findings(snapshot)
                        HStack(alignment: .top, spacing: 14) {
                            agents(snapshot)
                            tools(snapshot)
                        }
                        sessions(snapshot)
                    }
                }
                .padding(16)
            }
        } else {
            centeredState(
                icon: "chart.xyaxis.line",
                title: "Loading local detections…",
                detail: "Reading retained metadata from Perch’s local SQLite store.")
        }
    }

    private func summary(_ snapshot: DetectionInsightsSnapshot) -> some View {
        HStack(spacing: 12) {
            summaryTile(
                title: "Caution detections",
                value: snapshot.cautionCount,
                color: .orange)
            summaryTile(
                title: "Danger detections",
                value: snapshot.dangerCount,
                color: .red)
        }
    }

    private func summaryTile(title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            color.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.16), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    private func timeline(_ snapshot: DetectionInsightsSnapshot) -> some View {
        let rows = snapshot.timeline.flatMap { bucket in
            [
                InsightsTimelinePoint(
                    id: "\(bucket.start.timeIntervalSince1970)-caution",
                    bucket: bucket.label,
                    severity: "Caution",
                    count: bucket.cautionCount),
                InsightsTimelinePoint(
                    id: "\(bucket.start.timeIntervalSince1970)-danger",
                    bucket: bucket.label,
                    severity: "Danger",
                    count: bucket.dangerCount),
            ]
        }
        return insightsCard(title: "Observed detections") {
            Chart(rows) { row in
                BarMark(
                    x: .value("Time", row.bucket),
                    y: .value("Detections", row.count),
                    stacking: .standard)
                    .foregroundStyle(by: .value("Severity", row.severity))
            }
            .chartForegroundStyleScale([
                "Caution": Color.orange,
                "Danger": Color.red,
            ])
            .chartXAxis {
                AxisMarks(values: axisLabels(snapshot)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .frame(minHeight: 170)
            .accessibilityLabel(
                "Detection timeline, \(snapshot.cautionCount) caution and "
                    + "\(snapshot.dangerCount) danger detections")
        }
    }

    private func findings(_ snapshot: DetectionInsightsSnapshot) -> some View {
        insightsCard(title: "Findings") {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.findings.enumerated()), id: \.element.id) {
                    index, finding in
                    HStack(spacing: 8) {
                        severityBadge(finding.level)
                        Text(finding.code)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(finding.count)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(finding.code), \(finding.level.label), "
                            + "\(finding.count) findings")
                    if index < snapshot.findings.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func agents(_ snapshot: DetectionInsightsSnapshot) -> some View {
        insightsCard(title: "By agent") {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.agents.enumerated()), id: \.element.id) {
                    index, agent in
                    aggregateRow(
                        name: agent.agent.insightsDisplayName,
                        caution: agent.cautionCount,
                        danger: agent.dangerCount)
                    if index < snapshot.agents.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func tools(_ snapshot: DetectionInsightsSnapshot) -> some View {
        insightsCard(title: "By tool") {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.tools.enumerated()), id: \.element.id) {
                    index, tool in
                    aggregateRow(
                        name: tool.toolName,
                        caution: tool.cautionCount,
                        danger: tool.dangerCount,
                        monospaced: true)
                    if index < snapshot.tools.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func aggregateRow(name: String, caution: Int, danger: Int,
                              monospaced: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(monospaced
                      ? .system(size: 12, design: .monospaced)
                      : .callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if caution > 0 {
                Text("\(caution) caution")
                    .foregroundStyle(.orange)
            }
            if danger > 0 {
                Text("\(danger) danger")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func sessions(_ snapshot: DetectionInsightsSnapshot) -> some View {
        insightsCard(title: "Sessions with findings") {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.sessions.enumerated()), id: \.element.id) {
                    index, session in
                    sessionRow(session, snapshot: snapshot)
                    if index < snapshot.sessions.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: DetectionSessionAggregate,
                            snapshot: DetectionInsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(session.agent.insightsDisplayName)
                    .font(.caption.weight(.semibold))
                Text(shortSessionID(session.sessionID))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.sessionID)
                Spacer()
                severityBadge(session.highestLevel)
                Text("\(session.detectionCount) detection"
                     + (session.detectionCount == 1 ? "" : "s"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(sessionTimeRange(session, snapshot: snapshot))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(session.tools.joined(separator: " · "))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(session.findings) { finding in
                        Text("\(finding.code) ×\(finding.count)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(severityColor(finding.level))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(severityColor(finding.level).opacity(0.10)))
                    }
                }
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.agent.insightsDisplayName) session \(session.sessionID), "
                + "\(session.detectionCount) detections, "
                + "highest severity \(session.highestLevel.label)")
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("No retained detections in this range")
                    .font(.headline)
                Text("A quiet history is meaningful only when Monitoring Setup shows active coverage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var unavailableState: some View {
        centeredState(
            icon: "exclamationmark.triangle",
            title: "Insights unavailable",
            detail: "Perch could not read its local detection store. "
                + "Live monitoring and notifications continue to work.",
            retry: true)
    }

    private func centeredState(icon: String, title: String, detail: String,
                               retry: Bool = false) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            if retry {
                Button("Retry") { model.refresh() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var disclosure: some View {
        HStack(spacing: 7) {
            Image(systemName: "eye")
                .foregroundStyle(.secondary)
            Text("Perch observed these requests. It does not know whether they were "
                 + "approved, denied, executed, or completed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func insightsCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func severityBadge(_ level: RiskLevel) -> some View {
        Text(level.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(severityColor(level))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(severityColor(level).opacity(0.12)))
    }

    private func severityColor(_ level: RiskLevel) -> Color {
        switch level {
        case .safe: return .green
        case .caution: return .orange
        case .danger: return .red
        }
    }

    private func axisLabels(_ snapshot: DetectionInsightsSnapshot) -> [String] {
        let indices: [Int]
        switch snapshot.range {
        case .hours24:
            indices = [0, 6, 12, 18, 23]
        case .days7:
            indices = Array(snapshot.timeline.indices)
        case .days30:
            indices = [0, 6, 12, 18, 24, 29]
        }
        return indices.compactMap { snapshot.timeline.indices.contains($0)
            ? snapshot.timeline[$0].label
            : nil
        }
    }

    private func shortSessionID(_ id: String) -> String {
        guard id.count > 18 else { return id }
        return "\(id.prefix(8))…\(id.suffix(6))"
    }

    private func sessionTimeRange(_ session: DetectionSessionAggregate,
                                  snapshot: DetectionInsightsSnapshot) -> String {
        let first = formattedDateTime(
            session.firstObservedAt,
            timeZoneID: snapshot.timeZoneIdentifier)
        let last = formattedDateTime(
            session.lastObservedAt,
            timeZoneID: snapshot.timeZoneIdentifier)
        return first == last ? first : "\(first) – \(last)"
    }

    private func formattedTime(_ date: Date, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(identifier: timeZoneID)
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formattedDateTime(_ date: Date, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(identifier: timeZoneID)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
