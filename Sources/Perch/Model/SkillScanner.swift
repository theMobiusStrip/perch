import CryptoKit
import Darwin
import Foundation
import PerchCore

struct SkillScanLimits: Sendable {
    var maxSkills = 512
    var maxEntriesPerDirectory = 2_048
    var maxFilesPerSkill = 2_048
    var maxTotalFiles = 16_384
    var maxFileBytes = 2 * 1_024 * 1_024
    var maxSkillBytes = 16 * 1_024 * 1_024
    var maxTotalBytes = 64 * 1_024 * 1_024
    var maxDepth = 12
    var maxSymlinkHops = 32
    var maxProjectDirectories = 128
}

/// Reads only regular files through no-follow descriptors. Nested symlinks
/// are inventoried but not traversed; the root registration may be a symlink.
enum SkillScanner {
    private struct Root {
        var path: String
        var agent: AgentKind
        var scope: SkillScope
        var project: String?
        var contexts: Set<Int> = []
    }
    private struct Resolution {
        var path: String
        var links: [String] = []
        var issue: SkillIssue?
        var note: String?
        var missingOptionalPath = false
    }
    private struct Source {
        var record: SkillRecord
        var manifest: SkillFrontmatter?
        var identity: FileIdentity?
        var digestParts: [String] = []
    }
    private struct FileIdentity: Hashable {
        var device: dev_t
        var inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }
    private struct Budget {
        var files = 0
        var bytes = 0
    }

