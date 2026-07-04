import SwiftUI

/// One-line security posture strip at the top of the expanded notch panel:
/// rolling score (last hour of detections), grade, and what's driving it.
struct PostureBadgeView: View {
    @ObservedObject var posture: SecurityPosture

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text("Security \(posture.score)")
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(posture.grade.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if posture.dangerCount > 0 || posture.cautionCount > 0 {
                Text(driverText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.13)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
    }

    private var color: Color {
        switch posture.grade {
        case .ok: return .green
        case .elevated: return .orange
        case .high: return .red
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
