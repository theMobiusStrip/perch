import AppKit
import SwiftUI
import PerchCore

/// Observable UI state shared between NotchController (AppKit side) and
/// NotchRootView (SwiftUI side). The controller mutates it inside
/// `withAnimation`; the views read it and call back through `controller`.
/// Which page the expanded panel shows.
enum NotchPage { case sessions, integrity }

@MainActor
final class NotchViewState: ObservableObject {
    @Published var isExpanded = false
    @Published var page: NotchPage = .sessions
    @Published var hasAttention = false
    @Published var hasNotch = false
    @Published var pillSize = NotchGeometry.fallbackPillSize
    @Published var expandedSize = NotchGeometry.expandedMaxSize
    weak var controller: NotchController?
}

/// Owns the notch panel window: builds it on the right screen, drives
/// expand/collapse animations, hover + click-outside behavior, and routes
/// keyboard shortcuts to the risk feed.
@MainActor
final class NotchController {
    private let sessions: SessionStore
    private let usage: UsageStore
    private let riskFeed: RiskFeed
    private let posture: SecurityPosture
    private let usageHistory: UsageHistoryModel
    private let integrity: IntegrityModel

    private let state = NotchViewState()
    private var panel: NotchPanel?
    private var hostingView: NotchHostingView<NotchRootView>?
    private var geometry: NotchGeometry?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hoverExpandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var autoExpandedForAttention = false

    private static let expandAnimation = Animation.spring(response: 0.5, dampingFraction: 0.78)
    private static let collapseAnimation = Animation.spring(response: 0.36, dampingFraction: 0.88)

    init(sessions: SessionStore, usage: UsageStore, riskFeed: RiskFeed,
         posture: SecurityPosture, usageHistory: UsageHistoryModel,
         integrity: IntegrityModel) {
        self.sessions = sessions
        self.usage = usage
        self.riskFeed = riskFeed
        self.posture = posture
        self.usageHistory = usageHistory
        self.integrity = integrity
        state.controller = self
    }

    /// Switch the expanded panel between the sessions and integrity pages.
    func selectPage(_ page: NotchPage) {
        guard state.page != page else { return }
        state.page = page
        if page == .integrity { integrity.refresh() }
    }

    deinit {
        if let monitor = globalMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Public API (contract E)

    func show() {
        if panel == nil { buildPanel() }
        panel?.orderFrontRegardless()
    }

    func toggle() {
        if panel == nil { show() }  // build may have failed at launch (no screen)
        if state.isExpanded { collapse() } else { expand() }
    }

    func expand() {
        guard panel != nil else { return }
        cancelScheduledCollapse()
        cancelScheduledHoverExpand()
        if !state.isExpanded {
            withAnimation(Self.expandAnimation) {
                state.isExpanded = true
            }
        }
        integrity.refresh()
        updateInteractiveRect()
    }

    func collapse() {
        cancelScheduledCollapse()
        cancelScheduledHoverExpand()
        autoExpandedForAttention = false
        guard state.isExpanded else { return }
        withAnimation(Self.collapseAnimation) {
            state.isExpanded = false
        }
        updateInteractiveRect()
        surrenderKeyStatus()
    }

    /// Amber state + auto-expand (risk flagged / session needs input).
    func attention() {
        state.hasAttention = true
        show()
        if !state.isExpanded { autoExpandedForAttention = true }
        expand()
        // Deliberately NO makeKey() here: grabbing key status on an attention
        // event would silently swallow whatever the user is typing in the
        // terminal. The panel takes key only on mouseDown inside it
        // (NotchPanel.sendEvent), after which Esc/arrows work.
    }

    func attentionCleared() {
        state.hasAttention = false
        if autoExpandedForAttention {
            autoExpandedForAttention = false
            scheduleCollapse(after: 0.8)
        }
    }

    func rebuildForScreenChange() {
        guard let panel else {
            // Never built (e.g. launched headless before displays woke).
            // A screen may exist now — build instead of bailing forever.
            show()
            return
        }
        guard let geo = NotchGeometry.resolve() else {
            PerchLog.warn("No screen available; hiding notch panel", category: "notch")
            panel.orderOut(nil)
            return
        }
        geometry = geo
        panel.setFrame(geo.windowFrame, display: true)
        applyGeometryToState(geo)
        updateInteractiveRect()
        panel.orderFrontRegardless()
        PerchLog.info("Notch panel rebuilt for screen change (hasNotch=\(geo.hasNotch))", category: "notch")
    }

    // MARK: - Hover (called by NotchRootView)

    func pillHoverChanged(_ hovering: Bool) {
        cancelScheduledHoverExpand()
        guard hovering, !state.isExpanded else { return }
        // Small delay so a cursor merely passing the notch doesn't expand.
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.expand() }
        }
        hoverExpandWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func panelHoverChanged(_ hovering: Bool) {
        if hovering {
            cancelScheduledCollapse()
        } else if state.isExpanded, riskFeed.isEmpty {
            scheduleCollapse(after: 0.4)
        }
    }

