import AppKit
import PerchCore
import SwiftUI

/// "Worktrees" window: the cross-project read-only audit of stale agent git
/// worktrees. Reports and classifies; the only affordance is copying
/// `git worktree remove` lines for the user to run themselves.
@MainActor
final class WorktreeWindowController {
    private let model: WorktreeModel
    private var window: NSWindow?

    init(model: WorktreeModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "Perch — Worktrees"
            w.isReleasedWhenClosed = false
            w.center()
            w.contentViewController = NSHostingController(rootView: WorktreeView(model: model))
            window = w
        }
        // Refresh when the data is stale (or never scanned) — the window is the
        // reason to look, so it's a good moment. No timer runs while it's open
        // beyond the global 30-minute cadence.
        let age = model.snapshot.scannedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if age > 300 { model.refresh() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct WorktreeView: View {
    @ObservedObject var model: WorktreeModel
    @State private var copied = false

    private var snapshot: WorktreeSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            summaryStrip
            Divider()
            list
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 460)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Stale worktrees")
                .font(.title3.weight(.semibold))
            if let at = snapshot.scannedAt {
                Text("scanned \(at.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.scanning {
                ProgressView().controlSize(.small)
            }
            Button("Refresh") { model.refresh() }
                .disabled(model.scanning)
        }
    }

    // MARK: - Summary strip

    private var summaryStrip: some View {
        let hasData = snapshot.scannedAt != nil
        return HStack(spacing: 12) {
            tile("Worktrees",
                 hasData ? "\(snapshot.totalCount)" : "—",
                 detail: hasData ? "in \(snapshot.repos.count) project\(snapshot.repos.count == 1 ? "" : "s")" : nil)
            tile("Total size",
                 hasData ? ByteFormat.fmt(snapshot.totalBytes) : "—")
            tile("Reclaimable",
                 hasData && snapshot.reclaimableCount > 0 ? ByteFormat.fmt(snapshot.reclaimableBytes) : (hasData ? "0" : "—"),
                 detail: hasData && snapshot.reclaimableCount > 0 ? "\(snapshot.reclaimableCount) worktree\(snapshot.reclaimableCount == 1 ? "" : "s")" : nil,
                 accent: true)
        }
    }

    private func tile(_ label: String, _ value: String, detail: String? = nil, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(accent ? Color.accentColor : Color.primary)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Grouped list

    @ViewBuilder
    private var list: some View {
        if snapshot.scannedAt == nil {
            centered(model.scanning ? "Scanning projects…" : "…")
        } else if snapshot.totalCount == 0 {
            centered("No worktrees found in your projects.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(snapshot.repos.sorted { $0.totalBytes > $1.totalBytes }) { repo in
                        section(repo)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func section(_ repo: RepoWorktrees) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(repo.projectName) — \(repo.worktrees.count) worktree\(repo.worktrees.count == 1 ? "" : "s") · \(ByteFormat.fmt(repo.totalBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(snapshot.sortedForDisplay(repo.worktrees)) { wt in
                row(wt)
                Divider().opacity(0.4)
            }
        }
    }

    private func row(_ wt: WorktreeInfo) -> some View {
        HStack(spacing: 8) {
            badge(snapshot.tier(wt))
            Text(wt.name)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("— \(snapshot.note(for: wt))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(wt.sizeBytes.map { ByteFormat.fmt($0) } ?? "…")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .help(wt.path)
    }

    private func badge(_ tier: WorktreeTier) -> some View {
        Text(tier.rawValue)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Self.badgeColor(tier))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Self.badgeColor(tier).opacity(0.16)))
    }

    private static func badgeColor(_ tier: WorktreeTier) -> Color {
        switch tier {
        case .active: return .green
        case .reclaimable: return .accentColor
        case .review: return .orange
        case .orphaned: return .gray
        }
    }

    private func centered(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center) {
            Text("Read-only — Perch never deletes. Commands run in your terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(copied ? "Copied" : "Copy cleanup commands (\(snapshot.reclaimableCount))") {
                copyCommands()
            }
            .disabled(snapshot.reclaimableCount == 0)
        }
    }

    private func copyCommands() {
        // Re-checked against CURRENT live sessions — the snapshot's tiers can
        // be up to a scan-interval old.
        let commands = model.cleanupCommandsNow()
        guard !commands.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}

/// One-line notch glance on the sessions page — styled like `UsageOverviewRow`.
/// Renders ONLY when there are reclaimable bytes; tapping opens the Worktrees
/// window. Deliberately never touches notch attention/badge state (garbage is
/// slow-moving and must not steal the notch's live-tempo attention).
struct WorktreeGlanceRow: View {
    @ObservedObject var model: WorktreeModel
    var onOpen: () -> Void

    var body: some View {
        if model.snapshot.reclaimableBytes > 0 {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: "tree")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("Worktrees")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(summaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var summaryText: String {
        let snap = model.snapshot
        return "\(snap.totalCount) · \(ByteFormat.fmt(snap.totalBytes)) · \(ByteFormat.fmt(snap.reclaimableBytes)) reclaimable"
    }
}
