import AppKit
import SwiftUI
import PerchCore

@MainActor
final class SetupViewModel: ObservableObject {
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
    }

    struct Result {
        let title: String
        let text: String
        let failed: Bool
    }

    @Published private(set) var operation: Operation?
    @Published private(set) var result: Result?

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
        perform(.installClaude, resultTitle: "Claude Code monitoring") {
            Self.runReporting {
                _ = try BridgeDeployer.deploy()
                return try ClaudeHookInstaller.install()
            }
        }
    }

    func installCodex() {
        perform(.installCodex, resultTitle: "Codex monitoring") {
            Self.runReporting {
                _ = try BridgeDeployer.deploy()
                var report = try CodexHookInstaller.install()
                report.notes += CodexHookTrust.ensureTrusted()
                return report
            }
        }
    }

    func uninstallClaude() {
        perform(.uninstallClaude, resultTitle: "Claude Code monitoring") {
            Self.runReporting { try ClaudeHookInstaller.uninstall() }
        }
    }

    func uninstallCodex() {
        perform(.uninstallCodex, resultTitle: "Codex monitoring") {
            Self.runReporting { try CodexHookInstaller.uninstall() }
        }
    }

    func runDoctor() {
        perform(.doctor, resultTitle: "Perch Doctor") { Doctor.report() }
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

    private func perform(_ operation: Operation, resultTitle: String,
                         work: @escaping () -> String) {
        guard self.operation == nil else { return }
        self.operation = operation
        result = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let text = work()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.operation = nil
                self.result = Result(title: resultTitle, text: text,
                                     failed: text.hasPrefix("Failed:"))
                self.refresh()
            }
        }
    }

    private static func runReporting(_ body: () throws -> InstallReport) -> String {
        do {
            return try body().summaryText
        } catch {
            return "Failed: \(error.localizedDescription)"
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
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: healthIcon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(healthColor)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(health.snapshot.title)
                    .font(.title2.weight(.semibold))
                Text(health.snapshot.summary)
                    .foregroundStyle(.secondary)
                Text("Coverage and detections are read-only. Perch observes; it never approves, denies, or blocks an agent action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastEventAt = health.lastEventAt {
                    Text("Last hook event \(lastEventAt, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if health.snapshot.state == .ready {
                    Text("Connected · waiting for the first hook event")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if health.isRefreshing { ProgressView().controlSize(.small) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(healthColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(healthColor.opacity(0.25)))
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
                           install: model.installClaude, uninstall: model.uninstallClaude)
            Divider()
            integrationRow(health.snapshot.codex,
                           install: model.installCodex, uninstall: model.uninstallCodex)
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
            if let result = model.result {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Label(result.title,
                          systemImage: result.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(result.failed ? Color.red : Color.primary)
                    ScrollView(.vertical) {
                        Text(result.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                }
            } else if let operation = model.operation {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(operation.title).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func integrationRow(_ check: MonitoringCheck,
                                install: @escaping () -> Void,
                                uninstall: @escaping () -> Void) -> some View {
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
    }

    private func checkRow(_ check: MonitoringCheck) -> some View {
        HStack(spacing: 10) {
            statusIcon(check.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.subheadline.weight(.medium))
                Text(check.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
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

    private var healthIcon: String { icon(for: health.snapshot.state) }
    private var healthColor: Color { color(for: health.snapshot.state) }

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
