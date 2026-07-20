import SwiftUI

/// Compact account-usage gauges for the expanded notch panel. Renders one
/// horizontal bar per rate-limit window that is
/// currently known: Claude 5h/7d (statusline `rate_limits`) and Codex
/// primary/secondary (`token_count` events). Unknown windows are simply
/// omitted; when nothing is known the strip renders nothing.
struct UsageGaugeStrip: View {
    @ObservedObject var usage: UsageStore
    /// True when Claude sessions are live but no statusline payload has
    /// arrived — the one case worth explaining instead of hiding.
    var claudeDataMissing = false

    private struct GaugeItem: Identifiable {
        let label: String
        let window: UsageStore.RateWindow
        var id: String { label }
    }

    var body: some View {
        let items = collectItems()
        VStack(spacing: 6) {
            if claudeDataMissing {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9, weight: .medium))
                    Text("No Claude 5h/7d bars: the Claude app shows your quota in its own window but doesn't share it with Perch — only Terminal `claude` sessions do. Your token totals above still count every session.")
                        .font(.system(size: 9))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .perchInset()
            }
            gaugeRows(items)
        }
    }

    @ViewBuilder
    private func gaugeRows(_ items: [GaugeItem]) -> some View {
        if !items.isEmpty {
            // Periodic timeline keeps the "resets 2h 14m" countdowns fresh.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        GaugeRowView(label: item.label, window: item.window, now: context.date)
                    }
                }
            }
        }
    }

    private func collectItems() -> [GaugeItem] {
        var out: [GaugeItem] = []
        if let w = usage.claudeFiveHour { out.append(GaugeItem(label: "Claude 5h", window: w)) }
        if let w = usage.claudeSevenDay { out.append(GaugeItem(label: "Claude 7d", window: w)) }
        if let w = usage.codexPrimary { out.append(GaugeItem(label: "Codex 5h", window: w)) }
        if let w = usage.codexSecondary { out.append(GaugeItem(label: "Codex wk", window: w)) }
        return out
    }
}

/// One compact horizontal gauge: label · bar · percent · reset countdown.
private struct GaugeRowView: View {
    let label: String
    let window: UsageStore.RateWindow
    let now: Date

    private var pct: Double { min(max(window.usedPercentage, 0), 100) }
    private var barColor: Color { PerchTheme.gaugeColor(pct: pct) }

    private var countdownText: String {
        guard let resetsAt = window.resetsAt else { return "" }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return "resets soon" }
        return "resets \(Self.formatInterval(remaining))"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PerchTheme.trackFill)
                    Capsule()
                        .fill(LinearGradient(colors: [barColor.opacity(0.7), barColor],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(5, geo.size.width * pct / 100))
                }
            }
            .frame(height: 6)

            Text("\(Int(pct.rounded()))%")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(pct > 85 ? PerchTheme.danger : Color.primary)
                .frame(width: 34, alignment: .trailing)

            Text(countdownText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 84, alignment: .trailing)
        }
        .frame(height: 15)
        .help("\(label): \(Int(pct.rounded()))% used\(countdownText.isEmpty ? "" : " · \(countdownText)")")
    }

    /// "2h 14m", "3d 5h", "45m" — coarse two-unit countdown.
    static func formatInterval(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }
}
