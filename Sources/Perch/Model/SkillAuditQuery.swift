import Foundation
import PerchCore

enum SkillAuditStatusFilter: String, CaseIterable {
    case all, attention, reviewed
}

enum SkillAuditSort: String, CaseIterable {
    case attention, name, recentlyModified
}

/// Browsing state only. A reviewed record may still have findings, and a
/// root-level scan issue is not a record that can appear in the source list.
struct SkillAuditQuery: Equatable {
    var search = ""
    var agent: AgentKind? = nil
    var scope: SkillScope? = nil
    var status: SkillAuditStatusFilter = .all
    var sort: SkillAuditSort = .attention

    var hasFilters: Bool {
        !searchTerms.isEmpty || agent != nil || scope != nil || status != .all
    }

    mutating func resetFilters() {
        search = ""
        agent = nil
        scope = nil
        status = .all
    }

    func records(in snapshot: SkillAuditSnapshot) -> [SkillRecord] {
        matchingRecords(in: snapshot).filter { matchesStatus($0, status) }.sorted { lhs, rhs in
            switch sort {
            case .attention:
                if lhs.needsReview != rhs.needsReview { return lhs.needsReview }
            case .name:
                break
            case .recentlyModified:
                if lhs.lastModified != rhs.lastModified {
                    guard let lhsDate = lhs.lastModified else { return false }
                    guard let rhsDate = rhs.lastModified else { return true }
                    return lhsDate > rhsDate
                }
            }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// Counts honor the text and registration filters, not the active status.
    /// Attention and reviewed can overlap: review is not a safety verdict.
    func count(_ status: SkillAuditStatusFilter, in snapshot: SkillAuditSnapshot) -> Int {
        matchingRecords(in: snapshot).filter { matchesStatus($0, status) }.count
    }

    static func reconciledSelection(_ id: String?, records: [SkillRecord]) -> String? {
        if let id, records.contains(where: { $0.id == id }) { return id }
        return records.first?.id
    }

    private var searchTerms: [String] {
        search.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func matchingRecords(in snapshot: SkillAuditSnapshot) -> [SkillRecord] {
        let terms = searchTerms
        return snapshot.records.filter { record in
            if agent != nil || scope != nil {
                // Both constraints must describe the same registration. A
                // shared Claude-user/Codex-project source is not Claude-project.
                guard record.registrations.contains(where: {
                    (agent == nil || $0.agent == agent) && (scope == nil || $0.scope == scope)
                }) else { return false }
            }
            guard !terms.isEmpty else { return true }
            let fields = [record.name, record.description, record.sourcePath]
                + record.registrations.flatMap { [$0.path, $0.projectPath ?? ""] }
            return terms.allSatisfy { term in
                fields.contains { $0.range(of: term, options: .caseInsensitive) != nil }
            }
        }
    }

    private func matchesStatus(_ record: SkillRecord, _ status: SkillAuditStatusFilter) -> Bool {
        switch status {
        case .all: return true
        case .attention: return record.needsReview
        case .reviewed: return record.isReviewed
        }
    }
}
