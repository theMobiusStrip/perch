import SwiftUI

/// Coverage strip kept separate from the risk posture score: green means the
/// event path is connected, not merely that no detections happened recently.
struct MonitoringHealthBadgeView: View {
    @ObservedObject var health: MonitoringHealth
    let onOpen: () -> Void

    var body: some View {
        let presentation = health.presentation
        Button(action: onOpen) {
            HStack(spacing: 7) {
                Image(systemName: icon(for: presentation.state))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color(for: presentation.state))
                Text(presentation.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                Text(presentation.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(color(for: presentation.state).opacity(0.10)))
            .overlay(Capsule().strokeBorder(
                color(for: presentation.state).opacity(0.24), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Open Monitoring Setup and health details")
    }

    private func color(for state: MonitoringCheckState) -> Color {
        switch state {
        case .checking: return .secondary
        case .ready: return PerchTheme.running
        case .needsAttention: return PerchTheme.attention
        case .unavailable: return PerchTheme.danger
        }
    }

    private func icon(for state: MonitoringCheckState) -> String {
        switch state {
        case .checking: return "ellipsis.circle"
        case .ready: return "wave.3.right.circle.fill"
        case .needsAttention: return "wrench.and.screwdriver.fill"
        case .unavailable: return "antenna.radiowaves.left.and.right.slash"
        }
    }
}
