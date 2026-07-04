import Foundation
import PerchCore

/// Historical token-usage aggregation, computed on demand from the same
/// on-disk sources the live tailers read: Claude transcript JSONL
/// (`message.usage`, deduped by message.id+requestId — ccusage's rule) and
/// Codex rollout `token_count` totals. Read-only; never touches the stores.

struct TokenBucket: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheCreate = 0

    var total: Int { input + output + cacheRead + cacheCreate }
    var isEmpty: Bool { total == 0 }

    mutating func add(_ other: TokenBucket) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheCreate += other.cacheCreate
    }
}

struct DayUsage: Identifiable, Equatable {
    let day: Date
    var claude = TokenBucket()
    var codex = TokenBucket()
    var id: Date { day }
    var total: Int { claude.total + codex.total }
}

struct ModelUsage: Identifiable, Equatable {
    let agent: AgentKind
    let model: String
    var bucket = TokenBucket()
    var id: String { "\(agent.rawValue):\(model)" }
}

struct ProjectUsage: Identifiable, Equatable {
    let project: String
    var bucket = TokenBucket()
    var id: String { project }
}

struct UsageHistorySnapshot: Equatable {
    var days: [DayUsage] = []          // ascending by day
    var models: [ModelUsage] = []      // descending by total
    var projects: [ProjectUsage] = []  // descending by total
    var claudeTotal = TokenBucket()
    var codexTotal = TokenBucket()
    var filesScanned = 0
    var skippedCompressed = 0
    var scannedAt: Date?

    var grandTotal: Int { claudeTotal.total + codexTotal.total }
}

// MARK: - Aggregator (pure, single-threaded; exercised by the selftest)

final class UsageHistoryAggregator {
    private let calendar: Calendar
    /// Lines timestamped before this are ignored (recently-modified transcript
    /// files can begin far outside the report window).
    private let cutoff: Date?
    private var days: [Date: DayUsage] = [:]
    private var models: [String: ModelUsage] = [:]
    private var projects: [String: ProjectUsage] = [:]
    private var claudeDedupe = Set<String>()
    private(set) var claudeTotal = TokenBucket()
    private(set) var codexTotal = TokenBucket()
    var filesScanned = 0
    var skippedCompressed = 0

