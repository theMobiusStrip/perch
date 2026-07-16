import SwiftUI

/// Compact token-usage totals for the expanded notch panel: today / 7 days /
/// 30 days across both agents, fed by the background transcript scan.
/// Renders nothing until the first scan lands. Tapping opens the Token Usage
/// window (same affordance as the worktree glance row).
struct UsageOverviewRow: View {
    @ObservedObject var history: UsageHistoryModel
    var onOpen: () -> Void

    var body: some View {
        if history.snapshot.grandTotal > 0 {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("Tokens")
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
        let calendar = Calendar.current
        let now = Date()
        // Last 7 calendar days including today (startOfDay − 6 days).
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        var today = 0
        var week = 0
        for day in history.snapshot.days {
            if calendar.isDateInToday(day.day) { today += day.total }
            if day.day >= weekAgo { week += day.total }
        }
        let month = history.snapshot.grandTotal
        return "today \(TokenFormat.fmt(today)) · 7d \(TokenFormat.fmt(week)) · 30d \(TokenFormat.fmt(month))"
    }
}
