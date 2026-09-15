import Foundation

public enum SkillScope: String, Sendable, CaseIterable {
    case user = "User"
    case project = "Project"
}

public enum SkillIssue: String, Sendable, CaseIterable, Hashable {
    case unreadable, scanIncomplete, brokenLink, invalidSkill, nameConflict, changed

    public var label: String {
        switch self {
        case .unreadable: return "UNREADABLE"
        case .scanIncomplete: return "SCAN INCOMPLETE"
        case .brokenLink: return "BROKEN LINK"
        case .invalidSkill: return "INVALID SKILL"
        case .nameConflict: return "NAME CONFLICT"
        case .changed: return "CHANGED"
        }
    }
}

public struct SkillRegistration: Identifiable, Equatable, Sendable {
    public var id: String { agent.rawValue + ":" + path }
    /// The binding survives a canonical source change, so retargeting a
    /// reviewed registration is visible even when timestamps are preserved.
    public var reviewKey: String { "registration:" + id }
    public var agent: AgentKind
    public var scope: SkillScope
    public var path: String
    public var projectPath: String?
    public var isSymlink: Bool
    public var isDiscoverable: Bool

    public init(agent: AgentKind, scope: SkillScope, path: String, projectPath: String? = nil,
                isSymlink: Bool = false, isDiscoverable: Bool = true) {
        self.agent = agent; self.scope = scope; self.path = path
        self.projectPath = projectPath; self.isSymlink = isSymlink
        self.isDiscoverable = isDiscoverable
    }
}

public struct SkillFileCounts: Equatable, Sendable {
    public var scripts: Int
    public var references: Int
    public var assets: Int
    public var total: Int

    public init(scripts: Int = 0, references: Int = 0, assets: Int = 0, total: Int = 0) {
        self.scripts = scripts; self.references = references; self.assets = assets; self.total = total
    }
}

/// A source can be registered with multiple agents. Fingerprints cover both
/// content and registrations; an acknowledgement never grants agent authority.
public struct SkillRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var sourcePath: String
    public var registrations: [SkillRegistration]
    public var issues: Set<SkillIssue>
    public var notes: [String]
    public var fingerprint: String
    public var lastModified: Date?
    public var counts: SkillFileCounts
    public var isReviewed: Bool

    public init(id: String, name: String, description: String = "", sourcePath: String,
                registrations: [SkillRegistration], issues: Set<SkillIssue> = [],
                notes: [String] = [], fingerprint: String = "", lastModified: Date? = nil,
                counts: SkillFileCounts = SkillFileCounts(), isReviewed: Bool = false) {
        self.id = id; self.name = name; self.description = description; self.sourcePath = sourcePath
        self.registrations = registrations; self.issues = issues; self.notes = notes
        self.fingerprint = fingerprint; self.lastModified = lastModified; self.counts = counts
        self.isReviewed = isReviewed
    }

    public var isDiscoverable: Bool { registrations.contains(where: \.isDiscoverable) }
    public var needsReview: Bool { !issues.isEmpty }
    public var isShared: Bool { registrations.count > 1 }
    public var canReview: Bool {
        !fingerprint.isEmpty && issues.isDisjoint(with: [.unreadable, .scanIncomplete, .brokenLink, .invalidSkill])
    }
    public var statusLabel: String {
        SkillIssue.allCases.first(where: issues.contains)?.label
            ?? (isReviewed ? "REVIEWED" : "DISCOVERABLE")
    }
}

public struct SkillScanIssue: Equatable, Sendable, Identifiable {
    public var id: String { path + ":" + issue.rawValue }
    public var path: String
    public var issue: SkillIssue
    public var message: String

    public init(path: String, issue: SkillIssue, message: String) {
        self.path = path; self.issue = issue; self.message = message
    }
}

public struct SkillAuditSnapshot: Equatable, Sendable {
    public var records: [SkillRecord]
    public var issues: [SkillScanIssue]
    public var scannedAt: Date?
    public var rootsScanned: Int

    public init(records: [SkillRecord] = [], issues: [SkillScanIssue] = [],
                scannedAt: Date? = nil, rootsScanned: Int = 0) {
        self.records = records; self.issues = issues; self.scannedAt = scannedAt
        self.rootsScanned = rootsScanned
    }

    public var flaggedCount: Int { records.filter(\.needsReview).count + issues.count }
    public var discoverableCount: Int { records.filter(\.isDiscoverable).count }
    public var registrationCount: Int { records.reduce(0) { $0 + $1.registrations.count } }
    public var sortedRecords: [SkillRecord] {
        records.sorted {
            if $0.needsReview != $1.needsReview { return $0.needsReview }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    public var reportText: String {
        // Filenames/frontmatter are untrusted. Keep terminal control characters
        // out of a report without changing the paths stored in the snapshot.
        func clean(_ value: String) -> String {
            String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
        }
        var lines = ["Skills Audit — \(records.count) sources · \(registrationCount) registrations · \(flaggedCount) need review",
                     "Scope: local user skills and known projects; bundled, plugin, and admin skills excluded.",
                     "Discoverable means found on disk, not loaded or enabled. Unchanged is not a safety verdict."]
        for item in issues {
            lines.append("[\(item.issue.label)] \(clean(item.path)) — \(clean(item.message))")
        }
        for record in sortedRecords {
            lines.append("")
            lines.append("[\(record.statusLabel)] \(clean(record.name))\(record.isShared ? " · SHARED SOURCE" : "")")
            lines.append("  Source: \(clean(record.sourcePath))")
            if !record.description.isEmpty { lines.append("  Description: \(clean(record.description))") }
            lines.append("  Contents: \(record.counts.total) files · \(record.counts.scripts) scripts · \(record.counts.references) references · \(record.counts.assets) assets")
            lines.append("  Fingerprint: \(record.fingerprint.isEmpty ? "unavailable" : clean(record.fingerprint))")
            if record.issues.count > 1 {
                lines.append("  Findings: " + SkillIssue.allCases.filter(record.issues.contains).map(\.label).joined(separator: " · "))
            }
            for registration in record.registrations {
                lines.append("  \(registration.agent.rawValue) · \(registration.scope.rawValue) · \(registration.isSymlink ? "symlink" : "directory"): \(clean(registration.path))\(registration.isDiscoverable ? "" : " · not discoverable")")
            }
            for note in record.notes { lines.append("  \(clean(note))") }
        }
        return lines.joined(separator: "\n")
    }
}
