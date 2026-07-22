import SwiftUI

/// Collapsed notch content: count of live sessions + tiny per-state dots
/// (green executing / gray idle / amber attention pulse).
struct PillView: View {
    @ObservedObject var sessions: SessionStore
    @ObservedObject var health: MonitoringHealth
    let hasAttention: Bool

    private var liveSessions: [Session] {
        sessions.sessions.filter(\.isLive)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: healthIcon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(healthColor)
                .accessibilityLabel(health.presentation.title)
                .help("\(health.presentation.title): \(health.presentation.summary)")

            Text("\(liveSessions.count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(liveSessions.isEmpty ? 0.35 : 0.85))

            if !liveSessions.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(liveSessions.prefix(8))) { session in
                        StateDot(state: session.state)
                    }
                }
            }

            if hasAttention {
                AttentionDot()
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    private var healthColor: Color {
        switch health.presentation.state {
        case .checking: return .secondary
        case .ready: return PerchTheme.running
        case .needsAttention: return PerchTheme.attention
        case .unavailable: return PerchTheme.danger
        }
    }

    private var healthIcon: String {
        switch health.presentation.state {
        case .checking: return "ellipsis.circle"
        case .ready: return "checkmark.circle.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }
}

/// One 5pt dot per session, colored by state.
private struct StateDot: View {
    let state: SessionState

    var body: some View {
        Circle()
            .fill(PerchTheme.stateColor(state))
            .frame(width: 5, height: 5)
    }
}

/// Pulsing amber attention dot.
private struct AttentionDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(PerchTheme.attention)
            .frame(width: 6, height: 6)
            .scaleEffect(pulsing ? 1.25 : 0.8)
            .opacity(pulsing ? 1.0 : 0.55)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
