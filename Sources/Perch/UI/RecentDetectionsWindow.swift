import AppKit
import SwiftUI
import PerchCore

@MainActor
final class RecentDetectionsWindowController: NSWindowController {
    init(feed: RiskFeed, posture: SecurityPosture) {
        let root = RecentDetectionsView(feed: feed, posture: posture)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Recent Detections"
        window.contentViewController = hosting
        window.minSize = NSSize(width: 540, height: 400)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct RecentDetectionsView: View {
    @ObservedObject var feed: RiskFeed
    @ObservedObject var posture: SecurityPosture

    var body: some View {
        VStack(spacing: 0) {
            postureExplanation
            Divider()
            if feed.recent.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(feed.recent.reversed())) { entry in
                            detectionRow(entry)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 400)
    }

    private var postureExplanation: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(postureColor.opacity(0.14))
                Text("\(posture.score)")
                    .font(.title3.weight(.bold)).monospacedDigit()
                    .foregroundStyle(postureColor)
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("Security posture: \(posture.grade.rawValue)")
                        .font(.headline)
                    Text("PAST HOUR")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                Text("100 − 25 × \(posture.dangerCount) danger − 5 × \(posture.cautionCount) caution = \(posture.score)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("This score explains observed detections; it does not prove monitoring coverage. Check Monitoring Setup for coverage health.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background(postureColor.opacity(0.055))
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "checkmark.shield")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("No flagged calls in the past hour")
                .font(.headline)
            Text("A quiet history is meaningful only when Monitoring Setup shows active coverage.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func detectionRow(_ entry: RiskFeed.Entry) -> some View {
        let color: Color = entry.risk.level == .danger ? .red : .orange
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.risk.level == .danger
                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
                .font(.system(size: 16))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ToolSummary.summarize(toolName: entry.toolName, input: entry.toolInput))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    Text(entry.receivedAt, style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(metadata(for: entry))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(entry.risk.findings.enumerated()), id: \.offset) { _, finding in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(finding.code)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(color)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(color.opacity(0.10)))
                        Text(finding.message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.20)))
    }

    private func metadata(for entry: RiskFeed.Entry) -> String {
        let agent = entry.key.agent == .claude ? "Claude Code" : "Codex"
        let project = entry.cwd.map { ($0 as NSString).lastPathComponent }
        return [agent, project, entry.toolName].compactMap { $0 }.joined(separator: " · ")
    }

    private var postureColor: Color {
        switch posture.grade {
        case .ok: return .green
        case .elevated: return .orange
        case .high: return .red
        }
    }
}
