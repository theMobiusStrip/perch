import SwiftUI

/// Pill ⇄ expanded switcher rendered inside the large static panel window.
/// The window never resizes; this view animates the visible black shape
/// between the collapsed pill and the expanded panel (spring params, PLAN §4).
///
/// Expanded panel composes (in order): PostureBadgeView, RiskCardView (when
/// the feed is non-empty), a Sessions|Integrity page switcher, then either the
/// session list (+ UsageOverviewRow + UsageGaugeStrip) or the IntegrityView.
struct NotchRootView: View {
    @ObservedObject var state: NotchViewState
    @ObservedObject var sessions: SessionStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var riskFeed: RiskFeed
    @ObservedObject var posture: SecurityPosture
    @ObservedObject var health: MonitoringHealth
    @ObservedObject var usageHistory: UsageHistoryModel
    @ObservedObject var integrity: IntegrityModel
    @ObservedObject var worktrees: WorktreeModel
    let openWorktrees: () -> Void
    let openUsageHistory: () -> Void
    let openSetup: () -> Void
    let openRecentDetections: () -> Void
    /// Showcase renders swap the ScrollView for a plain stack: ImageRenderer
    /// (the vector-crisp rasterizer) skips ScrollView contents entirely.
    var renderStatic = false

    var body: some View {
        shell
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    // MARK: - Shell (the animated black shape)

    private var shellSize: CGSize {
        state.isExpanded ? state.expandedSize : state.pillSize
    }

    /// Top corners squared against the notch/screen edge; bottom radius ~18
    /// when expanded.
    private var shellShape: UnevenRoundedRectangle {
        let bottomRadius: CGFloat = state.isExpanded ? 18 : (state.hasNotch ? 10 : 14)
        return UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: 0,
            style: .continuous)
    }

    private var shell: some View {
        ZStack(alignment: .top) {
            // Dark material look: ultraThinMaterial under a black tint.
            // The collapsed pill is pure black so it blends with the bezel.
            shellShape
                .fill(Color.black.opacity(state.isExpanded ? 0.84 : 1.0))
                .background(.ultraThinMaterial, in: shellShape)
            inner
        }
        .frame(width: shellSize.width, height: shellSize.height)
        .clipShape(shellShape)
        .contentShape(shellShape)
        .shadow(color: .black.opacity(state.isExpanded ? 0.45 : 0), radius: 18, x: 0, y: 6)
        .onHover { hovering in
            if state.isExpanded {
                state.controller?.panelHoverChanged(hovering)
            } else {
                state.controller?.pillHoverChanged(hovering)
            }
        }
    }

    @ViewBuilder
    private var inner: some View {
        if state.isExpanded {
            expandedContent
                .transition(.opacity)
        } else {
            pillContent
                .transition(.opacity)
        }
    }

    /// Keeps content clear of the physical camera-housing cutout.
    private var notchCutoutInset: CGFloat {
        state.hasNotch ? max(0, state.pillSize.height - NotchGeometry.pillBandHeight) : 0
    }

    // MARK: - Collapsed pill

    private var pillContent: some View {
        VStack(spacing: 0) {
            if state.hasNotch {
                Spacer(minLength: 0)  // push the visible band below the cutout
            }
            PillView(sessions: sessions, health: health, hasAttention: state.hasAttention)
                .frame(height: state.hasNotch ? NotchGeometry.pillBandHeight : state.pillSize.height)
        }
        .frame(width: state.pillSize.width, height: state.pillSize.height)
        .contentShape(Rectangle())
        .onTapGesture { state.controller?.toggle() }
    }

    // MARK: - Expanded panel

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonitoringHealthBadgeView(health: health, onOpen: openSetup)
            PostureBadgeView(posture: posture, onOpen: openRecentDetections)
            if !riskFeed.isEmpty {
                RiskCardView(feed: riskFeed, renderStatic: renderStatic)
            }
            pageSwitcher
            Group {
                if state.page == .sessions {
                    sessionList
                } else {
                    IntegrityView(model: integrity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.page == .sessions {
                footerSection
            }
        }
        .padding(.top, notchCutoutInset + 10)
        .padding(.horizontal, 14)
        .padding(.bottom, 13)
        .frame(width: shellSize.width, height: shellSize.height, alignment: .top)
    }

    /// Footer: glance rows (worktrees, tokens) over the rate-limit gauges,
    /// separated from the session list by a hairline.
    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.bottom, 2)
            WorktreeGlanceRow(model: worktrees, onOpen: openWorktrees)
            UsageOverviewRow(history: usageHistory, onOpen: openUsageHistory)
            UsageGaugeStrip(usage: usage, claudeDataMissing: claudeGaugesMissing)
        }
    }

    // MARK: - Page switcher (Sessions | Integrity)

    private var pageSwitcher: some View {
        HStack(spacing: 2) {
            pageTab("Sessions", .sessions, badge: 0)
            pageTab("Integrity", .integrity, badge: integrity.snapshot.flaggedCount)
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }

    private func pageTab(_ title: String, _ page: NotchPage, badge: Int) -> some View {
        let selected = state.page == page
        return Button {
            state.controller?.selectPage(page)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2.weight(selected ? .semibold : .regular))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(PerchTheme.attention))
                }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(selected ? Color.white.opacity(0.16) : Color.clear)
                    .shadow(color: .black.opacity(selected ? 0.25 : 0), radius: 2, x: 0, y: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Claude sessions are live but no statusline payload ever arrived —
    /// typical when every session runs in the desktop app, which never
    /// invokes the CLI statusline command that carries rate_limits.
    private var claudeGaugesMissing: Bool {
        usage.claudeFiveHour == nil && usage.claudeSevenDay == nil
            && sessions.sessions.contains { $0.key.agent == .claude }
    }

    @ViewBuilder
    private var sessionList: some View {
        if sessions.sessions.isEmpty {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "terminal")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.quaternary)
                Text("No agent sessions")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if health.snapshot.hasConfiguredAgent {
                    Text("Start Claude Code or Codex")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Button("Finish monitoring setup", action: openSetup)
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(PerchTheme.attention)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        } else if renderStatic {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sessions.sessions) { session in
                    sessionRow(session)
                }
                Spacer(minLength: 0)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(sessions.sessions) { session in
                            sessionRow(session)
                                .id(session.key)
                        }
                    }
                }
                .onAppear { scrollToFocusedSession(using: proxy) }
                .onChange(of: state.sessionFocusRequest) { _, _ in
                    scrollToFocusedSession(using: proxy)
                }
            }
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        SessionRowView(session: session,
                       isNotificationTarget: state.focusedSessionKey == session.key)
    }

    private func scrollToFocusedSession(using proxy: ScrollViewProxy) {
        guard let key = state.focusedSessionKey else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(key, anchor: .center) }
        }
    }
}
