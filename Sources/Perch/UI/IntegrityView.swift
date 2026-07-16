import SwiftUI

/// The notch's "Integrity" page: current state of the agent-persistence
/// surface, grouped by category. Read-only — it reports, it doesn't judge.
struct IntegrityView: View {
    @ObservedObject var model: IntegrityModel
    /// Showcase renders swap the ScrollView for a plain stack: ImageRenderer
    /// (the vector-crisp rasterizer) skips ScrollView contents entirely.
    var renderStatic = false

    var body: some View {
        if renderStatic {
            content
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(IntegrityCategory.allCases, id: \.self) { category in
                let items = model.snapshot.items(in: category)
                if !items.isEmpty {
                    section(category, items)
                }
            }
            if model.snapshot.items.isEmpty {
                Text(model.scanning ? "Scanning…" : "No persistence surface found")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
            legend
        }
    }

    /// Perch can't verify a file is safe — only whether it changed recently or
    /// carries a hook it doesn't recognise. Say so, so a neutral dot is never
    /// read as an all-clear.
    private var legend: some View {
        Text("● changed recently  ● non-Perch hook — review. Perch flags changes, not safety; an unchanged file can still be poisoned.")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    private func section(_ category: IntegrityCategory, _ items: [IntegrityItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            ForEach(items) { item in
                row(item)
            }
        }
    }

    private func row(_ item: IntegrityItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color(for: item.status))
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let tag = tag(for: item.status) {
                        Text(tag)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(color(for: item.status))
                    }
                    Spacer(minLength: 4)
                    if item.status == .nonPerch || item.status == .changedRecently,
                       !item.fingerprint.isEmpty {
                        // Records "reviewed at this state" — the flag returns
                        // on any real change (new fingerprint). Not an approval.
                        Button {
                            model.acknowledge(item)
                        } label: {
                            Text("✓ reviewed")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Hide this flag until the item changes again")
                    }
                    if let m = item.lastModified {
                        Text(Self.age(m))
                            .font(.caption2)
                            .foregroundStyle(item.status == .changedRecently ? Color.orange : Color.secondary.opacity(0.7))
                            .monospacedDigit()
                    }
                }
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(0.04)))
    }

    /// Perch has no way to tell a user's own hook from an injected one, so a
    /// non-Perch hook is amber "review", never a red threat verdict. Nothing
    /// here is green: unchanged is a neutral state, not a safety guarantee.
    private func color(for status: IntegrityStatus) -> Color {
        switch status {
        case .nonPerch, .changedRecently: return .orange
        case .unreadable: return .yellow
        case .unchanged: return Color(white: 0.55)
        case .absent: return Color.gray.opacity(0.4)
        }
    }

    private func tag(for status: IntegrityStatus) -> String? {
        switch status {
        case .nonPerch: return "NON-PERCH HOOK"
        case .unreadable: return "UNREADABLE"
        default: return nil
        }
    }

    /// Coarse "modified 3h ago" relative label.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 3600 { return "\(max(1, s / 60))m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        let d = s / 86_400
        return d < 30 ? "\(d)d ago" : "30d+ ago"
    }
}
