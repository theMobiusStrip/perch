import Foundation

/// Pure model + classifier for the worktree audit — the read-only cross-project
/// inventory of stale agent git worktrees. Everything here is deterministic and
/// free of process/filesystem side effects, so the selftest drives it directly;
/// the impure discovery/sizing side lives in `WorktreeScanner` (Sources/Perch).
///
/// Perch reports and classifies; it never deletes. The one affordance is a
/// clipboard of `git worktree remove` lines the user runs themselves — see
/// `WorktreeSnapshot.cleanupCommands`, which emits nothing but text.

/// Which bucket a worktree falls in. Conservative by construction: anything
/// ambiguous (git errors, unknown ahead-count) lands in `review`, never
/// `reclaimable`, so Perch never nudges the user toward removing live work.
public enum WorktreeTier: String, Sendable, CaseIterable {
    /// A live agent session's cwd is inside it, or it was touched < 24h ago,
    /// or it is clean/merged but still younger than the stale threshold — in
    /// use or too fresh to reclaim. Also the main worktree (the repo itself).
    case active
    /// Not the main worktree, clean (0 dirty files), 0 commits ahead of the
    /// repo's default branch, no live session, and at least `staleDays` old.
    /// The only tier the cleanup clipboard covers.
    case reclaimable
    /// Dirty or ahead of the default branch, or something Perch could not
    /// resolve. Removing it could lose work, so it's shown for a human look.
    case review
    /// The porcelain entry is marked prunable — its directory is gone.
    case orphaned
}

/// Where a worktree came from, used only for the row tag. Cleanup covers every
/// reclaimable worktree regardless of origin.
public enum WorktreeOrigin: String, Sendable {
    /// Path is under `.claude/worktrees/` or `~/.codex/worktrees/`.
    case agent
    /// A worktree created outside the agent-managed locations.
    case manual
}

/// One worktree's read-only facts. `sizeBytes`/`bulkBytes` are nil until the
/// async sizing pass fills them (rows render "…" meanwhile).
public struct WorktreeInfo: Sendable, Equatable, Identifiable {
    public let path: String
    public let isMain: Bool
    /// Short branch name (refs/heads/ stripped); nil when detached.
    public let branch: String?
    public let detached: Bool
    /// Count of `git status --porcelain` lines. 0 when clean.
    public let dirtyCount: Int
    /// Commits ahead of the default branch. nil ⇒ Perch could not compute it
    /// (detached with no reachable default, git error) ⇒ treated as `review`.
    public let aheadCount: Int?
    /// Whole days since the directory's mtime. 0 ⇒ touched < 24h ago.
    public let ageDays: Int
    /// Total allocated bytes on disk; nil until sized.
    public var sizeBytes: Int64?
    /// Subset of `sizeBytes` under regenerable build dirs (.build, node_modules…).
    public var bulkBytes: Int64?
    /// A live session's cwd is this path or nested under it.
    public let hasLiveSession: Bool
    /// Porcelain marked this entry prunable (its gitdir points nowhere).
    public let prunable: Bool
    /// Porcelain marked this entry locked (`git worktree lock`) — an explicit
    /// do-not-touch that must never be offered as reclaimable.
    public let locked: Bool
    public let origin: WorktreeOrigin

    public var id: String { path }

    public init(path: String, isMain: Bool, branch: String?, detached: Bool,
                dirtyCount: Int, aheadCount: Int?, ageDays: Int,
                sizeBytes: Int64? = nil, bulkBytes: Int64? = nil,
                hasLiveSession: Bool, prunable: Bool, locked: Bool = false,
                origin: WorktreeOrigin) {
        self.path = path
        self.isMain = isMain
        self.branch = branch
        self.detached = detached
        self.dirtyCount = dirtyCount
        self.aheadCount = aheadCount
        self.ageDays = ageDays
        self.sizeBytes = sizeBytes
        self.bulkBytes = bulkBytes
        self.hasLiveSession = hasLiveSession
        self.prunable = prunable
        self.locked = locked
        self.origin = origin
    }

