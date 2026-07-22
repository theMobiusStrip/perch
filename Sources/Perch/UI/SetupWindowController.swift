import AppKit
import SwiftUI
import PerchCore

@MainActor
final class SetupViewModel: ObservableObject {
    enum ResultTarget: Hashable {
        case claude
        case codex
        case doctor
    }

    enum Outcome: Equatable {
        case success
        case attention
        case failure
    }

    enum Operation: Equatable {
        case installClaude
        case installCodex
        case uninstallClaude
        case uninstallCodex
        case doctor

        var title: String {
            switch self {
            case .installClaude: return "Installing Claude Code monitoring…"
            case .installCodex: return "Installing Codex monitoring…"
            case .uninstallClaude: return "Removing Claude Code monitoring…"
            case .uninstallCodex: return "Removing Codex monitoring…"
            case .doctor: return "Running Doctor…"
            }
        }

        var target: ResultTarget {
            switch self {
            case .installClaude, .uninstallClaude: return .claude
            case .installCodex, .uninstallCodex: return .codex
            case .doctor: return .doctor
            }
        }
    }

    struct Result {
        let title: String
        let text: String
        let outcome: Outcome
        let checks: [MonitoringCheck]
    }

    @Published private(set) var operation: Operation?
    @Published private(set) var results: [ResultTarget: Result] = [:]

    let health: MonitoringHealth
    let preferences: NotificationPreferences
    private let notifier: Notifier
    var onDone: (() -> Void)?

    init(health: MonitoringHealth, preferences: NotificationPreferences,
         notifier: Notifier) {
        self.health = health
        self.preferences = preferences
        self.notifier = notifier
    }

    func refresh() {
        health.refresh()
        notifier.authorizationState { [weak health] state in
            health?.updateNotificationState(state)
        }
    }

    func installClaude() {
        health.clearVerification(for: .claude)
        perform(.installClaude) {
            Self.runInstall(title: "Claude Code monitoring") {
                _ = try BridgeDeployer.deploy()
                return try ClaudeHookInstaller.install()
            } verify: {
                ClaudeHookInstaller.installationStatus().isReady
            }
        }
    }

    func installCodex() {
        health.clearVerification(for: .codex)
        perform(.installCodex) {
            Self.runInstall(title: "Codex monitoring") {
                _ = try BridgeDeployer.deploy()
                var report = try CodexHookInstaller.install()
                report.notes += CodexHookTrust.ensureTrusted()
                return report
            } verify: {
                CodexHookInstaller.installationStatus().isReady
                    && (CodexHookTrust.storedTrustRecordCount() ?? 0) > 0
            }
        }
    }

    func uninstallClaude() {
        health.clearVerification(for: .claude)
        perform(.uninstallClaude) {
            Self.runInstall(title: "Claude Code monitoring") {
                try ClaudeHookInstaller.uninstall()
            }
        }
    }

    func uninstallCodex() {
        health.clearVerification(for: .codex)
        perform(.uninstallCodex) {
            Self.runInstall(title: "Codex monitoring") {
                try CodexHookInstaller.uninstall()
            }
        }
    }

    func runDoctor() {
        perform(.doctor) {
            let report = Doctor.diagnose()
            return Result(title: "Perch Doctor", text: report.text,
                          outcome: Self.outcome(for: report.state), checks: report.checks)
        }
    }

    func requestNotifications() {
        notifier.requestAuthorization { [weak self] state in
            self?.health.updateNotificationState(state)
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func finish() {
        preferences.markSetupCompleted()
        onDone?()
    }

    func result(for target: ResultTarget) -> Result? {
        results[target]
    }

    private func perform(_ operation: Operation, work: @escaping () -> Result) {
        guard self.operation == nil else { return }
        self.operation = operation
        results[operation.target] = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.operation = nil
                self.results[operation.target] = result
                self.refresh()
            }
        }
    }