    init(calendar: Calendar = .current, cutoff: Date? = nil) {
        self.calendar = calendar
        self.cutoff = cutoff
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseTimestamp(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// One Claude transcript line. Returns true when tokens were counted.
    @discardableResult
    func ingestClaudeLine(_ line: JSONValue) -> Bool {
        guard line["type"]?.string == "assistant",
              let usage = line["message"]?["usage"], usage.objectValue != nil,
              let tsRaw = line["timestamp"]?.string,
              let ts = Self.parseTimestamp(tsRaw) else { return false }
        if let cutoff, ts < cutoff { return false }

        // Dedupe only when BOTH ids are present (retried/streamed lines repeat
        // the same message.id+requestId with identical usage).
        if let messageId = line["message"]?["id"]?.string,
           let requestId = line["requestId"]?.string {
            let key = messageId + ":" + requestId
            if claudeDedupe.contains(key) { return false }
            claudeDedupe.insert(key)
        }

        let model = line["message"]?["model"]?.string ?? "claude"
        guard model != "<synthetic>" else { return false }

        var bucket = TokenBucket()
        bucket.input = usage["input_tokens"]?.int ?? 0
        bucket.output = usage["output_tokens"]?.int ?? 0
        bucket.cacheRead = usage["cache_read_input_tokens"]?.int ?? 0
        bucket.cacheCreate = usage["cache_creation_input_tokens"]?.int ?? 0
        guard !bucket.isEmpty else { return false }

        add(agent: .claude, day: calendar.startOfDay(for: ts), model: model,
            project: line["cwd"]?.string, bucket: bucket)
        return true
    }

    /// One Codex session's final cumulative totals. Codex `input_tokens`
    /// INCLUDES cached tokens (observed on live rollouts), so cached is
    /// split out to avoid double counting.
    func ingestCodexSession(day: Date, model: String?, cwd: String?,
                            input: Int, cached: Int, output: Int) {
        var bucket = TokenBucket()
        bucket.cacheRead = max(0, cached)
        bucket.input = max(0, input - max(0, cached))
        bucket.output = max(0, output)
        guard !bucket.isEmpty else { return }
        add(agent: .codex, day: calendar.startOfDay(for: day),
            model: model ?? "codex", project: cwd, bucket: bucket)
    }

    private func add(agent: AgentKind, day: Date, model: String, project: String?, bucket: TokenBucket) {
        days[day, default: DayUsage(day: day)].accumulate(agent: agent, bucket: bucket)

        let modelKey = "\(agent.rawValue):\(model)"
        var m = models[modelKey] ?? ModelUsage(agent: agent, model: model)
        m.bucket.add(bucket)
        models[modelKey] = m

        let projectName = project.map { ($0 as NSString).lastPathComponent } ?? "unknown"
        var p = projects[projectName] ?? ProjectUsage(project: projectName)
        p.bucket.add(bucket)
        projects[projectName] = p

        switch agent {
        case .claude: claudeTotal.add(bucket)
        case .codex: codexTotal.add(bucket)
        }
    }

    func snapshot(scannedAt: Date? = nil) -> UsageHistorySnapshot {
        var snap = UsageHistorySnapshot()
        snap.days = days.values.sorted { $0.day < $1.day }
        snap.models = models.values.sorted {
            ($0.bucket.total, $1.id) > ($1.bucket.total, $0.id)
        }
        snap.projects = projects.values.sorted {
            ($0.bucket.total, $1.project) > ($1.bucket.total, $0.project)
        }
        snap.claudeTotal = claudeTotal
        snap.codexTotal = codexTotal
        snap.filesScanned = filesScanned
        snap.skippedCompressed = skippedCompressed
        snap.scannedAt = scannedAt
        return snap
    }
}

private extension DayUsage {
    mutating func accumulate(agent: AgentKind, bucket: TokenBucket) {
        switch agent {
        case .claude: claude.add(bucket)
        case .codex: codex.add(bucket)
        }
    }
}

// MARK: - Scanner (background; streaming line reads)

enum UsageHistoryScanner {
    /// Synchronous full scan; call off the main thread.
    static func scan(daysBack: Int,
                     claudeProjectsDir: URL = PerchPaths.claudeConfigDir
                        .appendingPathComponent("projects", isDirectory: true),
                     codexSessionsDir: URL = PerchPaths.codexHomeDir
                        .appendingPathComponent("sessions", isDirectory: true),
                     now: Date = Date()) -> UsageHistorySnapshot {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -daysBack,
                                   to: calendar.startOfDay(for: now)) ?? now
        let aggregator = UsageHistoryAggregator(calendar: calendar, cutoff: cutoff)

        scanClaude(root: claudeProjectsDir, cutoff: cutoff, into: aggregator)
        scanCodex(root: codexSessionsDir, daysBack: daysBack, now: now,
                  calendar: calendar, into: aggregator)

        return aggregator.snapshot(scannedAt: now)
    }

    private static func scanClaude(root: URL, cutoff: Date, into agg: UsageHistoryAggregator) {
        let fm = FileManager.default
        // Recurse: transcripts live one level down (projects/<enc>/*.jsonl) but
        // subagent + workflow runs write their own real-token transcripts
        // deeper (…/<session>/subagents/**/agent-*.jsonl). Those are distinct
        // API spend — skipping them undercounts materially. The global
        // message.id+requestId dedup in ingestClaudeLine makes recursion safe:
        // any line that somehow appears in two files is still counted once.
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            // A file whose last write predates the window has no lines in it.
            guard mtime >= cutoff else { continue }
            agg.filesScanned += 1
            forEachLine(of: file) { line in
                guard let json = JSONValue(parsingLine: line) else { return }
                agg.ingestClaudeLine(json)
            }
        }
    }

