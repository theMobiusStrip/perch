import PerchCore
import SwiftUI

/// The notch's dedicated Skills Audit tab. The source list is a glance; every
/// row opens the full audit where registrations and scan limits stay visible.
struct SkillsAuditView: View {
    @ObservedObject var model: SkillAuditModel
    var onOpen: (String?) -> Void
    var renderStatic = false

    private var snapshot: SkillAuditSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if renderStatic {
                GeometryReader { geometry in
                    let warningHeight: CGFloat = (model.errorMessage == nil ? 0 : 38)
                        + (snapshot.issues.isEmpty ? 0 : 38)
                    let capacity = max(0, min(4, Int((geometry.size.height - warningHeight - 18) / 36)))
                    listContent(limit: capacity)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) { listContent() }
            }
            HStack(spacing: 5) {
                Text("User + known projects · bundled / plugins excluded")
                    .lineLimit(1)
                Spacer(minLength: 3)
                Label("Read-only", systemImage: "lock")
            }
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Read-only. Covers user skills and known projects. Bundled and plugin skills excluded.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text("Local skills").font(.system(size: 12, weight: .semibold))
                Text("Claude Code & Codex")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if model.scanning { ProgressView().controlSize(.mini) }
                Button { onOpen(nil) } label: {
                    HStack(spacing: 4) {
                        Text("Full audit")
                        Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PerchTheme.attention)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(PerchTheme.attention.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open full Skills Audit")
            }
            HStack(spacing: 5) {
                if snapshot.scannedAt != nil {
                    Text("\(snapshot.records.count) sources").foregroundStyle(.primary)
                    Text("· \(snapshot.discoverableCount) discoverable")
                    if snapshot.flaggedCount > 0 {
                        Text("· \(snapshot.flaggedCount) need review")
                            .foregroundStyle(PerchTheme.attention)
                    }
                } else {
                    Text(model.scanning ? "Scanning local discovery roots…" : "Local skills not scanned yet")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func listContent(limit: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.errorMessage {
                warning(error)
            }
            if !snapshot.issues.isEmpty {
                Button { onOpen(nil) } label: {
                    warning("\(snapshot.issues.count) scan issue\(snapshot.issues.count == 1 ? "" : "s") · Coverage incomplete — open audit")
                }
                .buttonStyle(.plain)
            }
            if snapshot.records.isEmpty {
                Text(emptyText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ForEach(limit.map { Array(snapshot.sortedRecords.prefix($0)) } ?? snapshot.sortedRecords) { record in
                    Button { onOpen(record.id) } label: { row(record) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(record.name), \(record.statusLabel), \(SkillsAuditPresentation.agents(record)). Open details.")
                        .help(record.sourcePath)
                }
                if let limit, snapshot.records.count > limit {
                    Text("+ \(snapshot.records.count - limit) more in full audit")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private var emptyText: String {
        if snapshot.scannedAt == nil {
            return model.scanning ? "Reading skill metadata…" : "Open full audit to scan local skills."
        }
        return snapshot.issues.isEmpty && model.errorMessage == nil
            ? "No local skills found in covered roots."
            : "No sources available. Review scan issues for missing coverage."
    }

    private func row(_ record: SkillRecord) -> some View {
        HStack(spacing: 7) {
            Circle().fill(SkillsAuditPresentation.color(record)).frame(width: 5, height: 5)
            Text(record.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(SkillsAuditPresentation.agents(record))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            SkillStatusBadge(label: record.statusLabel, highlighted: record.needsReview)
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(record.needsReview ? PerchTheme.attention.opacity(0.06) : PerchTheme.cardFill,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(record.needsReview ? PerchTheme.attention.opacity(0.19) : PerchTheme.cardBorder, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func warning(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: 9))
            .foregroundStyle(PerchTheme.attention)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(PerchTheme.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Presentation-only labels. Reviewed/unchanged states stay neutral: neither is
/// evidence that a skill's instructions or scripts are safe.
enum SkillsAuditPresentation {
    static func color(_ record: SkillRecord) -> Color {
        record.needsReview ? PerchTheme.attention : PerchTheme.idle
    }

    static func agents(_ record: SkillRecord) -> String {
        AgentKind.allCases.filter { agent in record.registrations.contains { $0.agent == agent } }
            .map { $0 == .claude ? "Claude" : "Codex" }.joined(separator: " + ")
    }

    static func scopes(_ record: SkillRecord) -> String {
        SkillScope.allCases.filter { scope in record.registrations.contains { $0.scope == scope } }
            .map(\.rawValue).joined(separator: " + ")
    }
}

struct SkillStatusBadge: View {
    var label: String
    var highlighted = false

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(highlighted ? PerchTheme.attention : Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(highlighted ? PerchTheme.attention.opacity(0.13) : PerchTheme.cardFill, in: Capsule())
            .fixedSize()
    }
}
