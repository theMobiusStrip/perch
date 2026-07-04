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
        .padding(.vertical, 7)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(alignment: .leading) {
            if session.needsAttention {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.orange)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                expanded.toggle()
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.key.agent == .claude ? "sparkle" : "command")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(session.key.agent == .claude ? Color.orange : Color.cyan)
                .frame(width: 16, height: 16)
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
                            .foregroundStyle(session.lastRisk == .danger ? Color.red : Color.yellow)
                            .help(session.lastRisk == .danger
                                  ? "A dangerous tool call was flagged"
                                  : "A tool call was flagged for review")
                    }
                    Spacer(minLength: 4)
                    stateBadge
                }

                HStack(spacing: 8) {
                    elapsedText
                    if session.totalTokens > 0 {
                        Text(Self.compactTokens(session.totalTokens))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let pct = session.contextUsedPct {
                        ContextMicroBar(pct: pct)
                    }
                    if session.subagentCount > 0 {
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

                snippetLine
            }
        }
    }

    private var stateBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            Text(stateText)
                .font(.caption2)
                .foregroundStyle(session.needsAttention ? Color.orange : Color.secondary)
        }
    }

    @ViewBuilder
    private var snippetLine: some View {
        if session.needsAttention, let note = session.attentionNote, !note.isEmpty {
            Text(note)
                .font(.caption)
                .foregroundStyle(Color.orange)
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
        .padding(.leading, 24)
        .padding(.bottom, 2)
    }

    // MARK: - State presentation

    private var stateColor: Color {
        switch session.state {
        case .executing: return .green
        case .waitingPermission, .waitingInput: return .orange
        case .idle: return .gray
        case .ended: return Color.gray.opacity(0.5)
        case .unknown: return Color.gray.opacity(0.5)
        }
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

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geo.size.width * CGFloat(min(max(pct, 0), 100) / 100)))
                }
            }
            .frame(width: 34, height: 4)
            Text("\(Int(min(max(pct, 0), 100)))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var color: Color {
        if pct > 85 { return .red }
        if pct > 60 { return .orange }
        return .green
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
        if event.isError { return .red }
        if event.endedAt == nil { return .green }
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
