import SwiftUI
import PerchCore

/// One session in the expanded notch panel. Tap toggles an inline timeline of
/// the most recent tool events, described in plain language.
struct SessionRowView: View {
    let session: Session

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if expanded {
                timelineList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(session.needsAttention
                      ? PerchTheme.attention.opacity(0.09)
                      : PerchTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(session.needsAttention
                              ? PerchTheme.attention.opacity(0.45)
                              : PerchTheme.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                expanded.toggle()
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 9) {
            AgentIconChip(agent: session.key.agent)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if session.displayTitle != session.projectName {
                        Text(session.projectName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if session.lastRisk != .safe {
                        Image(systemName: session.lastRisk == .danger
                              ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(session.lastRisk == .danger
                                             ? PerchTheme.danger : PerchTheme.caution)
                            .help(session.lastRisk == .danger
                                  ? "A dangerous tool call was flagged"
                                  : "A tool call was flagged for review")
                    }
                    Spacer(minLength: 4)
                    StatePill(text: stateText, color: stateColor)
                }

                metadataLine

                snippetLine
            }
        }
    }

    private var metadataLine: some View {
        HStack(spacing: 5) {
            elapsedText
            if session.totalTokens > 0 {
                separator
                Text(Self.compactTokens(session.totalTokens))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let pct = session.contextUsedPct {
                separator
                ContextMicroBar(pct: pct)
            }
            if session.subagentCount > 0 {
                separator
                Text("\(session.subagentCount) sub")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
    }

    private var separator: some View {
        Text("·")
            .font(.caption2)
            .foregroundStyle(.quaternary)
    }

    @ViewBuilder
    private var snippetLine: some View {
        if session.needsAttention, let note = session.attentionNote, !note.isEmpty {
            Text(note)
                .font(.caption.weight(.medium))
                .foregroundStyle(PerchTheme.attention)
                .lineLimit(1)
        } else if let snippet = session.lastAssistantSnippet, !snippet.isEmpty {
            Text(snippet.replacingOccurrences(of: "\n", with: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Relative "time since last activity", self-updating once a second.
    private var elapsedText: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.elapsedString(from: session.lastActivity, to: context.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Timeline

    private var timelineList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(session.timeline.suffix(8))) { event in
                TimelineEventRow(event: event)
            }
            if session.timeline.isEmpty {
                Text("No tool activity yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 33)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    // MARK: - State presentation

    private var stateColor: Color {
        PerchTheme.stateColor(session.state)
    }

    private var stateText: String {
        switch session.state {
        case .executing: return "running"
        case .waitingPermission: return "asking permission"
        case .waitingInput: return "waiting for you"
        case .idle: return session.isLive ? "idle" : "gone"
        case .ended: return "ended"
        case .unknown: return "–"
        }
    }

    // MARK: - Formatting helpers

    static func elapsedString(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rem = minutes % 60
            return rem > 0 ? "\(hours)h \(rem)m" : "\(hours)h"
        }
        return "\(hours / 24)d"
    }

    static func compactTokens(_ count: Int) -> String {
        func trim(_ value: Double) -> String {
            let s = String(format: "%.1f", value)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        switch count {
        case ..<1000:
            return "\(count) tok"
        case ..<1_000_000:
            return "\(trim(Double(count) / 1000))k tok"
        default:
            return "\(trim(Double(count) / 1_000_000))M tok"
        }
    }
}

/// Tiny context-usage gauge (used when `contextUsedPct` is known).
private struct ContextMicroBar: View {
    let pct: Double

    private var clamped: Double { min(max(pct, 0), 100) }
    private var color: Color { PerchTheme.gaugeColor(pct: clamped) }

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PerchTheme.trackFill)
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.75), color],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, geo.size.width * CGFloat(clamped / 100)))
                }
            }
            .frame(width: 38, height: 4.5)
            Text("\(Int(clamped))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// One plain-language line in the expanded timeline.
private struct TimelineEventRow: View {
    let event: ToolEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 8))
                .foregroundStyle(iconColor)
                .frame(width: 10)
            Text(event.summary)
                .font(.caption2)
                .foregroundStyle(event.isNote ? .tertiary : .secondary)
                .italic(event.isNote)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let duration = durationText {
                Text(duration)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private var iconName: String {
        if event.isNote { return "arrow.triangle.2.circlepath" }
        if event.isError { return "exclamationmark.circle.fill" }
        return event.endedAt == nil ? "circle.dotted" : "checkmark.circle"
    }

    private var iconColor: Color {
        if event.isError { return PerchTheme.danger }
        if event.endedAt == nil { return PerchTheme.running }
        return Color.secondary
    }

    private var durationText: String? {
        guard let endedAt = event.endedAt else { return nil }
        let secs = endedAt.timeIntervalSince(event.startedAt)
        if secs < 0.05 { return nil }
        if secs < 10 { return String(format: "%.1fs", secs) }
        if secs < 60 { return "\(Int(secs))s" }
        return "\(Int(secs / 60))m"
    }
}
