import AppKit
import Combine
import ServiceManagement
import PerchCore

/// Menu bar presence: bird icon + attention badge, and a menu that mirrors
/// the notch panel (sessions, usage, install/doctor actions, quick routes).
/// The menu is rebuilt every time it opens (NSMenuDelegate) so session lines
/// are always fresh.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let sessions: SessionStore
    private let usage: UsageStore
    private let riskFeed: RiskFeed
    private let posture: SecurityPosture
    private let updateChecker: UpdateChecker
    private let worktrees: WorktreeModel
    private let actions: AppActions

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    init(sessions: SessionStore, usage: UsageStore, riskFeed: RiskFeed,
         posture: SecurityPosture, updateChecker: UpdateChecker,
         worktrees: WorktreeModel, actions: AppActions) {
        self.sessions = sessions
        self.usage = usage
        self.riskFeed = riskFeed
        self.posture = posture
        self.updateChecker = updateChecker
        self.worktrees = worktrees
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Perch")
                ?? NSImage(systemSymbolName: "circle.grid.2x1.fill", accessibilityDescription: "Perch")
            button.imagePosition = .imageLeading
            button.toolTip = "Perch — agent session monitor"
        }

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // Live badge: count of sessions needing attention.
        sessions.$sessions
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)
        riskFeed.$entries
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)
        updateBadge()
    }

    deinit {
        // NSStatusBar removal is main-thread work; controller lives for the
        // app's lifetime in practice (owned by AppDelegate).
    }

    // MARK: - Badge

    private func updateBadge() {
        let attentionCount = max(
            sessions.sessions.filter(\.needsAttention).count,
            riskFeed.count)
        guard let button = statusItem.button else { return }
        if attentionCount > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(attentionCount)",
                attributes: [
                    .foregroundColor: NSColor.systemOrange,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: - NSMenuDelegate (rebuild on open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Opening the menu is a good moment to refresh (throttled, non-blocking).
        updateChecker.checkIfStale()

        // Security posture.
        menu.addItem(infoItem("Security \(posture.score)/100 — \(posture.grade.rawValue)",
                              monospacedDigits: true))
        menu.addItem(.separator())

        // Session lines.
        let list = sessions.sessions
        if list.isEmpty {
            menu.addItem(infoItem("No active sessions"))
        } else {
            for session in list {
                menu.addItem(sessionItem(session))
            }
        }
        menu.addItem(.separator())

        // Usage summary.
        let usageLines = usageSummaryLines()
        if !usageLines.isEmpty {
            for line in usageLines {
                menu.addItem(infoItem(line, monospacedDigits: true))
            }
            menu.addItem(.separator())
        }

        // Worktree summary (only once scanned and non-empty).
        if let worktreeLine = worktreeSummaryLine() {
            menu.addItem(infoItem(worktreeLine, monospacedDigits: true))
            menu.addItem(.separator())
        }

        menu.addItem(actionItem("Show/Hide Notch Panel", #selector(toggleNotch), key: "n"))
        menu.addItem(actionItem("Token Usage…", #selector(openUsageHistory), key: "t"))
        menu.addItem(actionItem("Worktrees…", #selector(openWorktrees), key: "w"))
        menu.addItem(actionItem("Debug Window", #selector(openDebugWindow), key: "d"))
        menu.addItem(.separator())

        menu.addItem(actionItem("Install Claude Hooks…", #selector(installClaudeHooks)))
        menu.addItem(actionItem("Install Codex Hooks…", #selector(installCodexHooks)))

        let uninstallItem = NSMenuItem(title: "Uninstall…", action: nil, keyEquivalent: "")
        let uninstallMenu = NSMenu(title: "Uninstall…")
        uninstallMenu.autoenablesItems = false
        uninstallMenu.addItem(actionItem("Uninstall Claude Hooks…", #selector(uninstallClaudeHooks)))
        uninstallMenu.addItem(actionItem("Uninstall Codex Hooks…", #selector(uninstallCodexHooks)))
        uninstallItem.submenu = uninstallMenu
        uninstallItem.isEnabled = true
        menu.addItem(uninstallItem)

        menu.addItem(actionItem("Doctor", #selector(runDoctor)))
        menu.addItem(.separator())

        let routesItem = NSMenuItem(title: "Quick Routes", action: nil, keyEquivalent: "")
        routesItem.submenu = quickRoutesMenu()
        routesItem.isEnabled = true
        menu.addItem(routesItem)

        let loginItem = actionItem("Launch at Login", #selector(toggleLaunchAtLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        addUpdateItems(to: menu)
        menu.addItem(actionItem("About Perch (\(AppVersion.string))", #selector(showAbout)))
        menu.addItem(actionItem("Quit Perch", #selector(quit), key: "q"))
    }

    // MARK: - Update section

    private func addUpdateItems(to menu: NSMenu) {
        switch updateChecker.state {
        case .available(let release):
            let label = "Download Perch \(release.tag)…"
            let item = actionItem(label, #selector(openUpdate))
            let bold = NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0),
                                                    toHaveTrait: .boldFontMask)
            item.attributedTitle = NSAttributedString(string: label, attributes: [.font: bold])
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                 accessibilityDescription: "Update available")?
                .withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
            menu.addItem(item)
        case .checking:
            menu.addItem(infoItem("Checking for Updates…"))
        default:
            menu.addItem(actionItem("Check for Updates…", #selector(checkForUpdates)))
        }

        let autoItem = actionItem("Check Automatically", #selector(toggleAutoUpdate))
        autoItem.state = updateChecker.autoCheckEnabled ? .on : .off
        menu.addItem(autoItem)
        menu.addItem(.separator())
    }

    // MARK: - Menu item builders

    private func actionItem(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        return item
    }

    private func infoItem(_ text: String, monospacedDigits: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        if monospacedDigits {
            item.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize(for: .small), weight: .regular)])
        }
        item.isEnabled = false
        return item
    }

    private func sessionItem(_ session: Session) -> NSMenuItem {
        let item = NSMenuItem(title: session.displayTitle, action: nil, keyEquivalent: "")
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(
            string: "● ",
            attributes: [.foregroundColor: Self.stateColor(session.state)]))
        title.append(NSAttributedString(string: session.displayTitle))
        var detail = "  — \(Self.stateText(session.state))"
        if let note = session.attentionNote, !note.isEmpty {
            detail += " · \(note)"
        }
        title.append(NSAttributedString(
            string: detail,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = title
        item.isEnabled = false
        return item
    }

    private static func stateColor(_ state: SessionState) -> NSColor {
        switch state {
        case .executing: return .systemGreen
        case .waitingPermission, .waitingInput: return .systemOrange
        case .idle: return .systemGray
        case .ended: return .tertiaryLabelColor
        case .unknown: return .quaternaryLabelColor
        }
    }

    private static func stateText(_ state: SessionState) -> String {
        switch state {
        case .executing: return "running"
        case .waitingPermission: return "waiting for permission"
        case .waitingInput: return "waiting for input"
        case .idle: return "idle"
        case .ended: return "ended"
        case .unknown: return "unknown"
        }
    }

    private func usageSummaryLines() -> [String] {
        var lines: [String] = []
        func add(_ label: String, _ window: UsageStore.RateWindow?) {
            guard let window else { return }
            var line = "\(label): \(Int(window.usedPercentage.rounded()))%"
            if let resetsAt = window.resetsAt {
                line += " · resets \(Self.countdown(to: resetsAt))"
            }
            lines.append(line)
        }
        add("Claude 5h", usage.claudeFiveHour)
        add("Claude 7d", usage.claudeSevenDay)
        add("Codex 5h", usage.codexPrimary)
        add("Codex weekly", usage.codexSecondary)
        return lines
    }

    /// `Worktrees: 19 · 1.06 GB · 497 MB reclaimable` — nil until a scan lands
    /// or when there are no worktrees; the reclaimable clause drops when zero.
    private func worktreeSummaryLine() -> String? {
        let snap = worktrees.snapshot
        guard snap.scannedAt != nil, snap.totalCount > 0 else { return nil }
        var line = "Worktrees: \(snap.totalCount) · \(ByteFormat.fmt(snap.totalBytes))"
        if snap.reclaimableCount > 0 {
            line += " · \(ByteFormat.fmt(snap.reclaimableBytes)) reclaimable"
        }
        return line
    }

    private static func countdown(to date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "now" }
        let minutes = Int(seconds / 60)
        let days = minutes / (60 * 24)
        let hours = (minutes / 60) % 24
        let mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    // MARK: - Quick Routes

    private struct Route {
        let url: URL
        let reveal: Bool   // reveal file in Finder vs open directory
    }

    private func quickRoutesMenu() -> NSMenu {
        let m = NSMenu(title: "Quick Routes")
        m.autoenablesItems = false
        func add(_ title: String, _ url: URL, reveal: Bool = false) {
            let item = NSMenuItem(title: title, action: #selector(openRoute(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Route(url: url, reveal: reveal)
            item.isEnabled = true
            m.addItem(item)
        }
        let claude = PerchPaths.claudeConfigDir
        add("Claude Skills", claude.appendingPathComponent("skills", isDirectory: true))
        add("Claude Plugins", claude.appendingPathComponent("plugins", isDirectory: true))
        add("Claude Projects", claude.appendingPathComponent("projects", isDirectory: true))
        add("Claude settings.json", claude.appendingPathComponent("settings.json"), reveal: true)
        add("Codex Sessions", PerchPaths.codexHomeDir.appendingPathComponent("sessions", isDirectory: true))
        m.addItem(.separator())
        add("Perch App Support", PerchPaths.appSupportDir)
        add("Perch Log", PerchPaths.logFile, reveal: true)
        return m
    }

    @objc private func openRoute(_ sender: NSMenuItem) {
        guard let route = sender.representedObject as? Route else { return }
        guard FileManager.default.fileExists(atPath: route.url.path) else {
            PerchLog.warn("Quick route missing: \(route.url.path)", category: "menubar")
            NSSound.beep()
            return
        }
        if route.reveal {
            NSWorkspace.shared.activateFileViewerSelecting([route.url])
        } else {
            NSWorkspace.shared.open(route.url)
        }
    }

    // MARK: - Actions

    @objc private func toggleNotch() { actions.toggleNotch() }
    @objc private func openDebugWindow() { actions.openDebugWindow() }
    @objc private func openUsageHistory() { actions.openUsageHistory() }
    @objc private func openWorktrees() { actions.openWorktrees() }
    @objc private func quit() { actions.quit() }

    @objc private func installClaudeHooks() {
        showText(actions.installClaudeHooks(), title: "Install Claude Hooks")
    }

    @objc private func installCodexHooks() {
        showText(actions.installCodexHooks(), title: "Install Codex Hooks")
    }

    @objc private func uninstallClaudeHooks() {
        showText(actions.uninstallClaudeHooks(), title: "Uninstall Claude Hooks")
    }

    @objc private func uninstallCodexHooks() {
        showText(actions.uninstallCodexHooks(), title: "Uninstall Codex Hooks")
    }

    @objc private func runDoctor() {
        showText(actions.doctorReport(), title: "Perch Doctor")
    }

    // MARK: - Update actions

    @objc private func openUpdate() {
        updateChecker.openLatest()
    }

    @objc private func checkForUpdates() {
        updateChecker.checkManually { [weak self] state in
            self?.presentUpdateResult(state)
        }
    }

    @objc private func toggleAutoUpdate() {
        updateChecker.setAutoCheck(!updateChecker.autoCheckEnabled)
    }

    private func presentUpdateResult(_ state: UpdateChecker.State) {
        switch state {
        case .available(let release):
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Perch \(release.tag) is available"
            alert.informativeText = "You're running \(AppVersion.string). Open the release page to download it."
            alert.addButton(withTitle: "Download…")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                updateChecker.openLatest()
            }
        case .upToDate:
            showText("You're up to date (\(AppVersion.string)).", title: "Check for Updates")
        case .devBuild:
            showText("This is a development build — update checks are disabled.",
                     title: "Check for Updates")
        case .failed(let message):
            showText("Couldn't check for updates:\n\(message)", title: "Check for Updates")
        case .checking, .unknown:
            break
        }
    }

    @objc private func showAbout() {
        // Honest about the one network call: it exists only when the update
        // check is enabled.
        let networkLine = updateChecker.autoCheckEnabled
            ? "100% local · one network call: GitHub update check · MIT license"
            : "100% local · zero network calls · MIT license"
        showText("""
        Perch \(AppVersion.string)
        Read-only security watchtower for Claude Code and Codex.

        https://github.com/theMobiusStrip/perch
        \(networkLine)
        """, title: "About Perch")
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                PerchLog.info("Launch at login disabled", category: "menubar")
            } else {
                try service.register()
                PerchLog.info("Launch at login enabled", category: "menubar")
            }
        } catch {
            PerchLog.error("Launch at login toggle failed: \(error)", category: "menubar")
            showText("Could not change Launch at Login:\n\(error.localizedDescription)",
                     title: "Launch at Login")
        }
    }

    // MARK: - Alert helper (monospaced, scrollable)

    private func showText(_ text: String, title: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational
        alert.accessoryView = Self.monospacedTextView(text)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func monospacedTextView(_ text: String) -> NSView {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let height = min(280, max(48, CGFloat(lineCount) * 15 + 20))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        return scroll
    }
}