    // MARK: - Panel construction

    private func buildPanel() {
        guard let geo = NotchGeometry.resolve() else {
            PerchLog.warn("No screen available for notch panel", category: "notch")
            return
        }
        geometry = geo
        let panel = NotchPanel(contentRect: geo.windowFrame)
        let root = NotchRootView(state: state, sessions: sessions, usage: usage,
                                 riskFeed: riskFeed, posture: posture,
                                 usageHistory: usageHistory, integrity: integrity)
        let hosting = NotchHostingView(rootView: root)
        hosting.sizingOptions = []  // window frame is static; never autosize
        hosting.frame = NSRect(origin: .zero, size: geo.windowFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.keyDownHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        self.panel = panel
        self.hostingView = hosting
        applyGeometryToState(geo)
        updateInteractiveRect()
        installMouseMonitors()
        PerchLog.info("Notch panel built (hasNotch=\(geo.hasNotch), frame=\(geo.windowFrame))",
                      category: "notch")
    }

    private func applyGeometryToState(_ geo: NotchGeometry) {
        state.hasNotch = geo.hasNotch
        state.pillSize = geo.pillSize
        state.expandedSize = geo.expandedSize
    }

    private func updateInteractiveRect() {
        guard let geo = geometry else { return }
        hostingView?.interactiveRect = geo.interactiveRect(expanded: state.isExpanded)
    }

    // MARK: - Keyboard (panel is key while user interacts)

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard state.isExpanded else { return false }
        switch event.keyCode {
        case 53:  // Esc — dismiss the focused risk card
            riskFeed.dismissFocused()
            if riskFeed.isEmpty { collapse() }
            return true
        case 123:  // ←
            riskFeed.focusPrevious()
            return true
        case 124:  // →
            riskFeed.focusNext()
            return true
        default:
            return false
        }
    }

    // MARK: - Click-outside collapse

    private func installMouseMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleGlobalClick() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalClick(event) }
            return event
        }
    }

    private func handleGlobalClick() {
        guard state.isExpanded, let panel, let geo = geometry else { return }
        let rect = geo.interactiveRect(expanded: true)
            .offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        if !rect.contains(NSEvent.mouseLocation) {
            collapse()
        }
    }

    private func handleLocalClick(_ event: NSEvent) {
        guard state.isExpanded, let panel, event.window === panel, let geo = geometry else { return }
        if !geo.interactiveRect(expanded: true).contains(event.locationInWindow) {
            collapse()
        }
    }

    // MARK: - Key status

    /// Give keyboard focus back to whatever window had it (the terminal).
    /// Ordering the panel out briefly releases key status; the panel stays
    /// visually present because it's reordered in the same runloop turn.
    private func surrenderKeyStatus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    // MARK: - Deferred work

    private func scheduleCollapse(after delay: TimeInterval) {
        cancelScheduledCollapse()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.collapse() }
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelScheduledCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    private func cancelScheduledHoverExpand() {
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
    }
}
