import SwiftUI
import PerchCore

/// The flagged-call card at the top of the expanded notch panel. Renders
/// `feed.focused`. Purely informational: Perch never answers the agent — the
/// decision happens in the terminal. Esc dismisses, ←/→ walk the feed
/// (keyDown routed by NotchController).
struct RiskCardView: View {
    @ObservedObject var feed: RiskFeed
    /// Showcase renders swap the ScrollView for a plain stack: ImageRenderer
    /// (the vector-crisp rasterizer) skips ScrollView contents entirely.
    var renderStatic = false

    var body: some View {
        if let entry = feed.focused {
            card(for: entry)
        }
    }

    private func card(for entry: RiskFeed.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(for: entry)
            riskBanner(for: entry.risk)
            inputPreview(for: entry)
            footer(for: entry)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(accentColor(for: entry.risk).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accentColor(for: entry.risk).opacity(0.35), lineWidth: 1)
        )
    }

    private func accentColor(for risk: RiskAssessment) -> Color {
        risk.level == .danger ? PerchTheme.danger : PerchTheme.attention
    }

    private func riskBanner(for risk: RiskAssessment) -> some View {
        let color: Color = risk.level == .danger ? PerchTheme.danger : PerchTheme.caution
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: risk.level == .danger
                      ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(risk.level == .danger ? "Flagged dangerous" : "Flagged for review")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
            }
            ForEach(risk.findings, id: \.code) { finding in
                Text("• \(finding.message)")
                    .font(.caption2)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(color.opacity(0.22), lineWidth: 1))
    }

    // MARK: - Pieces

    private func header(for entry: RiskFeed.Entry) -> some View {
        HStack(alignment: .center, spacing: 7) {
            AgentIconChip(agent: entry.key.agent, size: 20)
            Text(projectName(for: entry))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("·")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(entry.toolName)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if feed.count > 1 {
                HStack(spacing: 4) {
                    Text("\(focusedPosition) of \(feed.count)")
                        .monospacedDigit()
                    Text("←/→")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
    }

    private func inputPreview(for entry: RiskFeed.Entry) -> some View {
        Group {
            if renderStatic {
                inputText(for: entry)
            } else {
                ScrollView(.vertical) {
                    inputText(for: entry)
                }
            }
        }
        // A couple of lines always visible, up to ~8 before it scrolls.
        .frame(minHeight: 42, maxHeight: 110)
        .perchInset(cornerRadius: 9)
    }

    private func inputText(for entry: RiskFeed.Entry) -> some View {
        Text(prettyInput(entry.toolInput))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
    }

    private func footer(for entry: RiskFeed.Entry) -> some View {
        HStack(spacing: 8) {
            Button {
                feed.dismiss(id: entry.id)
            } label: {
                HStack(spacing: 5) {
                    Text("Dismiss")
                        .font(.caption.weight(.medium))
                    Text("esc")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(0.10))
                        )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            Text("Perch is read-only — decide in your terminal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private var focusedPosition: Int {
        guard let entry = feed.focused,
              let idx = feed.entries.firstIndex(where: { $0.id == entry.id }) else { return 1 }
        return idx + 1
    }

    private func projectName(for entry: RiskFeed.Entry) -> String {
        guard let cwd = entry.cwd, !cwd.isEmpty else { return "unknown" }
        return (cwd as NSString).lastPathComponent
    }

    private func prettyInput(_ input: JSONValue) -> String {
        if input.isNull { return "(no input)" }
        return input.encodedString(pretty: true)
    }
}