    private static func runInstall(title: String,
                                   _ body: () throws -> InstallReport,
                                   verify: (() -> Bool)? = nil) -> Result {
        do {
            let report = try body()
            let verified = verify?()
            let outcome: Outcome = verified == false ? .attention : .success
            let text = verified == false
                ? report.summaryText
                    + "\nStatic verification still needs attention. Review the status above or run Doctor."
                : report.summaryText
            return Result(title: title, text: text,
                          outcome: outcome, checks: [])
        } catch {
            return Result(title: title, text: error.localizedDescription,
                          outcome: .failure, checks: [])
        }
    }

    static func outcome(for state: MonitoringCheckState) -> Outcome {
        switch state {
        case .ready: return .success
        case .checking, .needsAttention: return .attention
        case .unavailable: return .failure
        }
    }
}

@MainActor
final class SetupWindowController: NSWindowController {
    private let model: SetupViewModel

    init(health: MonitoringHealth, preferences: NotificationPreferences,
         notifier: Notifier) {
        let model = SetupViewModel(health: health, preferences: preferences,
                                   notifier: notifier)
        self.model = model

        let root = SetupView(model: model, health: health, preferences: preferences)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Perch Monitoring Setup"
        window.contentViewController = hosting
        window.minSize = NSSize(width: 580, height: 580)
        window.center()
        super.init(window: window)

        model.onDone = { [weak self] in self?.window?.close() }
    }

    required init?(coder: NSCoder) { nil }

    func show(runDoctor: Bool = false) {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.refresh()
        if runDoctor { model.runDoctor() }
    }
}

