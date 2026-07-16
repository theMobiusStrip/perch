import Foundation
import PerchCore

/// Impure discovery + git spawning + sizing for the worktree audit — the
/// counterpart to the pure `WorktreeAudit`. Mirrors `IntegrityScanner`'s role:
/// it turns the on-disk / git truth into a `WorktreeSnapshot`, and does it
/// READ-ONLY.
///
/// Read-only extends to git side effects: a plain `git status` refreshes the
/// index (a write to `.git/index`). Every spawned command therefore runs with
/// `--no-optional-locks -c core.fsmonitor=false`, which suppresses the index
/// refresh and the fsmonitor daemon write. Nothing here deletes, prunes, or
/// fetches. See the verification protocol: the repo's `.git/index` mtime is
/// unchanged across a full scan.
enum WorktreeScanner {
    /// Top-level directory names whose bytes are regenerable build output; we
    /// attribute them to a separate bulk counter so "494 MB, 490 MB of it build
    /// artifacts" reads honestly.
    static let bulkDirNames: Set<String> = [
        ".build", "node_modules", "target", "dist", ".venv",
        "__pycache__", ".next", "DerivedData",
    ]

    /// Per-invocation hard timeout for any single git command. This machine has
    /// no `timeout(1)`, so we kill via a DispatchWorkItem.
    static let gitTimeout: TimeInterval = 10

    // MARK: - Entry point

    /// Full metadata scan (no sizes — those come from `computeSizes`). Call off
    /// the main thread. `liveCwds` are the cwds of sessions Perch currently
    /// knows about, used to keep a running agent's worktree in `active`.
    static func scan(liveCwds: Set<String>,
                     staleDays: Int = PerchConfig.defaultWorktreeStaleDays,
                     now: Date = Date()) -> WorktreeSnapshot {
        // Resolve live cwds to physical paths once, so the live-session check
        // survives any symlink in the path (e.g. /tmp → /private/tmp) — git's
        // porcelain paths are already real-path resolved.
        let resolvedLive = Set(liveCwds.map { resolvePath($0) })
        let repoPaths = uniqueRepoPaths(candidates: candidateRoots(liveCwds: liveCwds, now: now))
        var repos: [RepoWorktrees] = []
        for repo in repoPaths {
            if let entry = scanRepo(repoPath: repo, liveCwds: resolvedLive, now: now) {
                repos.append(entry)
            }
        }
        return WorktreeSnapshot(repos: repos, staleDays: max(1, staleDays),
                                reposScanned: repos.count, scannedAt: now)
    }

    // MARK: - Candidate discovery

    /// Repo-or-worktree roots worth inspecting: live session cwds, the cwd
    /// recorded in each recent Claude transcript, and any Codex worktree.
    /// Live cwds are included as roots (a Codex session in a plain repo with no
    /// Claude transcript would otherwise never surface its repo).
    private static func candidateRoots(liveCwds: Set<String>, now: Date) -> [String] {
        var roots = Set<String>()
        roots.formUnion(liveCwds)
        roots.formUnion(historicalClaudeRoots(now: now))
        roots.formUnion(codexWorktreeRoots())
        return Array(roots)
    }

    /// Physical path with symlinks resolved; falls back to the input if the
    /// path does not exist (a not-yet/never-existing cwd stays comparable).
    private static func resolvePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// For every `~/.claude/projects/<slug>/`, read the cwd from the newest
    /// transcript's first parseable line. Transcript lines carry the real cwd,
    /// so we never try to decode the slug. Slugs whose newest file is > 60 days
    /// old are skipped; results are cached per slug keyed by that file's mtime.
    private static func historicalClaudeRoots(now: Date) -> [String] {
        let projects = PerchPaths.claudeConfigDir.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        guard let slugs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        let cutoff = now.addingTimeInterval(-60 * 86_400)
        var roots: [String] = []
        for slug in slugs {
            guard (try? slug.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let newest = newestTranscript(in: slug), newest.mtime >= cutoff else { continue }
            if let cwd = SlugCwdCache.shared.cwd(slug: slug.lastPathComponent, file: newest.url, mtime: newest.mtime) {
                roots.append(cwd)
            }
        }
        return roots
    }

    private static func newestTranscript(in dir: URL) -> (url: URL, mtime: Date)? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        var best: (url: URL, mtime: Date)?
        for file in files where file.pathExtension == "jsonl" {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || mtime > best!.mtime { best = (file, mtime) }
        }
        return best
    }