    /// Basename shown in the row (the memorable `funny-name-abcd12`).
    public var name: String { (path as NSString).lastPathComponent }
}

/// The pure tier decision. `staleDays` is the reclaimable age gate.
///
/// Precedence is conservative: prunable and main are decided first; a live
/// session or fresh mtime keeps a worktree `active`; only then does dirtiness
/// / ahead-count / staleness decide. A nil `aheadCount` (anything Perch could
/// not compute) always yields `review`, never `reclaimable`.
///
/// Known accepted false negative: a squash-merged branch still shows commits
/// ahead via `rev-list`, so it lands in `review` rather than `reclaimable`.
/// v1 does not try to detect squash merges (that needs patch-id/cherry
/// analysis and remote state); a human glance in `review` is the safe outcome.
public func classify(_ w: WorktreeInfo, staleDays: Int) -> WorktreeTier {
    if w.prunable { return .orphaned }
    if w.isMain { return .active }            // the repo itself is never garbage
    if w.hasLiveSession { return .active }    // a running agent beats a stale mtime
    if w.ageDays < 1 { return .active }       // touched < 24h ago
    if w.locked { return .review }            // explicit do-not-touch (git worktree lock)
    if w.dirtyCount > 0 { return .review }    // uncommitted work
    guard let ahead = w.aheadCount else { return .review }  // unknown ⇒ review
    if ahead > 0 { return .review }           // clean but unmerged: could lose commits
    if w.ageDays >= staleDays { return .reclaimable }
    return .active                            // clean & merged but still fresh
}

/// One parsed block of `git worktree list --porcelain`. The first block is the
/// main worktree.
public struct PorcelainEntry: Sendable, Equatable {
    public let path: String
    public let head: String?
    /// Short branch name with refs/heads/ stripped; nil when detached/bare.
    public let branch: String?
    public let detached: Bool
    public let bare: Bool
    public let locked: Bool
    public let prunable: Bool
    public let isMain: Bool
}

public enum WorktreeAudit {
    /// Parse `git worktree list --porcelain`. Blocks are separated by blank
    /// lines; each starts with `worktree <path>` and carries `HEAD <sha>`,
    /// then either `branch refs/heads/<name>`, `detached`, or `bare`, plus
    /// optional `locked`/`prunable` markers. The first block is the main
    /// worktree.
    public static func parseWorktreePorcelain(_ text: String) -> [PorcelainEntry] {
        var entries: [PorcelainEntry] = []
        var path: String?
        var head: String?
        var branch: String?
        var detached = false
        var bare = false
        var locked = false
        var prunable = false

        func flush() {
            guard let path else { return }
            entries.append(PorcelainEntry(
                path: path, head: head, branch: branch, detached: detached,
                bare: bare, locked: locked, prunable: prunable,
                isMain: entries.isEmpty))
            head = nil; branch = nil
            detached = false; bare = false; locked = false; prunable = false
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                path = nil
                continue
            }
            if let value = value(of: "worktree", in: line) {
                // A new `worktree` line without a preceding blank still starts
                // a fresh entry (defensive against odd spacing).
                if path != nil { flush() }
                path = value
            } else if let value = value(of: "HEAD", in: line) {
                head = value
            } else if let value = value(of: "branch", in: line) {
                branch = shortBranch(value)
            } else if line == "detached" {
                detached = true
            } else if line == "bare" {
                bare = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                prunable = true
            }
        }
        flush()
        return entries
    }

    private static func value(of key: String, in line: String) -> String? {
        let prefix = key + " "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func shortBranch(_ ref: String) -> String {
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        return ref
    }
}

/// One repository and its non-main worktrees.
public struct RepoWorktrees: Sendable, Equatable, Identifiable {
    /// The main worktree's toplevel path.
    public let repoPath: String
    /// Non-main worktrees only (the audit targets stray agent worktrees, not
    /// the repo itself).
    public var worktrees: [WorktreeInfo]

