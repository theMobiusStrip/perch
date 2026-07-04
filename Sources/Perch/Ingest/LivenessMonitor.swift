import Darwin
import Foundation
import PerchCore

/// Polls ~/.claude/sessions/<pid>.json every 2 seconds, validates each entry
/// against the live process table (kill(pid, 0) + procStart double-check via
/// sysctl KERN_PROC_PID → kp_proc.p_starttime), and feeds the full live list
/// to the SessionStore. Dead or stale (pid-reused) entries are simply omitted;
/// the store removes sessions that drop out of the set.
@MainActor
final class LivenessMonitor {
    private let store: SessionStore
    private let queue = DispatchQueue(label: "dev.evan.perch.liveness", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let scanner = ClaudeSessionScanner()

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        let store = self.store
        let scanner = self.scanner
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(200),
                       repeating: .seconds(2),
                       leeway: .milliseconds(250))
        timer.setEventHandler {
            // Runs on `queue`; scanner is confined to it.
            let live = scanner.scan()
            Task { @MainActor in
                store.applyClaudeLiveness(live)
            }
        }
        timer.resume()
        self.timer = timer
        PerchLog.info("Liveness monitor polling \(scanner.sessionsDir.path)", category: "liveness")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        timer?.cancel()
    }
}

/// Does the actual scanning. Confined to LivenessMonitor's queue — never
/// touched from the main actor after start().
private final class ClaudeSessionScanner {
    let sessionsDir = PerchPaths.claudeConfigDir.appendingPathComponent("sessions", isDirectory: true)

    /// procStart observed live (v2.1.197) is a ctime-style string rendered in
    /// UTC ("Wed Jul  1 20:13:25 2026" for a 13:13:25 PDT start). Parse UTC
    /// first; keep a local-time interpretation as a tolerant fallback.
    private let utcFormatter: DateFormatter
    private let localFormatter: DateFormatter

    /// One-shot log guards so a bad file doesn't spam every 2s.
    private var warnedFiles: Set<String> = []
    private var reportedStale: Set<String> = []

    init() {
        func makeFormatter(_ tz: TimeZone) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            f.timeZone = tz
            return f
        }
        utcFormatter = makeFormatter(TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!)
        localFormatter = makeFormatter(TimeZone.current)
    }

    func scan() -> [ClaudeLiveInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: sessionsDir,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else {
            // Missing dir ⇒ no live sessions. (Also covers transient IO errors;
            // worst case sessions reappear on the next tick.)
            return []
        }
        var bySession: [String: ClaudeLiveInfo] = [:]
        for url in entries where url.pathExtension == "json" {
            guard let info = parseAndValidate(url) else { continue }
            // Duplicate sessionIds (stale file + fresh resume): keep the newest.
            if let existing = bySession[info.sessionId],
               (existing.startedAtMs ?? 0) > (info.startedAtMs ?? 0) {
                continue
            }
            bySession[info.sessionId] = info
        }
        return Array(bySession.values)
    }

    // MARK: - Per-file validation

    private func parseAndValidate(_ url: URL) -> ClaudeLiveInfo? {
        let fileName = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = try? JSONValue(parsing: data), json.objectValue != nil else {
            warnOnce(fileName, "unparseable session file")
            return nil
        }
        guard let pidValue = json["pid"]?.int, pidValue > 0, pidValue <= Int(Int32.max) else {
            warnOnce(fileName, "missing/invalid pid")
            return nil
        }
        let pid = Int32(pidValue)
        guard let sessionId = json["sessionId"]?.string, !sessionId.isEmpty else {
            warnOnce(fileName, "missing sessionId")
            return nil
        }
        guard isProcessAlive(pid) else { return nil }               // normal churn — no log
        guard passesStartTimeGuard(pid: pid,
                                   procStart: json["procStart"]?.string,
                                   file: fileName) else { return nil }

        return ClaudeLiveInfo(
            pid: pid,
            sessionId: sessionId,
            cwd: json["cwd"]?.string,
            startedAtMs: json["startedAt"]?.double.map { Int64($0) },
            version: json["version"]?.string,
            kind: json["kind"]?.string,
            entrypoint: json["entrypoint"]?.string,
            name: json["name"]?.string)
    }

    /// kill(pid, 0): 0 → alive; ESRCH → dead; EPERM → alive (exists, not ours).
    private func isProcessAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// pid-reuse guard: the file's procStart must match the actual process
    /// start time within ±5s. Fail-open when anything is missing/unparseable —
    /// dropping a live session is worse than briefly showing a stale one.
    private func passesStartTimeGuard(pid: Int32, procStart: String?, file: String) -> Bool {
        guard let raw = procStart, !raw.isEmpty else { return true }
        guard let actual = Self.processStartTime(pid: pid) else { return true }

        // ctime format pads single-digit days with a double space
        // ("Wed Jul  1 …") — normalize runs of whitespace before parsing.
        let normalized = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let candidates = [utcFormatter.date(from: normalized),
                          localFormatter.date(from: normalized)].compactMap { $0 }
        guard !candidates.isEmpty else {
            warnOnce(file, "unparseable procStart \"\(raw)\"")
            return true
        }

        let slack: TimeInterval = 5
        if candidates.contains(where: { abs($0.timeIntervalSince(actual)) <= slack }) {
            return true
        }
        if reportedStale.insert(file).inserted {
            PerchLog.info("Stale session file \(file): pid \(pid) reused (procStart mismatch)",
                          category: "liveness")
        }
        return false
    }

    /// Actual process start time via sysctl(KERN_PROC_PID) → kp_proc.p_starttime.
    static func processStartTime(pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_starttime
        let seconds = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func warnOnce(_ file: String, _ message: String) {
        guard warnedFiles.insert(file).inserted else { return }
        PerchLog.warn("\(file): \(message)", category: "liveness")
    }
}