    /// `~/.codex/worktrees/*` — cheap glob of Codex-managed worktrees.
    private static func codexWorktreeRoots() -> [String] {
        let dir = PerchPaths.codexHomeDir.appendingPathComponent("worktrees", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.path)
    }

    // MARK: - Normalize + dedupe to main repos

    /// Map each candidate (which may itself be a linked worktree) to the main
    /// repository's toplevel via `--git-common-dir`, then dedupe. Candidates
    /// that aren't inside any git repo are dropped.
    private static func uniqueRepoPaths(candidates: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for candidate in candidates {
            guard let repo = mainRepoPath(for: candidate) else { continue }
            if seen.insert(repo).inserted { ordered.append(repo) }
        }
        return ordered
    }

    private static func mainRepoPath(for candidate: String) -> String? {
        let dir = URL(fileURLWithPath: candidate, isDirectory: true)
        guard let out = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir),
              !out.value.isEmpty else { return nil }
        let common = URL(fileURLWithPath: out.value.trimmingCharacters(in: .whitespacesAndNewlines))
        // Normal repos: common dir is <repo>/.git → the repo is its parent.
        // Bare repos: the common dir itself is the repo.
        return common.lastPathComponent == ".git" ? common.deletingLastPathComponent().path : common.path
    }

    // MARK: - Per-repo scan

    private static func scanRepo(repoPath: String, liveCwds: Set<String>, now: Date) -> RepoWorktrees? {
        let repoURL = URL(fileURLWithPath: repoPath, isDirectory: true)
        guard let listed = git(["worktree", "list", "--porcelain"], in: repoURL) else { return nil }
        let entries = WorktreeAudit.parseWorktreePorcelain(listed.value)
        guard let main = entries.first else { return nil }
        let canonicalRepo = main.path
        let ref = defaultRef(repo: repoURL)

        var worktrees: [WorktreeInfo] = []
        for entry in entries where !entry.isMain {
            worktrees.append(worktreeInfo(entry: entry, repo: repoURL, defaultRef: ref,
                                          liveCwds: liveCwds, now: now))
        }
        // Omit repos with no linked worktrees — nothing to report or reclaim.
        guard !worktrees.isEmpty else { return nil }
        return RepoWorktrees(repoPath: canonicalRepo, worktrees: worktrees)
    }

    private static func worktreeInfo(entry: PorcelainEntry, repo: URL, defaultRef: String?,
                                     liveCwds: Set<String>, now: Date) -> WorktreeInfo {
        let origin: WorktreeOrigin =
            (entry.path.contains("/.claude/worktrees/") || entry.path.contains("/.codex/worktrees/"))
            ? .agent : .manual
        // `liveCwds` is already symlink-resolved (see scan); resolve the
        // porcelain path the same way so a live session is never missed on a
        // path-form mismatch and its worktree wrongly called reclaimable.
        let resolvedPath = resolvePath(entry.path)
        let hasLive = liveCwds.contains { $0 == resolvedPath || $0.hasPrefix(resolvedPath + "/") }

        // Prunable = directory gone; skip the git/stat probes entirely.
        if entry.prunable {
            return WorktreeInfo(path: entry.path, isMain: false, branch: entry.branch,
                                detached: entry.detached, dirtyCount: 0, aheadCount: nil,
                                ageDays: 0, hasLiveSession: hasLive, prunable: true,
                                locked: entry.locked, origin: origin)
        }

        let wtURL = URL(fileURLWithPath: entry.path, isDirectory: true)
        var ambiguous = false

        // Dirty count. Launch failure, timeout, OR a non-zero exit (a broken
        // gitdir pointer, a dubious-ownership refusal, a worktree on an
        // unmounted volume) all mean Perch could not observe the working tree
        // — treat it as ambiguous so it can never be called clean/reclaimable.
        var dirty = 0
        if let status = git(["status", "--porcelain"], in: wtURL), status.ok {
            dirty = status.value.split(separator: "\n", omittingEmptySubsequences: true).count
        } else {
            ambiguous = true
        }

        // Commits ahead of the default branch, via the worktree's HEAD sha
        // (works for detached HEADs too). No reachable default or a git error
        // leaves ahead nil → `review`.
        var ahead: Int? = nil
        if let ref = defaultRef, let head = entry.head,
           let out = git(["rev-list", "--count", "\(ref)..\(head)"], in: repo), out.ok,
           let n = Int(out.value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            ahead = n
        } else {
            ambiguous = true
        }

        // Age from the directory mtime.
        var ageDays = 0
        if let mtime = (try? wtURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            ageDays = max(0, Int(now.timeIntervalSince(mtime) / 86_400))
        } else {
            ambiguous = true
        }

        // Ambiguity of any kind must never resolve to reclaimable; nil ahead is
        // the classifier's `review` lever.
        if ambiguous { ahead = nil }

        return WorktreeInfo(path: entry.path, isMain: false, branch: entry.branch,
                            detached: entry.detached, dirtyCount: dirty, aheadCount: ahead,
                            ageDays: ageDays, hasLiveSession: hasLive, prunable: false,
                            locked: entry.locked, origin: origin)
    }

    /// The repo's default branch ref to diff worktrees against:
    /// `origin/HEAD` if set, else a local `main`, else `master`. nil ⇒ every
    /// worktree's ahead-count is unknown ⇒ all land in `review`.
    private static func defaultRef(repo: URL) -> String? {
        if let out = git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo) {
            let ref = out.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ref.isEmpty { return ref }
        }
        for name in ["main", "master"] {
            if let out = git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: repo),
               !out.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
        }
        return nil
    }

    // MARK: - Sizing (async second pass)

    /// Fill `sizeBytes`/`bulkBytes` on a metadata snapshot. Call off the main
    /// thread after `scan`; the list renders first with "…" placeholders.
    static func computeSizes(_ snapshot: WorktreeSnapshot) -> WorktreeSnapshot {
        var snap = snapshot
        var sizedPaths = Set<String>()
        for i in snap.repos.indices {
            for j in snap.repos[i].worktrees.indices {
                let wt = snap.repos[i].worktrees[j]
                if wt.prunable {
                    snap.repos[i].worktrees[j].sizeBytes = 0
                    snap.repos[i].worktrees[j].bulkBytes = 0
                    continue
                }
                let sized = SizeCache.shared.size(of: wt.path)
                snap.repos[i].worktrees[j].sizeBytes = sized.total
                snap.repos[i].worktrees[j].bulkBytes = sized.bulk
                sizedPaths.insert(wt.path)
            }
        }
        // Evict cached sizes for worktrees that have since vanished.
        SizeCache.shared.retain(sizedPaths)
        return snap
    }

    /// Directory walk reading `totalFileAllocatedSize`, draining a per-file
    /// autoreleasepool. This copies the RSS discipline of
    /// `UsageHistoryScanner.forEachLine`: without a pool, a multi-thousand-file
    /// sweep piles the per-file `resourceValues` bridging into one pool and RSS
    /// climbs by hundreds of MB that malloc never returns to the OS. Bytes
    /// under any `bulkDirNames` component are also tallied as regenerable bulk.
    static func directorySize(_ path: String) -> (total: Int64, bulk: Int64) {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []) else { return (0, 0) }
        let prefixCount = path.hasSuffix("/") ? path.count : path.count + 1
        var total: Int64 = 0
        var bulk: Int64 = 0
        for case let file as URL in walker {
            autoreleasepool {
                guard let vals = try? file.resourceValues(forKeys: Set(keys)),
                      vals.isRegularFile == true, let size = vals.totalFileAllocatedSize else { return }
                let bytes = Int64(size)
                total += bytes
                let relative = file.path.count > prefixCount ? String(file.path.dropFirst(prefixCount)) : ""
                // Match only ANCESTOR directory components (dropLast excludes the
                // file's own basename) so a regular file merely named `dist` or
                // `.build` isn't miscounted as regenerable build output.
                if relative.split(separator: "/").dropLast().contains(where: { bulkDirNames.contains(String($0)) }) {
                    bulk += bytes
                }
            }
        }
        return (total, bulk)
    }

    // MARK: - git spawning

    private struct GitOutput { let value: String; let ok: Bool }

    /// Run one git command read-only with a hard timeout. Returns nil when the
    /// process can't launch (bad cwd, missing binary) or is killed; otherwise
    /// the captured stdout plus the zero-exit flag.
    private static func git(_ args: [String], in dir: URL) -> GitOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // --no-optional-locks + fsmonitor off keeps `status` (and friends) from
        // writing .git/index — the read-only guarantee. Prepended to every call.
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false"] + args
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice  // don't let stderr fill a pipe we never drain
        // The kill work item below is retained by the dispatch timer until its
        // deadline even after cancel(), and it captures `process` (→ this
        // pipe's read FD). Close the read end explicitly at return so a large
        // scan can't leak one FD per git call toward the process limit.
        defer { try? outPipe.fileHandleForReading.close() }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Kill if it outlives the timeout (no timeout(1) on this machine).
        var timedOut = false
        let killer = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gitTimeout, execute: killer)

        // Read to EOF before waiting — EOF arrives when git exits (or is killed).
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        if timedOut {
            PerchLog.warn("git \(args.first ?? "?") timed out in \(dir.lastPathComponent)", category: "worktrees")
            return nil
        }
        return GitOutput(value: String(data: data, encoding: .utf8) ?? "",
                         ok: process.terminationStatus == 0)
    }
}

