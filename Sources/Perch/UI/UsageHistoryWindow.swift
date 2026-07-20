import AppKit
import Charts
import PerchCore
import SwiftUI

/// "Token Usage" window: 30-day history aggregated from transcripts/rollouts.
@MainActor
final class UsageHistoryWindowController {
    private let model: UsageHistoryModel
    private var window: NSWindow?

    init(model: UsageHistoryModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "Perch — Token Usage"
            w.isReleasedWhenClosed = false
            w.center()
            w.contentViewController = NSHostingController(
                rootView: UsageHistoryView(model: model))
            window = w
        }
        if model.snapshot.scannedAt == nil {
            model.refresh()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct UsageHistoryView: View {
    @ObservedObject var model: UsageHistoryModel
    /// Showcase renders swap the ScrollView for a plain stack: ImageRenderer
    /// (the vector-crisp rasterizer) skips ScrollView contents entirely.
    var renderStatic = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if renderStatic {
                scrollContent
            } else {
                ScrollView {
                    scrollContent
                }
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 480)
    }

    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryCards
            chart
            dailyTable
            HStack(alignment: .top, spacing: 16) {
                breakdown(title: "By model", rows: model.snapshot.models.prefix(10).map {
                    ($0.id, $0.agent == .claude ? "✳" : "⌘", $0.model, $0.bucket)
                })
                breakdown(title: "By project", rows: model.snapshot.projects.prefix(10).map {
                    ($0.id, "▸", $0.project, $0.bucket)
                })
            }
            footer
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MM-dd"
        return f
    }()

    /// Exact numbers per day per agent, latest first.
    private var dailyTable: some View {
        let days = model.snapshot.days.reversed()
        return VStack(alignment: .leading, spacing: 4) {
            Text("Daily").font(.headline)
            if days.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow {
                        Text("Day").gridColumnAlignment(.leading)
                        Text("✳ Claude")
                        Text("⌘ Codex")
                        Text("Total")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(Array(days)) { d in
                        GridRow {
                            Text(Self.dayFormatter.string(from: d.day))
                                .gridColumnAlignment(.leading)
                                .foregroundStyle(.secondary)
                            Text(d.claude.total > 0 ? Self.fmt(d.claude.total) : "·")
                            Text(d.codex.total > 0 ? Self.fmt(d.codex.total) : "·")
                            Text(Self.fmt(d.total)).fontWeight(.medium)
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Last \(model.daysBack) days")
                .font(.title3.weight(.semibold))
            if let at = model.snapshot.scannedAt {
                Text("scanned \(at.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.scanning {
                ProgressView().controlSize(.small)
            }
            Button("Refresh") { model.refresh() }
                .disabled(model.scanning)
        }
    }

    private var summaryCards: some View {
        let snap = model.snapshot
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let week = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let todayTotal = snap.days.last(where: { $0.day == today })?.total ?? 0
        let weekTotal = snap.days.filter { $0.day >= week }.reduce(0) { $0 + $1.total }
        return HStack(spacing: 12) {
            card("Today", todayTotal)
            card("Last 7 days", weekTotal)
            card("Last 30 days", snap.grandTotal,
                 detail: "✳ \(Self.fmt(snap.claudeTotal.total)) · ⌘ \(Self.fmt(snap.codexTotal.total))")
        }
    }

    private func card(_ label: String, _ value: Int, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Self.fmt(value)).font(.title2.weight(.semibold)).monospacedDigit()
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private struct ChartRow: Identifiable {
        let id: String
        let day: Date
        let agent: String
        let total: Int
    }

    private var chart: some View {
        let rows: [ChartRow] = model.snapshot.days.flatMap { d in
            [
                ChartRow(id: "\(d.day.timeIntervalSince1970)-c", day: d.day,
                         agent: "Claude", total: d.claude.total),
                ChartRow(id: "\(d.day.timeIntervalSince1970)-x", day: d.day,
                         agent: "Codex", total: d.codex.total),
            ].filter { $0.total > 0 }
        }
        return Group {
            if rows.isEmpty {
                Text(model.scanning ? "Scanning…" : "No usage found in the window.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart(rows) { row in
                    BarMark(
                        x: .value("Day", row.day, unit: .day),
                        y: .value("Tokens", row.total))
                        .foregroundStyle(by: .value("Agent", row.agent))
                }
                .chartForegroundStyleScale(["Claude": Color.orange, "Codex": Color.teal])
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text(Self.fmt(v))
                            }
                        }
                    }
                }
                .frame(minHeight: 160)
            }
        }
    }

    private func breakdown(title: String,
                           rows: [(id: String, icon: String, name: String, bucket: TokenBucket)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if rows.isEmpty {
                Text("—").foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.id) { row in
                HStack(spacing: 6) {
                    Text(row.icon).frame(width: 14)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Self.fmt(row.bucket.total))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .help("in \(Self.fmt(row.bucket.input)) · out \(Self.fmt(row.bucket.output)) · cache-r \(Self.fmt(row.bucket.cacheRead)) · cache-w \(Self.fmt(row.bucket.cacheCreate))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        let snap = model.snapshot
        var note = "\(snap.filesScanned) files scanned"
        if snap.skippedCompressed > 0 {
            note += " · \(snap.skippedCompressed) compressed Codex rollouts skipped (older sessions undercounted)"
        }
        return Text(note).font(.caption).foregroundStyle(.tertiary)
    }

    static func fmt(_ n: Int) -> String {
        TokenFormat.fmt(n)
    }
}
