import SwiftUI

/// Coverage strip kept separate from the risk posture score: green means the
/// event path is connected, not merely that no detections happened recently.
struct MonitoringHealthBadgeView: View {
    @ObservedObject var health: MonitoringHealth
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(health.snapshot.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                Text(health.snapshot.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().strokeBorder(color.opacity(0.24), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Open Monitoring Setup and health details")
    }

    private var color: Color {
        switch health.snapshot.state {
        case .checking: return .secondary
        case .ready: return PerchTheme.running
        case .needsAttention: return PerchTheme.attention
        case .unavailable: return PerchTheme.danger
        }
    }

    private var icon: String {
        switch health.snapshot.state {
        case .checking: return "ellipsis.circle"
        case .ready: return "wave.3.right.circle.fill"
        case .needsAttention: return "wrench.and.screwdriver.fill"
        case .unavailable: return "antenna.radiowaves.left.and.right.slash"
        }
    }
}
