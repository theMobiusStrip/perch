import AppKit
import PerchCore
import SwiftUI

@MainActor
final class SkillsAuditWindowController {
    private let model: SkillAuditModel
    private var window: NSWindow?

    init(model: SkillAuditModel) { self.model = model }

    func show(selecting id: String? = nil) {
        if let id { model.select(id) }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Perch — Skills Audit"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 900, height: 620)
            if !w.setFrameUsingName("PerchSkillsAudit") { w.center() }
            w.setFrameAutosaveName("PerchSkillsAudit")
            w.contentViewController = NSHostingController(rootView: SkillsAuditDetailView(model: model))
            window = w
        }
        let age = model.snapshot.scannedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if age > 300 { model.refresh() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SkillsAuditDetailView: View {
    @ObservedObject var model: SkillAuditModel
    var renderStatic = false
    @State private var query = SkillAuditQuery()
    @State private var showCoverage = false
    @State private var reviewReceipt: String?
    @FocusState private var searchFocused: Bool

    private var snapshot: SkillAuditSnapshot { model.snapshot }
    private var visibleRecords: [SkillRecord] { query.records(in: snapshot) }
    private var selected: SkillRecord? {
        visibleRecords.first { $0.id == model.selectedSkillID } ?? visibleRecords.first
    }
    private var attentionCount: Int { snapshot.records.filter(\.needsReview).count }
    private var hasCoverageIssues: Bool { model.errorMessage != nil || !snapshot.issues.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            if hasCoverageIssues { coverageNotice }
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 302)
                Divider()
                if let selected {
                    SkillAuditInspector(record: selected, scanning: model.scanning,
                                        renderStatic: renderStatic,
                                        position: selectedPosition,
                                        canGoBack: selectedIndex > 0,
                                        canGoForward: selectedIndex + 1 < visibleRecords.count,
                                        goBack: { moveSelection(-1) },
                                        goForward: { moveSelection(1) },
                                        review: {
                        if model.acknowledge(selected) {
                            reviewReceipt = "Review recorded for \(selected.name)."
                        }
                    })
                    .id(selected.id)
                } else {
                    emptyDetail
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 880, minHeight: 570)
        .background(Color(red: 0.065, green: 0.069, blue: 0.08))
        .preferredColorScheme(.dark)
        .onAppear { revealRequestedSelection(); reconcileSelection() }
        .onChange(of: visibleRecords.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: model.selectionRequest) { _, _ in revealRequestedSelection() }
        .task(id: reviewReceipt) {
            guard reviewReceipt != nil else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            reviewReceipt = nil
        }
        .background {
            // Window-local shortcuts. Arrow-key selection comes from the
            // native list; command-F never competes with typing in search.
            Button { searchFocused = true } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(PerchTheme.attention)
                .frame(width: 46, height: 46)
                .background(PerchTheme.attention.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text("Skills Audit").font(.system(size: 20, weight: .semibold))
                Text(briefing)
                    .font(.system(size: 12))
                    .foregroundStyle(attentionCount > 0 ? PerchTheme.attention : Color.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                SkillAuditAction(title: model.scanning ? "Checking…" : "Check now",
                                 icon: "arrow.clockwise", disabled: model.scanning,
                                 renderStatic: renderStatic) { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Rescan local skills. Your filters and selected source stay in place.")
                Text("Local only · You're in control")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var briefing: String {
        if snapshot.scannedAt == nil {
            return model.scanning ? "Getting your local skill library ready…" : "Your local skill library, in one place."
        }
        if attentionCount > 0 {
            return "\(attentionCount) source\(attentionCount == 1 ? "" : "s") need\(attentionCount == 1 ? "s" : "") a closer look."
        }
        if hasCoverageIssues { return "Some locations couldn't be checked. Review coverage below." }
        if snapshot.records.isEmpty { return "No skills found in the locations checked." }
        return "No source findings in this scan. Your library is ready to browse."
    }

    private var coverageNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showCoverage.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(model.errorMessage != nil ? "Review storage needs attention" :
                            "\(snapshot.issues.count) scan issue\(snapshot.issues.count == 1 ? "" : "s") · Coverage incomplete")
                        .fontWeight(.medium)
                    Spacer()
                    Text(showCoverage ? "Hide details" : "Show details")
                    Image(systemName: showCoverage ? "chevron.up" : "chevron.down")
                }
                .font(.system(size: 11))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showCoverage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error = model.errorMessage { Text(error).textSelection(.enabled) }
                        ForEach(snapshot.issues) { issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(issue.issue.label) · \(issue.message)")
                                Text(issue.path).font(.system(size: 10, design: .monospaced))
                            }
                            .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 80)
                .font(.system(size: 11))
            }
        }
        .foregroundStyle(PerchTheme.attention)
        .padding(10)
        .background(PerchTheme.attention.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("YOUR LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1)
                    Spacer()
                    Text("\(snapshot.records.count) sources").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    statusFilter(.all, title: "All")
                    statusFilter(.attention, title: "Attention")
                    statusFilter(.reviewed, title: "Reviewed")
                }
                .padding(3)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                searchField
                HStack(spacing: 8) {
                    agentPicker
                    scopePicker
                }
                HStack {
                    Text("\(visibleRecords.count) shown")
                    if query.hasFilters {
                        Button("Reset") { query.resetFilters() }
                            .buttonStyle(.plain).foregroundStyle(PerchTheme.attention)
                            .help("Clear search, agent, scope, and status filters")
                    }
                    Spacer(minLength: 3)
                    sortPicker
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider().padding(.horizontal, 14)
            if visibleRecords.isEmpty {
                Text(snapshot.scannedAt == nil ? "Waiting for a scan…" : "No matching sources")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                Spacer(minLength: 0)
            } else if renderStatic {
                VStack(spacing: 4) {
                    ForEach(visibleRecords) { sourceRow($0) }
                }
                .padding(10)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    List(selection: Binding(get: { model.selectedSkillID }, set: {
                        model.selectedSkillID = SkillAuditQuery.reconciledSelection($0, records: visibleRecords)
                    })) {
                        ForEach(visibleRecords) { record in
                            sourceRow(record)
                                .tag(record.id)
                                .id(record.id)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                .contextMenu {
                                    Button("Copy source path") { SkillAuditInspector.copy(record.sourcePath) }
                                    Button("Reveal in Finder") { SkillAuditInspector.reveal(record.sourcePath) }
                                        .disabled(record.issues.contains(.brokenLink))
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .tint(PerchTheme.attention)
                    .accessibilityLabel("Skill sources. Use arrow keys to select a source.")
                    .onChange(of: model.selectedSkillID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                    .onChange(of: visibleRecords.map(\.id)) { _, _ in
                        if let id = selected?.id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .background(Color.black.opacity(0.13))
    }

    private func statusFilter(_ status: SkillAuditStatusFilter, title: String) -> some View {
        Button { query.status = status } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("\(query.count(status, in: snapshot))").monospacedDigit()
                    .foregroundStyle(query.status == status ? Color.primary : Color.secondary)
            }
            .font(.system(size: 10, weight: query.status == status ? .semibold : .regular))
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(query.status == status ? Color.white.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(query.count(status, in: snapshot)) sources")
        .accessibilityAddTraits(query.status == status ? .isSelected : [])
        .help(status == .attention ? "Sources with findings. Scan coverage issues are shown separately." :
                status == .reviewed ? "Sources matching a recorded fingerprint. Reviewed does not mean safe." : "All matching sources")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            if renderStatic {
                Text("Find a skill or path").foregroundStyle(.tertiary)
                Spacer()
                Text("⌘F").foregroundStyle(.tertiary)
            } else {
                TextField("Find a skill or path", text: $query.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search skills by name, description, or path")
                    .onExitCommand { query.search = "" }
                if !query.search.isEmpty {
                    Button { query.search = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
        }
        .font(.system(size: 12))
        .padding(9).perchInset()
    }

    @ViewBuilder
    private var agentPicker: some View {
        if renderStatic {
            staticMenu("All agents", icon: "person.2")
        } else {
            Picker("Agent", selection: $query.agent) {
                Text("All agents").tag(AgentKind?.none)
                Text("Claude Code").tag(AgentKind?.some(.claude))
                Text("Codex").tag(AgentKind?.some(.codex))
            }
            .labelsHidden().accessibilityLabel("Filter by agent").controlSize(.small)
        }
    }

    @ViewBuilder
    private var scopePicker: some View {
        if renderStatic {
            staticMenu("All locations", icon: "folder")
        } else {
            Picker("Location", selection: $query.scope) {
                Text("All locations").tag(SkillScope?.none)
                Text("User skills").tag(SkillScope?.some(.user))
                Text("Project skills").tag(SkillScope?.some(.project))
            }
            .labelsHidden().accessibilityLabel("Filter by location").controlSize(.small)
        }
    }

    @ViewBuilder
    private var sortPicker: some View {
        if renderStatic {
            Label("Attention first", systemImage: "arrow.up.arrow.down")
        } else {
            Picker("Sort", selection: $query.sort) {
                Text("Attention first").tag(SkillAuditSort.attention)
                Text("Name A–Z").tag(SkillAuditSort.name)
                Text("Recently modified").tag(SkillAuditSort.recentlyModified)
            }
            .labelsHidden().accessibilityLabel("Sort skills").controlSize(.mini)
            .fixedSize()
        }
    }

    private func staticMenu(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: 8))
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(7).perchInset()
    }

    private func sourceRow(_ record: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: record.needsReview ? "circle.dotted" : "square.stack")
                    .foregroundStyle(SkillsAuditPresentation.color(record))
                Text(record.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if record.isShared {
                    Image(systemName: "link").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            HStack(spacing: 4) {
                Text(SkillsAuditPresentation.agents(record))
                Text("· \(SkillsAuditPresentation.scopes(record))")
                Spacer(minLength: 0)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            SkillStatusBadge(label: record.statusLabel, highlighted: record.needsReview)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected?.id == record.id ? PerchTheme.attention.opacity(0.09) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(selected?.id == record.id ? PerchTheme.attention.opacity(0.23) : Color.clear))
        .contentShape(Rectangle())
        .help(record.sourcePath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(record.name), \(record.statusLabel), \(SkillsAuditPresentation.agents(record)), \(SkillsAuditPresentation.scopes(record))")
        .accessibilityAddTraits(selected?.id == record.id ? .isSelected : [])
    }

    private var selectedIndex: Int { visibleRecords.firstIndex { $0.id == selected?.id } ?? 0 }
    private var selectedPosition: String { "\(selectedIndex + 1) of \(visibleRecords.count)" }

    private func moveSelection(_ offset: Int) {
        let target = selectedIndex + offset
        guard visibleRecords.indices.contains(target) else { return }
        model.selectedSkillID = visibleRecords[target].id
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
            Text(snapshot.scannedAt == nil ? (model.scanning ? "Checking local skills…" : "Your library starts here") :
                    snapshot.records.isEmpty ? "No sources in the locations checked" : "Nothing matches these filters")
                .font(.system(size: 17, weight: .medium))
            Text(query.hasFilters ? "Clear your filters to see the rest of your library." :
                    "User skills and known projects appear here after a scan.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if query.hasFilters {
                SkillAuditAction(title: "Show all skills", icon: "line.3.horizontal.decrease.circle",
                                 renderStatic: renderStatic) { query.resetFilters() }
            } else if !model.scanning {
                SkillAuditAction(title: "Check now", icon: "arrow.clockwise",
                                 renderStatic: renderStatic) { model.refresh() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let reviewReceipt {
                Label(reviewReceipt, systemImage: "checkmark")
                    .foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel(reviewReceipt + " Fingerprint only; not a safety verdict.")
            }
            HStack {
                Label("Read-only · Never runs skills", systemImage: "lock")
                Spacer()
                if let scanned = snapshot.scannedAt {
                    Text("\(snapshot.rootsScanned) roots · Checked \(scanned.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text(model.scanning ? "Checking…" : "Not checked yet")
                }
            }
            HStack {
                Text("User + known projects · Bundled, plugin, synced, admin & remote skills excluded")
                Spacer()
                Text("Auto-checks about every 2 min")
            }
            .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 11)
    }

    private func reconcileSelection() {
        model.selectedSkillID = SkillAuditQuery.reconciledSelection(model.selectedSkillID, records: visibleRecords)
    }

    private func revealRequestedSelection() {
        guard let id = model.selectedSkillID, snapshot.records.contains(where: { $0.id == id }),
              !visibleRecords.contains(where: { $0.id == id }) else { return }
        query.resetFilters()
    }
}

/// Fictional data for native showcase rendering; no machine paths are sampled.
enum SkillsAuditDemo {
    static func snapshot(now: Date = Date()) -> SkillAuditSnapshot {
        func registrations(_ name: String, agents: [AgentKind] = [.claude, .codex]) -> [SkillRegistration] {
            agents.map { agent in
                SkillRegistration(agent: agent, scope: .user,
                                  path: "/Example/\(agent == .claude ? ".claude" : ".agents")/skills/\(name)",
                                  isSymlink: true)
            }
        }
        return SkillAuditSnapshot(records: [
            SkillRecord(id: "code-review", name: "code-review",
                        description: "Review code changes for correctness, regressions, and missing tests.",
                        sourcePath: "/Example/ai-skills/code-review", registrations: registrations("code-review"),
                        issues: [.changed], notes: ["Content differs from the reviewed fingerprint. Inspect the source before recording a new review."],
                        fingerprint: "a51e7b90945a0c8ef82164b3ba27a1ab6863c756614030286c8981fa4c316d84",
                        lastModified: now.addingTimeInterval(-720),
                        counts: SkillFileCounts(scripts: 1, references: 2, total: 4)),
            SkillRecord(id: "api-contracts", name: "api-contracts",
                        description: "Check API schema changes against the project contract.",
                        sourcePath: "/Example/ai-skills/api-contracts",
                        registrations: [SkillRegistration(agent: .codex, scope: .project,
                            path: "/Example/api-server/.agents/skills/api-contracts", projectPath: "/Example/api-server",
                            isSymlink: true, isDiscoverable: false)],
                        issues: [.brokenLink], notes: ["The registration exists, but its symlink target is missing."]),
            SkillRecord(id: "repo-harness", name: "repo-harness",
                        description: "Check repository policies and prepare consistent verification steps.",
                        sourcePath: "/Example/ai-skills/repo-harness", registrations: registrations("repo-harness"),
                        fingerprint: String(repeating: "7c3d80f1", count: 8), lastModified: now.addingTimeInterval(-259200),
                        counts: SkillFileCounts(scripts: 2, references: 3, total: 6), isReviewed: true),
            SkillRecord(id: "swift-testing", name: "swift-testing",
                        description: "Plan focused tests for Swift models and application behavior.",
                        sourcePath: "/Example/desktop-app/.claude/skills/swift-testing",
                        registrations: [SkillRegistration(agent: .claude, scope: .project,
                            path: "/Example/desktop-app/.claude/skills/swift-testing", projectPath: "/Example/desktop-app")],
                        fingerprint: String(repeating: "b60832a4", count: 8), lastModified: now.addingTimeInterval(-432000),
                        counts: SkillFileCounts(references: 1, total: 2)),
            SkillRecord(id: "release-checklist", name: "release-checklist",
                        description: "Inspect release artifacts and document verification results.",
                        sourcePath: "/Example/ai-skills/release-checklist", registrations: registrations("release-checklist"),
                        fingerprint: String(repeating: "33e174d0", count: 8), lastModified: now.addingTimeInterval(-604800),
                        counts: SkillFileCounts(references: 2, total: 3))
        ], scannedAt: now, rootsScanned: 4)
    }
}
