import AppKit
import SwiftUI
import PerchCore

/// Plain NSWindow showing every session with all fields plus raw usage-window
/// values. First-line debugging surface before the notch UI existed; kept
/// around behind the menu bar "Debug Window" item.
@MainActor
final class DebugWindowController: NSObject {
    private let sessions: SessionStore
    private let usage: UsageStore
    private var window: NSWindow?

    init(sessions: SessionStore, usage: UsageStore) {
        self.sessions = sessions
        self.usage = usage
        super.init()
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: DebugRootView(sessions: sessions, usage: usage))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Perch Debug"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Controller (held by AppDelegate) keeps the window; closing just hides it.
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 780, height: 540))
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        window.setFrameAutosaveName("PerchDebugWindow")
        return window
    }
}

// MARK: - SwiftUI content

private struct DebugRootView: View {
    @ObservedObject var sessions: SessionStore
    @ObservedObject var usage: UsageStore

    var body: some View {
        List {
            Section("Sessions (\(sessions.sessions.count))") {
                if sessions.sessions.isEmpty {
                    Text("No sessions")
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions.sessions) { session in
                    SessionDebugRow(session: session)
                }
            }
            Section("Usage windows") {
                UsageDebugRow(label: "Claude 5h", window: usage.claudeFiveHour)
                UsageDebugRow(label: "Claude 7d", window: usage.claudeSevenDay)
                UsageDebugRow(label: "Codex primary (~5h)", window: usage.codexPrimary)
                UsageDebugRow(label: "Codex secondary (~weekly)", window: usage.codexSecondary)
            }
        }
        .listStyle(.inset)
        .font(.system(.caption, design: .monospaced))
        .frame(minWidth: 540, minHeight: 340)
    }
}

private struct SessionDebugRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(session.displayTitle)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Text("[\(session.key.agent.rawValue)]")
                    .foregroundStyle(.secondary)
            }
            field("key", "\(session.key.agent.rawValue)/\(session.key.id)")
            field("state", session.state.rawValue)
            field("live", session.isLive ? "yes" : "no")
            field("pid", session.pid.map(String.init))
            field("cwd", session.cwd)
            field("branch", session.gitBranch)
            field("model", session.model)
            field("entrypoint", session.entrypoint)
            field("version", session.version)
            field("startedAt", session.startedAt.map(Self.format))
            field("lastActivity", Self.format(session.lastActivity))
            field("attentionNote", session.attentionNote)
            field("tokens", "in \(session.inputTokens) · out \(session.outputTokens) · "
                + "cacheRead \(session.cacheReadTokens) · cacheCreate \(session.cacheCreationTokens) · "
                + "total \(session.totalTokens)")
            field("ctx", session.contextUsedPct.map { String(format: "%.1f%%", $0) }
                .map { pct in
                    session.contextWindowSize.map { "\(pct) of \($0)" } ?? pct
                })
            field("costUSD", session.costUSD.map { String(format: "%.4f", $0) })
            field("subagents", session.subagentCount > 0 ? "\(session.subagentCount)" : nil)
            field("transcript", session.transcriptPath)
            field("timeline", "\(session.timeline.count) events")
            field("lastPrompt", session.lastPrompt)
            field("lastAssistant", session.lastAssistantSnippet)
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }

    private var stateColor: Color {
        switch session.state {
        case .executing: return .green
        case .waitingPermission, .waitingInput: return .orange
        case .idle: return .gray
        case .ended, .unknown: return .secondary.opacity(0.4)
        }
    }

    @ViewBuilder
    private func field(_ name: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                Text("\(name):")
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
                Text(value)
                    .lineLimit(3)
            }
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

private struct UsageDebugRow: View {
    let label: String
    let window: UsageStore.RateWindow?

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .trailing)
            if let window {
                Text(describe(window))
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .textSelection(.enabled)
    }

    private func describe(_ w: UsageStore.RateWindow) -> String {
        var parts = [String(format: "used %.1f%%", w.usedPercentage)]
        if let resetsAt = w.resetsAt {
            parts.append("resetsAt \(resetsAt.formatted(date: .abbreviated, time: .standard))")
        }
        if let minutes = w.windowMinutes {
            parts.append("window \(minutes)m")
        }
        parts.append("updated \(w.updatedAt.formatted(date: .omitted, time: .standard))")
        return parts.joined(separator: " · ")
    }
}