// MARK: - Caches

/// Per-slug cache of the cwd read from a transcript, keyed by the newest file's
/// mtime so an unchanged project isn't re-read every 30-minute scan.
private final class SlugCwdCache: @unchecked Sendable {
    static let shared = SlugCwdCache()
    private let lock = NSLock()
    private var store: [String: (mtime: Date, cwd: String?)] = [:]

    func cwd(slug: String, file: URL, mtime: Date) -> String? {
        lock.lock()
        if let hit = store[slug], hit.mtime == mtime {
            lock.unlock()
            return hit.cwd
        }
        lock.unlock()

        let cwd = firstCwd(in: file)
        lock.lock()
        store[slug] = (mtime, cwd)
        lock.unlock()
        return cwd
    }

    /// The `cwd` from the first parseable JSON line of a transcript.
    private func firstCwd(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        while buffer.count < (1 << 20) {  // a cwd shows up in the first line; cap the read
            guard let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let json = JSONValue(parsingLine: String(data: lineData, encoding: .utf8) ?? ""),
                   let cwd = json["cwd"]?.string, !cwd.isEmpty {
                    return cwd
                }
            }
        }
        if let json = JSONValue(parsingLine: String(data: buffer, encoding: .utf8) ?? ""),
           let cwd = json["cwd"]?.string, !cwd.isEmpty {
            return cwd
        }
        return nil
    }
}