private struct SetupView: View {
    @ObservedObject var model: SetupViewModel
    @ObservedObject var health: MonitoringHealth
    @ObservedObject var preferences: NotificationPreferences

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    runtimeSection
                    integrationsSection
                    verificationSection
                    notificationsSection
                    doctorSection
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Refresh") { model.refresh() }
                    .disabled(health.isRefreshing || model.operation != nil)
                Spacer()
                Button("Done") { model.finish() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 580, minHeight: 580)
    }

    private var header: some View {
        let presentation = health.presentation
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon(for: presentation.state))
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(color(for: presentation.state))
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.title)
                    .font(.title2.weight(.semibold))
                Text(presentation.summary)
                    .foregroundStyle(.secondary)
                Text("Coverage and detections are read-only. Perch observes; it never approves, denies, or blocks an agent action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastEventAt = health.lastEventAt {
                    Text("Last verified hook event \(lastEventAt, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if health.snapshot.state == .ready {
                    Text("Static checks passed · waiting for a real hook event")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if health.isRefreshing { ProgressView().controlSize(.small) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(color(for: presentation.state).opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(color(for: presentation.state).opacity(0.25)))
    }

    private var runtimeSection: some View {
        section("Local runtime", subtitle: "Both checks must pass before hooks can deliver events.") {
            checkRow(health.snapshot.bridge)
            Divider()
            checkRow(health.snapshot.socket)
        }
    }

    private var integrationsSection: some View {
        section("Agent integrations", subtitle: "Install at least one integration for tool-risk coverage.") {
            integrationRow(health.snapshot.claude,
                           target: .claude,
                           install: model.installClaude, uninstall: model.uninstallClaude)
            Divider()
            integrationRow(health.snapshot.codex,
                           target: .codex,
                           install: model.installCodex, uninstall: model.uninstallCodex)
        }
    }

    private var verificationSection: some View {
        section("Live verification",
                subtitle: "A real hook event confirms the configured path works end to end.") {
            if health.snapshot.configuredAgents.isEmpty {
                Text("Install an integration above, then start or restart its agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if health.snapshot.claude.isReady {
                    verificationRow(.claude)
                }
                if health.snapshot.claude.isReady && health.snapshot.codex.isReady {
                    Divider()
                }
                if health.snapshot.codex.isReady {
                    verificationRow(.codex)
                }
            }
        }
    }

    private var notificationsSection: some View {
        section("Notifications", subtitle: "Choose which local events may interrupt you.") {
            HStack(spacing: 10) {
                statusIcon(notificationCheckState)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System permission").font(.subheadline.weight(.medium))
                    Text(health.notificationState.label)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if health.notificationState == .denied {
                    Button("Open Settings") { model.openNotificationSettings() }
                } else if health.notificationState == .notRequested
                            || health.notificationState == .unknown {
                    Button("Allow Notifications") { model.requestNotifications() }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Toggle("Dangerous tool calls", isOn: $preferences.dangerousCalls)
                Toggle("Sessions waiting for attention", isOn: $preferences.attention)
                Toggle("Task completion", isOn: $preferences.taskCompletion)
                Toggle("Usage thresholds", isOn: $preferences.usageThresholds)
                Toggle("Play notification sounds", isOn: $preferences.sounds)
            }
            .toggleStyle(.switch)
        }
    }

    private var doctorSection: some View {
        section("Doctor", subtitle: "Runs deeper checks without freezing the menu or setup window.") {
            HStack {
                if model.operation == .doctor {
                    ProgressView().controlSize(.small)
                    Text(model.operation?.title ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run Doctor") { model.runDoctor() }
                    .disabled(model.operation != nil)
            }
            if let result = model.result(for: .doctor) {
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    resultHeader(result)
                    ForEach(result.checks, id: \.title) { check in
                        checkRow(check, showDetail: true)
                    }
                    DisclosureGroup("Technical details") {
                        ScrollView(.vertical) {
                            Text(result.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 170)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func integrationRow(_ check: MonitoringCheck,
                                target: SetupViewModel.ResultTarget,
                                install: @escaping () -> Void,
                                uninstall: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                statusIcon(check.state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.title).font(.subheadline.weight(.medium))
                    Text(check.summary).font(.caption).foregroundStyle(.secondary)
                    if let detail = check.detail {
                        Text(detail).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button(check.isReady ? "Repair" : "Install") { install() }
                    .disabled(model.operation != nil)
                Menu {
                    Button("Uninstall Perch integration", action: uninstall)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.operation != nil)
            }
            if model.operation?.target == target, let operation = model.operation {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(operation.title).font(.caption).foregroundStyle(.secondary)
                }
            } else if let result = model.result(for: target) {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    resultHeader(result)
                    Text(result.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func checkRow(_ check: MonitoringCheck, showDetail: Bool = false) -> some View {
        HStack(spacing: 10) {
            statusIcon(check.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.subheadline.weight(.medium))
                Text(check.summary).font(.caption).foregroundStyle(.secondary)
                if showDetail, let detail = check.detail {
                    Text(detail).font(.caption2).foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }

    private func verificationRow(_ agent: AgentKind) -> some View {
        let lastEventAt = health.lastEventAt(for: agent)
        let title = agent == .claude ? "Claude Code" : "Codex"
        return HStack(spacing: 10) {
            statusIcon(health.verificationState(for: agent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if let lastEventAt {
                    Text("Hook event received \(lastEventAt, style: .relative)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Configured · start or restart \(title) to verify")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }

    private func resultHeader(_ result: SetupViewModel.Result) -> some View {
        Label(result.title, systemImage: resultIcon(result.outcome))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(resultColor(result.outcome))
    }

    private func resultIcon(_ outcome: SetupViewModel.Outcome) -> String {
        switch outcome {
        case .success: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    private func resultColor(_ outcome: SetupViewModel.Outcome) -> Color {
        switch outcome {
        case .success: return .green
        case .attention: return .orange
        case .failure: return .red
        }
    }

    private func section<Content: View>(_ title: String, subtitle: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09)))
        }
    }

    private func statusIcon(_ state: MonitoringCheckState) -> some View {
        Image(systemName: icon(for: state))
            .foregroundStyle(color(for: state))
            .frame(width: 18)
    }

    private var notificationCheckState: MonitoringCheckState {
        switch health.notificationState {
        case .allowed, .provisional: return .ready
        case .notRequested: return .needsAttention
        case .denied, .unavailable: return .unavailable
        case .unknown: return .checking
        }
    }

    private func icon(for state: MonitoringCheckState) -> String {
        switch state {
        case .checking: return "ellipsis.circle"
        case .ready: return "checkmark.circle.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }

    private func color(for state: MonitoringCheckState) -> Color {
        switch state {
        case .checking: return .secondary
        case .ready: return .green
        case .needsAttention: return .orange
        case .unavailable: return .red
        }
    }
}
