import SwiftUI
import PerchCore

/// Shared visual language for the notch panel: surfaces, hairlines, and the
/// semantic colors every row, gauge, and badge draws from. Pure presentation —
/// no behavior lives here.
enum PerchTheme {
    // MARK: - Surfaces (drawn on the near-black shell)

    /// Elevated card on the panel (session rows, glance rows, integrity rows).
    static let cardFill = Color.white.opacity(0.055)
    /// Hairline around cards — the border, not the fill, is what reads as
    /// "raised" against the black shell.
    static let cardBorder = Color.white.opacity(0.09)
    /// Recessed well (code blocks, info callouts).
    static let insetFill = Color.black.opacity(0.30)
    static let insetBorder = Color.white.opacity(0.06)
    /// Unfilled portion of bars/gauges.
    static let trackFill = Color.white.opacity(0.10)

    // MARK: - Semantic state colors

    static let running = Color(red: 0.30, green: 0.85, blue: 0.56)
    static let attention = Color.orange
    static let danger = Color(red: 1.00, green: 0.42, blue: 0.40)
    static let caution = Color(red: 1.00, green: 0.80, blue: 0.34)
    static let idle = Color(white: 0.62)
    static let dormant = Color(white: 0.38)

    /// One color per agent across the whole app (matches the usage chart).
    static func agentColor(_ agent: AgentKind) -> Color {
        switch agent {
        case .claude: return Color(red: 1.00, green: 0.62, blue: 0.30)
        case .codex: return Color(red: 0.30, green: 0.78, blue: 0.76)
        }
    }

    static func agentIcon(_ agent: AgentKind) -> String {
        agent == .claude ? "sparkle" : "command"
    }

    // MARK: - Session state

    static func stateColor(_ state: SessionState) -> Color {
        switch state {
        case .executing: return running
        case .waitingPermission, .waitingInput: return attention
        case .idle: return idle
        case .ended, .unknown: return dormant
        }
    }

    /// Gauge fill: green → amber → red as the window fills up.
    static func gaugeColor(pct: Double) -> Color {
        if pct > 85 { return danger }
        if pct > 60 { return attention }
        return running
    }
}

// MARK: - Reusable surface modifiers

extension View {
    /// Elevated card: soft white fill with a hairline border.
    func perchCard(cornerRadius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(PerchTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(PerchTheme.cardBorder, lineWidth: 1)
        )
    }

    /// Recessed well: dark inset with a faint hairline (code blocks, callouts).
    func perchInset(cornerRadius: CGFloat = 8) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(PerchTheme.insetFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(PerchTheme.insetBorder, lineWidth: 1)
        )
    }
}

/// Small square chip carrying an agent icon, tinted with the agent's color.
struct AgentIconChip: View {
    let agent: AgentKind
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: PerchTheme.agentIcon(agent))
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(PerchTheme.agentColor(agent))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .fill(PerchTheme.agentColor(agent).opacity(0.16))
            )
    }
}

/// One tappable footer line in the notch panel (Worktrees, Tokens): icon,
/// label, summary, and a chevron that signals "opens a window".
struct NotchGlanceRow: View {
    let icon: String
    let tint: Color
    let label: String
    let summary: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary.opacity(0.85))
            Spacer(minLength: 8)
            Text(summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .contentShape(Rectangle())
    }
}

/// Colored dot + label on a tinted capsule — the session state badge.
struct StatePill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}