    public var id: String { repoPath }
    public var projectName: String { (repoPath as NSString).lastPathComponent }

    public init(repoPath: String, worktrees: [WorktreeInfo]) {
        self.repoPath = repoPath
        self.worktrees = worktrees
    }

    public var totalBytes: Int64 { worktrees.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
}

/// The whole cross-project audit result.
public struct WorktreeSnapshot: Sendable, Equatable {
    public var repos: [RepoWorktrees] = []
    public var staleDays: Int = PerchConfig.defaultWorktreeStaleDays
    public var reposScanned: Int = 0
    public var scannedAt: Date?

    public init(repos: [RepoWorktrees] = [],
                staleDays: Int = PerchConfig.defaultWorktreeStaleDays,
                reposScanned: Int = 0, scannedAt: Date? = nil) {
        self.repos = repos
        self.staleDays = staleDays
        self.reposScanned = reposScanned
        self.scannedAt = scannedAt
    }

    /// Every non-main worktree across every repo.
    public var allWorktrees: [WorktreeInfo] { repos.flatMap(\.worktrees) }

    public var totalCount: Int { allWorktrees.count }
    public var totalBytes: Int64 { allWorktrees.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
    public var bulkBytes: Int64 { allWorktrees.reduce(0) { $0 + ($1.bulkBytes ?? 0) } }

    public func tier(_ w: WorktreeInfo) -> WorktreeTier { classify(w, staleDays: staleDays) }

    public var reclaimable: [WorktreeInfo] { allWorktrees.filter { tier($0) == .reclaimable } }
    public var reclaimableCount: Int { reclaimable.count }
    public var reclaimableBytes: Int64 { reclaimable.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }

    /// Reclaimable-only cleanup, one `git worktree remove` per line, grouped by
    /// repo. Each line carries `-C <repo>` so it runs correctly from any cwd —
    /// the copied block may span several projects. Emits ONLY reclaimable
    /// worktrees; empty when there are none. Perch never runs these; the user
    /// does, in their own terminal.
    public var cleanupCommands: String { cleanupCommands(excludingPaths: []) }

    /// Same, minus `excluded` worktree paths. The snapshot's tiers are as old
    /// as the last scan, so the caller re-checks liveness at COPY time and
    /// passes any reclaimable-marked worktree a session has entered since —
    /// its removal must never reach the clipboard.
    public func cleanupCommands(excludingPaths excluded: Set<String>) -> String {
        var lines: [String] = []
        for repo in repos {
            for wt in repo.worktrees where tier(wt) == .reclaimable && !excluded.contains(wt.path) {
                lines.append("git -C \(shellQuote(repo.repoPath)) worktree remove \(shellQuote(wt.path))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// POSIX single-quote a path for a shell command line: wrap in single quotes,
/// and render any embedded single quote as `'\''`.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Decimal (base-1000) byte formatting with ~3 significant digits, matching the
/// "1.06 GB" / "494 MB" idiom in the window and report. Deterministic (no
/// locale/ByteCountFormatter dependence) so it's stable across machines.
public enum ByteFormat {
    public static func fmt(_ n: Int64) -> String {
        let d = Double(n)
        // Unit thresholds sit at 999.5 of the next unit so a value that would
        // round up to "1000 MB" renders as "1.00 GB" instead — the output
        // always keeps ~3 significant digits.
        if d >= 999_500_000 { return scaled(d / 1_000_000_000, "GB") }
        if d >= 999_500 { return scaled(d / 1_000_000, "MB") }
        if d >= 1_000 { return scaled(d / 1_000, "KB") }
        return "\(n) B"
    }

    private static func scaled(_ v: Double, _ unit: String) -> String {
        // Decimal cutoffs at the rounding boundary (99.95 → "100", 9.995 →
        // "10.0"), for the same reason as the unit thresholds above.
        let decimals: Int
        switch v {
        case 99.95...: decimals = 0
        case 9.995...: decimals = 1
        default: decimals = 2
        }
        return String(format: "%.\(decimals)f %@", v, unit)
    }
}

// MARK: - Headless report

public extension WorktreeSnapshot {
    /// Note text under a row, per tier — mirrors the window's row note.
    func note(for w: WorktreeInfo) -> String {
        switch tier(w) {
        case .orphaned:
            return "directory gone"
        case .active:
            var parts: [String] = []
            parts.append(w.hasLiveSession ? "live session" : (w.branch ?? "detached"))
            parts.append(ageText(w.ageDays))
            return parts.joined(separator: " · ")
        case .review:
            let head: String
            if w.dirtyCount > 0 {
                head = "\(w.dirtyCount) dirty file\(w.dirtyCount == 1 ? "" : "s")"
            } else if let ahead = w.aheadCount, ahead > 0 {
                head = "\(ahead) commit\(ahead == 1 ? "" : "s") not on main"
            } else if w.locked {
                head = "locked"
            } else {
                head = "git error — treated as review"
            }
            return "\(head) · \(ageText(w.ageDays))"
        case .reclaimable:
            var note = "clean · \(ageText(w.ageDays))"
            if let size = w.sizeBytes, let bulk = w.bulkBytes, bulk * 2 > size, bulk > 0 {
                note += " · \(ByteFormat.fmt(bulk)) build artifacts"
            }
            return note
        }
    }

    private func ageText(_ days: Int) -> String {
        days < 1 ? "today" : "\(days)d"
    }

    /// Plain-text rendering for `Perch --worktree-report`.
    var reportText: String {
        var out: [String] = []
        out.append("Worktrees — \(reposScanned) project\(reposScanned == 1 ? "" : "s") scanned")
        out.append("")
        var total = "Total: \(totalCount) worktree\(totalCount == 1 ? "" : "s") · \(ByteFormat.fmt(totalBytes))"
        if reclaimableCount > 0 {
            total += " · reclaimable \(ByteFormat.fmt(reclaimableBytes)) (\(reclaimableCount))"
        }
        out.append(total)

        // Projects by total size desc; within a project, reclaimable first.
        let ordered = repos.sorted { $0.totalBytes > $1.totalBytes }
        for repo in ordered where !repo.worktrees.isEmpty {
            out.append("")
            out.append("\(repo.projectName)  (\(repo.worktrees.count) · \(ByteFormat.fmt(repo.totalBytes)))")
            for wt in sortedForDisplay(repo.worktrees) {
                let tierLabel = pad(tier(wt).rawValue, to: 12)
                let name = pad(wt.name, to: 26)
                let size = wt.sizeBytes.map { ByteFormat.fmt($0) } ?? "…"
                out.append("  \(tierLabel) \(name) \(size)  \(note(for: wt))")
            }
        }

        let commands = cleanupCommands
        if !commands.isEmpty {
            out.append("")
            out.append("Cleanup commands (reclaimable only — run yourself; Perch never deletes):")
            for line in commands.split(separator: "\n") {
                out.append("  \(line)")
            }
        }
        return out.joined(separator: "\n")
    }

    /// Column padding that NEVER truncates: a review-tier row's name is the
    /// only identifier the user has (cleanup lines carry full paths only for
    /// reclaimable), so an over-long name breaks alignment instead of losing
    /// its disambiguating suffix. (`String.padding(toLength:)` would truncate.)
    private func pad(_ s: String, to width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    /// Rows ordered reclaimable (size desc) → review → active → orphaned.
    func sortedForDisplay(_ worktrees: [WorktreeInfo]) -> [WorktreeInfo] {
        func rank(_ t: WorktreeTier) -> Int {
            switch t {
            case .reclaimable: return 0
            case .review: return 1
            case .active: return 2
            case .orphaned: return 3
            }
        }
        return worktrees.sorted {
            let (ra, rb) = (rank(tier($0)), rank(tier($1)))
            if ra != rb { return ra < rb }
            return ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0)
        }
    }
}
