import SwiftUI

/// Collapsed notch content: count of live sessions + tiny per-state dots
/// (green executing / gray idle / amber attention pulse).
struct PillView: View {
    @ObservedObject var sessions: SessionStore
    let hasAttention: Bool

    private var liveSessions: [Session] {
        sessions.sessions.filter(\.isLive)
    }

    var body: some View {
        HStack(spacing: 6) {
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
}

/// One 5pt dot per session, colored by state.
private struct StateDot: View {
    let state: SessionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
    }

    private var color: Color {
        switch state {
        case .executing:
            return .green
        case .waitingPermission, .waitingInput:
            return .orange
        case .idle:
            return Color(white: 0.6)
        case .ended, .unknown:
            return Color(white: 0.35)
        }
    }
}

/// Pulsing amber attention dot.
private struct AttentionDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .scaleEffect(pulsing ? 1.25 : 0.8)
            .opacity(pulsing ? 1.0 : 0.55)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
