import AppKit
import PerchCore
import SwiftUI

/// One source at a time. Identity is supplied by the browser so switching
/// sources resets scroll/disclosures while refresh preserves the current view.
struct SkillAuditInspector: View {
    let record: SkillRecord
    var scanning: Bool
    var renderStatic = false
    var position: String
    var canGoBack: Bool
    var canGoForward: Bool
    var goBack: () -> Void
    var goForward: () -> Void
    var review: () -> Void
    @State private var showRegistrations = false
    @State private var showFingerprint = false
    @State private var copiedValue: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SOURCE DETAILS")
                    .font(.system(size: 10, weight: .semibold)).tracking(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(position).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                navigationButton("Previous source", icon: "chevron.left", disabled: !canGoBack, action: goBack)
                navigationButton("Next source", icon: "chevron.right", disabled: !canGoForward, action: goForward)
            }
            .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 8)
            if renderStatic {
                contents
                Spacer(minLength: 0)
            } else {
                ScrollView { contents }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            reviewDock
        }
        .task(id: copiedValue) {
            guard copiedValue != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedValue = nil
        }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Text(record.name).font(.system(size: 24, weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    SkillStatusBadge(label: record.statusLabel, highlighted: record.needsReview)
                        .padding(.top, 6)
                }
                Text(record.description.isEmpty ? "No description provided by this skill." : record.description)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label(SkillsAuditPresentation.agents(record), systemImage: "person.2")
                    Label(SkillsAuditPresentation.scopes(record), systemImage: "folder")
                    if record.isShared { Label("Shared source", systemImage: "link") }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            reviewNotice
            sourceLocation
            contentsSummary
            disclosure(title: "Registrations", subtitle: "\(record.registrations.count) local connection\(record.registrations.count == 1 ? "" : "s")",
                       expanded: $showRegistrations) {
                VStack(spacing: 8) {
                    ForEach(record.registrations) { registrationRow($0) }
                }
            }
            disclosure(title: "Fingerprint", subtitle: "Content & registration identity",
                       expanded: $showFingerprint) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(record.fingerprint.isEmpty ? "Fingerprint unavailable" : record.fingerprint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !record.fingerprint.isEmpty {
                        SkillAuditAction(title: copiedValue == record.fingerprint ? "Copied" : "Copy fingerprint",
                                         icon: "doc.on.doc", renderStatic: renderStatic) {
                            copyValue(record.fingerprint)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var reviewNotice: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: record.needsReview ? "eye" : record.isReviewed ? "checkmark.circle" : "square.stack")
                .font(.system(size: 17, weight: .regular)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 7) {
                Text(noticeTitle).font(.system(size: 13, weight: .semibold))
                if !record.issues.isEmpty {
                    Text(SkillIssue.allCases.filter(record.issues.contains).map(\.label).joined(separator: " · "))
                        .font(.system(size: 9, weight: .medium))
                }
                ForEach(Array(record.notes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.system(size: 12)).textSelection(.enabled)
                }
                if record.notes.isEmpty {
                    Text(record.isReviewed ? "Content and registrations match the fingerprint you reviewed." :
                            "Found on disk. This does not tell us whether an agent has loaded or enabled it.")
                        .font(.system(size: 12))
                }
                if !record.canReview {
                    Text("Review is unavailable until the source can be read and checked completely.")
                        .font(.system(size: 11))
                }
            }
        }
        .foregroundStyle(record.needsReview ? PerchTheme.attention : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(record.needsReview ? PerchTheme.attention.opacity(0.07) : PerchTheme.cardFill,
                    in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(record.needsReview ? PerchTheme.attention.opacity(0.16) : PerchTheme.cardBorder))
    }

    private var noticeTitle: String {
        if record.issues.contains(.brokenLink) { return "This connection needs a look" }
        if !record.canReview { return "A complete review isn't available yet" }
        if record.issues.contains(.changed) { return "Worth another look" }
        if record.needsReview { return "Something needs your attention" }
        return record.isReviewed ? "Matches your last review" : "Ready for your first review"
    }

    private var sourceLocation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(record.isShared ? "One source, shared across registrations" : "Source location")
                .font(.system(size: 12, weight: .medium))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(.secondary)
                Text(record.sourcePath).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                SkillAuditAction(title: "Reveal in Finder", icon: "folder",
                                 disabled: record.issues.contains(.brokenLink),
                                 renderStatic: renderStatic) { Self.reveal(record.sourcePath) }
                SkillAuditAction(title: copiedValue == record.sourcePath ? "Copied" : "Copy path",
                                 icon: "doc.on.doc", renderStatic: renderStatic) { copyValue(record.sourcePath) }
                Spacer(minLength: 0)
            }
            if let modified = record.lastModified {
                Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(13).perchInset(cornerRadius: 10)
    }

    private var contentsSummary: some View {
        HStack(spacing: 0) {
            contentCount(record.counts.total, label: "Files")
            Divider().frame(height: 26)
            contentCount(record.counts.scripts, label: "Scripts")
            Divider().frame(height: 26)
            contentCount(record.counts.references, label: "References")
            Divider().frame(height: 26)
            contentCount(record.counts.assets, label: "Assets")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func contentCount(_ count: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(count)").font(.system(size: 17, weight: .medium)).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func disclosure<Content: View>(title: String, subtitle: String,
                                           expanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 12)
                    Text(title).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(expanded.wrappedValue ? "expanded" : "collapsed")")
            if expanded.wrappedValue { content() }
        }
    }

    private func registrationRow(_ registration: SkillRegistration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgentIconChip(agent: registration.agent, size: 18)
                Text(registration.agent == .claude ? "Claude Code" : "Codex")
                    .font(.system(size: 11, weight: .medium))
                Text(registration.scope.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                SkillStatusBadge(label: registration.isSymlink ? "SYMLINK" : "DIRECT")
                if !registration.isDiscoverable { SkillStatusBadge(label: "UNAVAILABLE", highlighted: true) }
            }
            Text(registration.path).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let project = registration.projectPath {
                Text("Project: \(project)").font(.system(size: 10)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                SkillAuditAction(title: copiedValue == registration.path ? "Copied" : "Copy path",
                                 icon: "doc.on.doc", renderStatic: renderStatic) { copyValue(registration.path) }
                SkillAuditAction(title: "Reveal registration", icon: "folder",
                                 renderStatic: renderStatic) { Self.reveal(registration.path) }
            }
        }
        .padding(11).perchCard(cornerRadius: 9)
    }

    private var reviewDock: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.isReviewed ? "Review recorded" : "Looked through this source?")
                        .font(.system(size: 12, weight: .medium))
                    Text(record.isReviewed ? "A later change will need another look." :
                            record.canReview ? "Keep this fingerprint as your review baseline." : "Incomplete or invalid sources can't be marked reviewed.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SkillAuditAction(title: record.isReviewed ? "Reviewed" : "Mark reviewed", icon: "checkmark",
                                 prominent: true, disabled: !record.canReview || record.isReviewed || scanning,
                                 renderStatic: renderStatic, action: review)
                    .help("Record only the displayed fingerprint. This does not approve or run a skill.")
            }
            Text("Reviewed ≠ safe. Perch never approves, edits, or runs your skills.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22).padding(.vertical, 15)
        .background(Color.white.opacity(0.025))
    }

    private func navigationButton(_ title: String, icon: String, disabled: Bool,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(PerchTheme.cardFill, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityLabel(title).help(title)
    }

    private func copyValue(_ value: String) {
        Self.copy(value)
        copiedValue = value
    }

    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// SwiftUI-only styling keeps live controls and synthetic previews consistent.
struct SkillAuditAction: View {
    var title: String
    var icon: String
    var prominent = false
    var disabled = false
    var renderStatic = false
    var action: () -> Void

    var body: some View {
        if renderStatic {
            actionLabel.opacity(disabled ? 0.4 : 1)
        } else {
            Button(action: action) { actionLabel }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1)
        }
    }

    private var actionLabel: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(prominent ? Color.black.opacity(0.88) : Color.primary)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(prominent ? PerchTheme.attention : PerchTheme.cardFill,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(prominent ? Color.clear : PerchTheme.cardBorder))
            .contentShape(Rectangle())
    }
}
