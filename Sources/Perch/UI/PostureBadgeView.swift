import SwiftUI

/// One-line security posture strip at the top of the expanded notch panel:
/// rolling score (last hour of detections), grade, and what's driving it.
struct PostureBadgeView: View {
    @ObservedObject var posture: SecurityPosture

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text("Security")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("\(posture.score)")
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(posture.grade.rawValue)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(color.opacity(0.16)))
            Spacer(minLength: 8)
            if posture.dangerCount > 0 || posture.cautionCount > 0 {
                Text(driverText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(
                LinearGradient(colors: [color.opacity(0.18), color.opacity(0.09)],
                               startPoint: .leading, endPoint: .trailing))
        )
        .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 1))
    }

    private var color: Color {
        switch posture.grade {
        case .ok: return PerchTheme.running
        case .elevated: return PerchTheme.attention
        case .high: return PerchTheme.danger
        }
    }

    private var icon: String {
        switch posture.grade {
        case .ok: return "checkmark.shield.fill"
        case .elevated: return "exclamationmark.shield.fill"
        case .high: return "xmark.shield.fill"
        }
    }

    private var driverText: String {
        var parts: [String] = []
        if posture.dangerCount > 0 { parts.append("\(posture.dangerCount) danger") }
        if posture.cautionCount > 0 { parts.append("\(posture.cautionCount) caution") }
        return parts.joined(separator: " · ") + " · past hour"
    }
}