/// Directory-size cache keyed by (path, mtime): a worktree whose top-level
/// mtime is unchanged since the last walk reuses the prior byte totals.
private final class SizeCache: @unchecked Sendable {
    static let shared = SizeCache()
    private let lock = NSLock()
    private var store: [String: (mtime: Date, total: Int64, bulk: Int64)] = [:]

    func size(of path: String) -> (total: Int64, bulk: Int64) {
        let mtime = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        lock.lock()
        if let hit = store[path], hit.mtime == mtime {
            lock.unlock()
            return (hit.total, hit.bulk)
        }
        lock.unlock()

        let sized = WorktreeScanner.directorySize(path)
        lock.lock()
        store[path] = (mtime, sized.total, sized.bulk)
        lock.unlock()
        return sized
    }

    /// Drop cached sizes for paths not present in the latest scan — agent
    /// worktrees carry unique per-session names, so without eviction a
    /// weeks-resident app would accumulate a dead entry per worktree ever seen.
    func retain(_ keep: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        store = store.filter { keep.contains($0.key) }
    }
}

// MARK: - Observable model for the window / menu / notch glance

@MainActor
final class WorktreeModel: ObservableObject {
    @Published private(set) var snapshot = WorktreeSnapshot()
    @Published private(set) var scanning = false

    /// Live session cwds — fed by AppDelegate from the SessionStore, same
    /// source IntegrityModel uses. Keeps a running agent's worktree `active`.
    var liveCwdsProvider: () -> Set<String> = { [] }
    var staleDays: Int = PerchConfig.defaultWorktreeStaleDays

    /// Showcase/selftest support: set a snapshot without scanning.
    func injectSnapshot(_ snap: WorktreeSnapshot) {
        snapshot = snap
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let cwds = liveCwdsProvider()
        let days = staleDays
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Phase A: metadata (fast git calls) → publish so rows render with
            // "…" sizes immediately.
            let base = WorktreeScanner.scan(liveCwds: cwds, staleDays: days)
            Task { @MainActor in self?.snapshot = base }
            // Phase B: sizing (the slow directory walks) → publish filled.
            let sized = WorktreeScanner.computeSizes(base)
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = sized
                self.scanning = false
                PerchLog.info("Worktree scan: \(sized.totalCount) worktrees across \(sized.reposScanned) repos, "
                              + "reclaimable \(sized.reclaimableCount) (\(ByteFormat.fmt(sized.reclaimableBytes)))",
                              category: "worktrees")
            }
        }
    }
}