    private static func scanCodex(root: URL, daysBack: Int, now: Date,
                                  calendar: Calendar, into agg: UsageHistoryAggregator) {
        let fm = FileManager.default
        var dayFormatter: DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy/MM/dd"
            return f
        }
        let formatter = dayFormatter
        for offset in 0...daysBack {
            guard let day = calendar.date(byAdding: .day, value: -offset,
                                          to: calendar.startOfDay(for: now)) else { continue }
            let dir = root.appendingPathComponent(formatter.string(from: day), isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }

            let plainStems = Set(files.filter { $0.pathExtension == "jsonl" }
                .map { $0.deletingPathExtension().lastPathComponent })
            for file in files {
                if file.lastPathComponent.hasSuffix(".jsonl.zst") {
                    let stem = file.lastPathComponent
                        .replacingOccurrences(of: ".jsonl.zst", with: "")
                    if !plainStems.contains(stem) { agg.skippedCompressed += 1 }
                    continue
                }
                guard file.pathExtension == "jsonl" else { continue }
                agg.filesScanned += 1
                ingestCodexRollout(file: file, day: day, into: agg)
            }
        }
    }

    private static func ingestCodexRollout(file: URL, day: Date, into agg: UsageHistoryAggregator) {
        var cwd: String?
        var model: String?
        var input = 0, cached = 0, output = 0

        forEachLine(of: file) { raw in
            guard let line = JSONValue(parsingLine: raw) else { return }
            let type = line["type"]?.string
            let payload = line["payload"]
            switch type {
            case "session_meta":
                cwd = payload?["cwd"]?.string ?? cwd
                model = payload?["model"]?.string ?? model
            case "turn_context":
                model = payload?["model"]?.string ?? model
            case "event_msg", "token_count":
                let tc: JSONValue?
                if type == "token_count" {
                    tc = payload
                } else if payload?["type"]?.string == "token_count" {
                    tc = payload
                } else {
                    tc = nil
                }
                guard let info = tc?["info"], let totals = info["total_token_usage"] else { return }
                // Cumulative totals — later lines supersede earlier ones.
                input = totals["input_tokens"]?.int ?? input
                cached = totals["cached_input_tokens"]?.int ?? cached
                output = totals["output_tokens"]?.int ?? output
            default:
                return
            }
        }

        agg.ingestCodexSession(day: day, model: model, cwd: cwd,
                               input: input, cached: cached, output: output)
    }

    /// Streaming line reader — bounded memory even on 100MB transcripts.
    /// Each chunk's read + parse runs in its own autoreleasepool: the per-line
    /// String bridging (plus whatever `body` parses) autoreleases, and without
    /// a pool here a multi-thousand-file sweep piles those allocations into
    /// one pool — RSS spiked ~460MB that malloc never returned to the OS.
    /// Draining per chunk bounds memory for every caller by construction,
    /// including a single huge transcript.
    static func forEachLine(of url: URL, _ body: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var buffer = Data()
        let chunkSize = 1 << 20
        while true {
            let done = autoreleasepool { () -> Bool in
                let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
                guard let chunk, !chunk.isEmpty else { return true }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<nl]
                    if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                        body(line)
                    }
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
                return false
            }
            if done { break }
        }
        if buffer.isEmpty { return }
        autoreleasepool {
            if let line = String(data: buffer, encoding: .utf8) { body(line) }
        }
    }
}

// MARK: - Formatting / headless report

enum TokenFormat {
    static func fmt(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.2fB", Double(n) / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }
}

extension UsageHistorySnapshot {
    /// Plain-text rendering for `Perch --usage-report`.
    var reportText: String {
        let f = TokenFormat.fmt
        var out: [String] = []
        out.append("Token usage — last 30 days")
        out.append("")
        out.append("Total: \(f(grandTotal))  (claude \(f(claudeTotal.total)) · codex \(f(codexTotal.total)))")
        out.append("")
        if !days.isEmpty {
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.dateFormat = "yyyy-MM-dd"
            out.append("Per day:")
            for d in days {
                var line = "  \(dayFormatter.string(from: d.day))  \(f(d.total))"
                if d.claude.total > 0 { line += "  claude \(f(d.claude.total))" }
                if d.codex.total > 0 { line += "  codex \(f(d.codex.total))" }
                out.append(line)
            }
            out.append("")
        }
        if !models.isEmpty {
            out.append("Per model:")
            for m in models.prefix(12) {
                out.append("  \(m.model) (\(m.agent.rawValue))  \(f(m.bucket.total))  " +
                           "[in \(f(m.bucket.input)) out \(f(m.bucket.output)) " +
                           "cache-r \(f(m.bucket.cacheRead)) cache-w \(f(m.bucket.cacheCreate))]")
            }
            out.append("")
        }
        if !projects.isEmpty {
            out.append("Per project (top 12):")
            for p in projects.prefix(12) {
                out.append("  \(p.project)  \(f(p.bucket.total))")
            }
            out.append("")
        }
        var note = "\(filesScanned) files scanned"
        if skippedCompressed > 0 {
            note += ", \(skippedCompressed) compressed codex rollouts skipped"
        }
        out.append(note)
        return out.joined(separator: "\n")
    }
}

// MARK: - Observable model for the window

@MainActor
final class UsageHistoryModel: ObservableObject {
    @Published private(set) var snapshot = UsageHistorySnapshot()
    @Published private(set) var scanning = false
    let daysBack = 30

    /// Showcase/selftest support: inject a snapshot without scanning.
    func injectSnapshot(_ snap: UsageHistorySnapshot) {
        snapshot = snap
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let days = daysBack
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snap = UsageHistoryScanner.scan(daysBack: days)
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = snap
                self.scanning = false
                PerchLog.info("Usage scan: \(snap.filesScanned) files, \(snap.grandTotal) tokens across \(snap.days.count) days",
                              category: "usage-history")
            }
        }
    }
}