    /// Only add ancestors when a repository boundary can actually be found.
    /// An arbitrary cwd outside a repository does not enroll the whole home.
    static func projectRoots(from directories: [URL]) -> [URL] {
        Set(projectContexts(from: directories).flatMap { $0 }).sorted().map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Keep the discovered ancestors grouped by originating cwd. Two nested
    /// paths may belong to independent repositories or worktrees.
    private static func projectContexts(from directories: [URL]) -> [[String]] {
        var output: [[String]] = []
        for directory in directories.prefix(128) {
            let start = directory.standardizedFileURL
            var cursor = start
            var ancestors: [String] = []
            var foundRepository = false
            for _ in 0..<64 {
                ancestors.append(cursor.path)
                var info = stat()
                if lstat(cursor.appendingPathComponent(".git").path, &info) == 0 {
                    foundRepository = true
                    break
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
            output.append(foundRepository ? ancestors : [start.path])
        }
        return output
    }

    static func scan(claudeDir: URL = PerchPaths.claudeConfigDir,
                     home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                     projectDirs: [URL] = [], acks: [String: String] = [:],
                     now: Date = Date(), limits: SkillScanLimits = SkillScanLimits()) -> SkillAuditSnapshot {
        var snapshot = SkillAuditSnapshot(scannedAt: now)
        var roots = [Root(path: claudeDir.appendingPathComponent("skills").path, agent: .claude, scope: .user),
                     Root(path: home.appendingPathComponent(".agents/skills").path, agent: .codex, scope: .user)]
        if projectDirs.count > max(0, limits.maxProjectDirectories) {
            snapshot.issues.append(SkillScanIssue(path: "Known projects", issue: .scanIncomplete,
                                                 message: "Project directory limit reached."))
        }
        let contexts = projectContexts(from: Array(projectDirs.prefix(max(0, limits.maxProjectDirectories))))
        let projects = Set(contexts.flatMap { $0 }).sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
        if projects.count > max(0, limits.maxProjectDirectories) {
            snapshot.issues.append(SkillScanIssue(path: "Project ancestors", issue: .scanIncomplete,
                                                 message: "Expanded project ancestor directory limit reached."))
        }
        for project in projects.prefix(max(0, limits.maxProjectDirectories)) {
            let projectContexts = Set(contexts.indices.filter { contexts[$0].contains(project.path) })
            roots.append(Root(path: project.appendingPathComponent(".claude/skills").path,
                              agent: .claude, scope: .project, project: project.path, contexts: projectContexts))
            roots.append(Root(path: project.appendingPathComponent(".agents/skills").path,
                              agent: .codex, scope: .project, project: project.path, contexts: projectContexts))
        }
        var sources: [String: Source] = [:]
        var sourceIDsByIdentity: [FileIdentity: String] = [:]
        var seenRoots = Set<String>()
        var budget = Budget()
        var registrations = 0
        var effectiveNames: [String: String] = [:]
        var registrationContexts: [String: Set<Int>] = [:]
        for root in roots {
            guard seenRoots.insert(root.agent.rawValue + ":" + root.path).inserted else { continue }
            let resolvedRoot = resolve(root.path, maxHops: limits.maxSymlinkHops)
            if let issue = resolvedRoot.issue {
                // Missing optional discovery directories are normal. A dangling
                // symlink or inaccessible directory remains a visible finding.
                if resolvedRoot.missingOptionalPath { continue }
                snapshot.issues.append(SkillScanIssue(path: root.path, issue: issue,
                                                     message: resolvedRoot.note ?? "Cannot inspect discovery root."))
                continue
            }
            let directory = open(resolvedRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard directory >= 0 else {
                snapshot.issues.append(SkillScanIssue(path: root.path, issue: .unreadable,
                                                     message: "Cannot open discovery directory."))
                continue
            }
            var rootInfo = stat()
            var rootPathInfo = stat()
            guard fstat(directory, &rootInfo) == 0,
                  lstat(resolvedRoot.path, &rootPathInfo) == 0, sameFile(rootInfo, rootPathInfo) else {
                close(directory)
                snapshot.issues.append(SkillScanIssue(path: root.path, issue: .scanIncomplete,
                                                     message: "Discovery root changed while opening it."))
                continue
            }
            var rootSourceIDs = Set<String>()
            snapshot.rootsScanned += 1
            let listing = names(in: directory, limit: limits.maxEntriesPerDirectory)
            if let issue = listing.issue {
                snapshot.issues.append(SkillScanIssue(path: root.path, issue: issue,
                                                     message: "Discovery directory could not be fully enumerated."))
            }
            for name in listing.names where !name.hasPrefix(".") && !(root.agent == .claude && name == "synced") {
                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    snapshot.issues.append(SkillScanIssue(path: root.path + "/" + name, issue: .unreadable,
                                                         message: "Cannot inspect registration."))
                    continue
                }
                let kind = info.st_mode & S_IFMT
                guard kind == S_IFDIR || kind == S_IFLNK else { continue }
                guard registrations < max(0, limits.maxSkills) else {
                    snapshot.issues.append(SkillScanIssue(path: root.path, issue: .scanIncomplete,
                                                         message: "Skill registration limit reached."))
                    break
                }
                registrations += 1
                let path = root.path + "/" + name
                let resolved = resolve(path, maxHops: limits.maxSymlinkHops)
                var targetInfo = stat()
                let targetIdentity = resolved.issue == nil && lstat(resolved.path, &targetInfo) == 0 &&
                    targetInfo.st_mode & S_IFMT == S_IFDIR ? FileIdentity(targetInfo) : nil
                // Path spelling is not filesystem identity on case-insensitive
                // volumes. Keep stable path IDs, but hash each physical source once.
                let sourceID = resolved.issue == nil
                    ? targetIdentity.flatMap { sourceIDsByIdentity[$0] } ?? resolved.path
                    : "unresolved:" + path
                rootSourceIDs.insert(sourceID)
                var registration = SkillRegistration(agent: root.agent, scope: root.scope, path: path,
                                                     projectPath: root.project, isSymlink: kind == S_IFLNK,
                                                     isDiscoverable: resolved.issue == nil)
                if sources[sourceID] == nil {
                    if let issue = resolved.issue {
                        sources[sourceID] = Source(record: SkillRecord(id: sourceID, name: name, sourcePath: resolved.path,
                                                                      registrations: [], issues: [issue],
                                                                      notes: [resolved.note ?? "Cannot resolve registration."]),
                                                   digestParts: ["unresolved", path])
                    } else {
                        sources[sourceID] = inspect(resolved.path, fallbackName: name, limits: limits, budget: &budget)
                        if let identity = sources[sourceID]?.identity { sourceIDsByIdentity[identity] = sourceID }
                    }
                }
                guard var source = sources[sourceID] else { continue }
                // The target can remain stable while its registration changes
                // during hashing. Re-check the binding, not only target bytes.
                let latestResolution = resolve(path, maxHops: limits.maxSymlinkHops)
                var latestRegistration = stat()
                var latestTarget = stat()
                let targetChanged = targetIdentity != nil &&
                    (source.identity != targetIdentity || lstat(resolved.path, &latestTarget) != 0 ||
                     !sameFile(targetInfo, latestTarget) || !sameTime(targetInfo.st_ctimespec, latestTarget.st_ctimespec))
                if latestResolution.path != resolved.path || latestResolution.links != resolved.links ||
                    latestResolution.issue != resolved.issue || targetChanged ||
                    fstatat(directory, name, &latestRegistration, AT_SYMLINK_NOFOLLOW) != 0 ||
                    !sameFile(info, latestRegistration) || !sameTime(info.st_ctimespec, latestRegistration.st_ctimespec) {
                    source.record.issues.insert(.scanIncomplete)
                    source.record.notes.append("Registration changed during scan: \(path)")
                    registration.isDiscoverable = false
                }
                if let manifest = source.manifest {
                    if root.agent == .codex && manifest.unsupported.isEmpty {
                        if manifest.name == nil {
                            source.record.issues.insert(.invalidSkill)
                            source.record.notes.append("Codex requires a name field.")
                            registration.isDiscoverable = false
                        }
                        if manifest.description == nil {
                            source.record.issues.insert(.invalidSkill)
                            source.record.notes.append("Codex requires a description field.")
                            registration.isDiscoverable = false
                        }
                    }
                    if !manifest.invalid.isEmpty || !manifest.unsupported.isEmpty { registration.isDiscoverable = false }
                } else { registration.isDiscoverable = false }
                source.record.registrations.append(registration)
                // Claude's frontmatter name is a display label; its local
                // command name is the registration directory basename.
                effectiveNames[registration.id] = root.agent == .claude ? name : source.manifest?.name ?? name
                registrationContexts[registration.id] = root.contexts
                source.digestParts.append("registration:" + registration.id + ":" + (root.project ?? ""))
                source.digestParts.append(contentsOf: resolvedRoot.links + resolved.links)
                source.record.lastModified = newest(source.record.lastModified, modification(info))
                if kind == S_IFLNK {
                    source.record.notes.append("Symlink: \(path) → \(resolved.path)")
                }
                sources[sourceID] = source
            }
            let latestRoot = resolve(root.path, maxHops: limits.maxSymlinkHops)
            var latestRootInfo = stat()
            if latestRoot.issue != nil || latestRoot.path != resolvedRoot.path || latestRoot.links != resolvedRoot.links ||
                lstat(latestRoot.path, &latestRootInfo) != 0 || !sameFile(rootInfo, latestRootInfo) ||
                !sameTime(rootInfo.st_mtimespec, latestRootInfo.st_mtimespec) || !sameTime(rootInfo.st_ctimespec, latestRootInfo.st_ctimespec) {
                snapshot.issues.append(SkillScanIssue(path: root.path, issue: .scanIncomplete,
                                                     message: "Discovery root changed during scan."))
                for id in rootSourceIDs {
                    sources[id]?.record.issues.insert(.scanIncomplete)
                    sources[id]?.record.notes.append("Discovery root changed during scan: \(root.path)")
                }
            }
            close(directory)
        }
        var records = sources.values.map { source -> SkillRecord in
            var record = source.record
            var hash = SHA256()
            for part in source.digestParts.sorted() { add(part, to: &hash) }
            record.fingerprint = hex(hash.finalize())
            let complete = record.issues.isDisjoint(with: [.unreadable, .scanIncomplete, .brokenLink, .invalidSkill])
            let registrationMarkers = record.registrations.compactMap { acks[$0.reviewKey] }
            let registrationMismatch = registrationMarkers.contains { $0 != record.fingerprint }
            record.isReviewed = complete && acks[record.id] == record.fingerprint && !registrationMismatch
            if !record.isReviewed && (acks[record.id] != nil || !registrationMarkers.isEmpty ||
                                     (record.lastModified.map { now.timeIntervalSince($0) < 86_400 } ?? false)) {
                record.issues.insert(.changed)
            }
            record.notes = Array(Set(record.notes)).sorted()
            record.registrations.sort { $0.id < $1.id }
            return record
        }
        for left in records.indices {
            for right in records.indices where right > left {
                let conflicts = records[left].registrations.contains { lhs in
                    records[right].registrations.contains { rhs in
                        guard lhs.agent == rhs.agent, effectiveNames[lhs.id] == effectiveNames[rhs.id] else { return false }
                        if lhs.scope == .user || rhs.scope == .user { return true }
                        return !(registrationContexts[lhs.id] ?? []).isDisjoint(with: registrationContexts[rhs.id] ?? [])
                    }
                }
                if conflicts {
                    records[left].issues.insert(.nameConflict)
                    records[right].issues.insert(.nameConflict)
                }
            }
        }
        snapshot.records = records.sorted { $0.id < $1.id }
        return snapshot
    }

    private static func inspect(_ path: String, fallbackName: String, limits: SkillScanLimits,
                                budget: inout Budget) -> Source {
        var source = Source(record: SkillRecord(id: path, name: fallbackName, sourcePath: path, registrations: []))
        var entries = 0
        var sourceBytes = 0
        var manifestData: Data?
        var sawManifest = false
        var hash = SHA256()
        add("source:" + path, to: &hash)
        var expected = stat()
        guard lstat(path, &expected) == 0, expected.st_mode & S_IFMT == S_IFDIR else {
            source.record.issues.insert(.unreadable)
            source.record.notes.append("Source is not an accessible directory.")
            return source
        }
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard directory >= 0 else {
            source.record.issues.insert(.unreadable)
            source.record.notes.append("Source is not an accessible directory.")
            return source
        }
        defer { close(directory) }
        var verified = stat()
        guard fstat(directory, &verified) == 0, sameFile(expected, verified) else {
            source.record.issues.insert(.scanIncomplete)
            source.record.notes.append("Source directory changed during scan.")
            return source
        }
        source.identity = FileIdentity(verified)
        add("source inode:\(verified.st_dev):\(verified.st_ino)", to: &hash)
        func issue(_ kind: SkillIssue, _ note: String) {
            source.record.issues.insert(kind)
            if source.record.notes.count < 32 { source.record.notes.append(note) }
        }
        func walk(_ descriptor: Int32, relative: String, depth: Int) {
            guard depth <= max(0, limits.maxDepth) else {
                issue(.scanIncomplete, "Directory depth limit reached: \(relative)")
                return
            }
            var directoryBefore = stat()
            guard fstat(descriptor, &directoryBefore) == 0 else {
                issue(.unreadable, "Cannot inspect directory \(relative).")
                return
            }
            defer {
                var directoryAfter = stat()
                if fstat(descriptor, &directoryAfter) != 0 ||
                    !sameTime(directoryBefore.st_mtimespec, directoryAfter.st_mtimespec) ||
                    !sameTime(directoryBefore.st_ctimespec, directoryAfter.st_ctimespec) {
                    issue(.scanIncomplete, "Directory changed during scan: \(relative)")
                }
            }
            let listing = names(in: descriptor, limit: limits.maxEntriesPerDirectory)
            if let failure = listing.issue { issue(failure, "Directory enumeration incomplete: \(relative)") }
            for name in listing.names {
                guard entries < max(0, limits.maxFilesPerSkill), budget.files < max(0, limits.maxTotalFiles) else {
                    issue(.scanIncomplete, "File or entry limit reached.")
                    return
                }
                entries += 1
                budget.files += 1
                let child = relative.isEmpty ? name : relative + "/" + name
                if child == "SKILL.md" { sawManifest = true }
                if child == ".claude-plugin/plugin.json" {
                    issue(.scanIncomplete, "Plugin contents are outside the local-skills audit scope.")
                }
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    issue(.unreadable, "Cannot inspect \(child).")
                    continue
                }
                source.record.lastModified = newest(source.record.lastModified, modification(info))
                let kind = info.st_mode & S_IFMT
                if child == "SKILL.md" && kind != S_IFREG && kind != S_IFLNK {
                    issue(.invalidSkill, "SKILL.md must be a regular text file.")
                }
                add("entry:" + child + ":" + String(info.st_mode), to: &hash)
                if kind == S_IFLNK {
                    var buffer = [CChar](repeating: 0, count: 16_384)
                    let count = readlinkat(descriptor, name, &buffer, buffer.count)
                    if count >= 0 && count < buffer.count {
                        let target = String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        add("symlink:" + target, to: &hash)
                    }
                    issue(.scanIncomplete, "Nested symlink content was not followed: \(child)")
                } else if kind == S_IFDIR {
                    add("directory inode:\(info.st_dev):\(info.st_ino)", to: &hash)
                    let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard next >= 0 else { issue(.unreadable, "Cannot read directory \(child)."); continue }
                    defer { close(next) }
                    var opened = stat()
                    guard fstat(next, &opened) == 0, sameFile(info, opened) else {
                        issue(.scanIncomplete, "Directory changed during scan: \(child)")
                        continue
                    }
                    walk(next, relative: child, depth: depth + 1)
                } else if kind == S_IFREG {
                    source.record.counts.total += 1
                    if child.hasPrefix("scripts/") { source.record.counts.scripts += 1 }
                    if child.hasPrefix("references/") { source.record.counts.references += 1 }
                    if child.hasPrefix("assets/") { source.record.counts.assets += 1 }
                    guard info.st_size >= 0,
                          info.st_size <= max(0, limits.maxFileBytes),
                          info.st_size <= max(0, limits.maxSkillBytes - sourceBytes),
                          info.st_size <= max(0, limits.maxTotalBytes - budget.bytes) else {
                        issue(.scanIncomplete, "Content byte limit reached: \(child)")
                        continue
                    }
                    let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard file >= 0 else { issue(.unreadable, "Cannot read \(child)."); continue }
                    defer { close(file) }
                    var opened = stat()
                    guard fstat(file, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, sameFile(info, opened) else {
                        issue(.scanIncomplete, "File changed during scan: \(child)")
                        continue
                    }
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 32_768)
                    var fileHash = SHA256()
                    var readBytes = 0
                    var fullyRead = true
                    while true {
                        let count = read(file, &buffer, buffer.count)
                        if count == 0 { break }
                        if count < 0 {
                            if errno == EINTR { continue }
                            issue(.unreadable, "Cannot finish reading \(child).")
                            fullyRead = false
                            break
                        }
                        guard count <= max(0, limits.maxFileBytes - readBytes),
                              count <= max(0, limits.maxSkillBytes - sourceBytes),
                              count <= max(0, limits.maxTotalBytes - budget.bytes) else {
                            issue(.scanIncomplete, "Content grew beyond byte limit: \(child)")
                            fullyRead = false
                            break
                        }
                        readBytes += count; sourceBytes += count; budget.bytes += count
                        let chunk = Data(buffer.prefix(count))
                        fileHash.update(data: chunk)
                        if child == "SKILL.md" { data.append(chunk) }
                    }
                    var after = stat()
                    if fstat(file, &after) != 0 || !sameFile(opened, after) || opened.st_size != after.st_size ||
                        !sameTime(opened.st_mtimespec, after.st_mtimespec) || !sameTime(opened.st_ctimespec, after.st_ctimespec) || readBytes != opened.st_size {
                        issue(.scanIncomplete, "File changed during scan: \(child)")
                        fullyRead = false
                    }
                    add("content:" + hex(fileHash.finalize()), to: &hash)
                    if child == "SKILL.md" && fullyRead { manifestData = data }
                } else {
                    issue(.scanIncomplete, "Special filesystem entry was not opened: \(child)")
                }
            }
        }
        var before = stat()
        if fstat(directory, &before) == 0 { source.record.lastModified = modification(before) }
        walk(directory, relative: "", depth: 0)
        var after = stat()
        if fstat(directory, &after) != 0 || !sameTime(before.st_mtimespec, after.st_mtimespec) || !sameTime(before.st_ctimespec, after.st_ctimespec) {
            issue(.scanIncomplete, "Source directory changed during scan.")
        }
        if let manifestData {
            if let text = String(data: manifestData, encoding: .utf8) {
                let manifest = SkillFrontmatter.parse(text)
                source.manifest = manifest
                source.record.name = manifest.name ?? fallbackName
                source.record.description = manifest.description ?? ""
                for note in manifest.invalid { issue(.invalidSkill, note) }
                for note in manifest.unsupported { issue(.scanIncomplete, note) }
            } else { issue(.invalidSkill, "SKILL.md is not UTF-8 text.") }
        } else if !sawManifest && source.record.issues.isEmpty {
            issue(.invalidSkill, "SKILL.md is missing.")
        } else if source.record.issues.isEmpty {
            issue(.scanIncomplete, "SKILL.md could not be fully inspected.")
        }
        source.digestParts.append("content:" + hex(hash.finalize()))
        return source
    }

    private static func names(in descriptor: Int32, limit: Int) -> (names: [String], issue: SkillIssue?) {
        let copy = dup(descriptor)
        guard copy >= 0 else { return ([], .unreadable) }
        guard let directory = fdopendir(copy) else { close(copy); return ([], .unreadable) }
        defer { closedir(directory) }
        var result: [String] = []
        var failure: SkillIssue?
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { failure = .unreadable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < max(0, limit) else { failure = .scanIncomplete; break }
            result.append(name)
        }
        return (result.sorted(), failure)
    }

    /// Resolve one component at a time, preserving symlink/.. semantics and a
    /// finite hop budget. Foundation's unbounded convenience resolver is not used.
    private static func resolve(_ path: String, maxHops: Int) -> Resolution {
        // The marker follows components introduced by a link's target. A
        // missing ordinary suffix after a valid ancestor link is still an
        // absent optional root, not a dangling link (/tmp is a common case).
        var pending = path.split(separator: "/").map { (name: String($0), linkTarget: false) }
        var components: [String] = []
        var result = Resolution(path: path)
        var hops = 0
        var inspected = 0
        while !pending.isEmpty {
            inspected += 1
            guard inspected <= 1_024 else {
                result.issue = .scanIncomplete; result.note = "Path component limit reached."; return result
            }
            let next = pending.removeFirst()
            let component = next.name
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            let candidate = "/" + (components + [component]).joined(separator: "/")
            var info = stat()
            guard lstat(candidate, &info) == 0 else {
                let failure = errno
                result.path = candidate + (pending.isEmpty ? "" : "/" + pending.map(\.name).joined(separator: "/"))
                if failure == ENOENT {
                    result.issue = .brokenLink
                    result.missingOptionalPath = !next.linkTarget
                    result.note = "Path or symlink target does not exist."
                } else if failure == ENOTDIR {
                    result.issue = .scanIncomplete
                    result.note = "A discovery path component is not a directory."
                } else {
                    result.issue = .unreadable
                    result.note = "Path cannot be inspected."
                }
                return result
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                hops += 1
                guard hops <= max(0, maxHops) else {
                    result.issue = .scanIncomplete; result.note = "Symlink cycle or hop limit reached."; return result
                }
                var buffer = [CChar](repeating: 0, count: 16_384)
                let count = readlink(candidate, &buffer, buffer.count)
                guard count > 0, count < buffer.count else {
                    result.issue = .unreadable; result.note = "Symlink target cannot be read."; return result
                }
                let target = String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                result.links.append("link:" + candidate + "→" + target)
                if target.hasPrefix("/") { components = [] }
                pending = target.split(separator: "/").map { (name: String($0), linkTarget: true) } + pending
            } else {
                // Kernel traversal requires each intermediate component to
                // be a directory, even when the next component is "..".
                guard pending.isEmpty || info.st_mode & S_IFMT == S_IFDIR else {
                    result.path = candidate + "/" + pending.map(\.name).joined(separator: "/")
                    result.issue = .scanIncomplete
                    result.note = "A discovery path component is not a directory."
                    return result
                }
                components.append(component)
            }
        }
        result.path = "/" + components.joined(separator: "/")
        return result
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
    }
    private static func sameTime(_ lhs: timespec, _ rhs: timespec) -> Bool {
        lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
    }
    private static func modification(_ info: stat) -> Date {
        Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
    private static func newest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }; guard let rhs else { return lhs }; return max(lhs, rhs)
    }
    private static func add(_ value: String, to hash: inout SHA256) {
        let bytes = Data(value.utf8)
        hash.update(data: Data("\(bytes.count):".utf8))
        hash.update(data: bytes)
    }
    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
