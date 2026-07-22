import Foundation
import PerchCore

struct DoctorReport: Sendable {
    let state: MonitoringCheckState
    let checks: [MonitoringCheck]
    let text: String
}

/// Aggregated integration health check: bridge deployed? socket live?
/// Claude/Codex hook status, Codex version + trust reminder. Rendered as
/// plain monospaced text in the menu-bar alert and by `Perch --doctor`.
enum Doctor {
    static func report() -> String {
        diagnose().text
    }

    static func diagnose() -> DoctorReport {
        let runtime = socketCheck()
        let snapshot = MonitoringInspector.inspect(runtime: runtime)
        let checks = [snapshot.bridge, snapshot.socket, snapshot.claude, snapshot.codex]
        var lines: [String] = []
        lines.append("Perch Doctor — \(AppVersion.string) — \(timestamp())")
        lines.append("")
        lines.append(contentsOf: checks.map(render))
        lines.append(CodexHookInstaller.versionSupportNote())
        lines.append("Detection: every tool call relayed by the hooks above is risk-scored offline; "
            + "danger-level calls (rm -rf, sudo, curl|sh, credential access, agent hook/settings writes) raise an OS notification "
            + "and a notch card. Perch is observe-only — it never approves, denies, or blocks anything. "
            + "Active only while hooks are installed and the socket is live.")
        lines.append("")
        lines.append("Claude rate-limit gauges: populated only by the statusline payload, which "
            + "Claude Code renders in terminal sessions — the desktop app never invokes it. "
            + "Token usage totals come from transcripts and work for all session types.")
        lines.append(CodexHookTrust.doctorLine()
            + " If Codex hooks are installed but tool calls never surface, missing trust is why.")
        lines.append("Log: \(PerchPaths.logFile.path)")
        return DoctorReport(state: aggregateState(for: checks), checks: checks,
                            text: lines.joined(separator: "\n"))
    }

    /// Doctor is stricter than the compact monitoring badge: a mixed report
    /// must not render a green success header while one of its visible checks
    /// says that setup or repair is still required.
    static func aggregateState(for checks: [MonitoringCheck]) -> MonitoringCheckState {
        if checks.contains(where: { $0.state == .unavailable }) { return .unavailable }
        if checks.contains(where: { $0.state == .checking }) { return .checking }
        if checks.contains(where: { $0.state == .needsAttention }) { return .needsAttention }
        return .ready
    }

    // MARK: - Checks

    static func bridgeCheck() -> MonitoringCheck {
        let path = PerchPaths.bridgeInstallPath.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return MonitoringCheck(title: "Bridge", state: .unavailable,
                                   summary: "Bridge is not deployed",
                                   detail: "Expected at \(path); relaunch Perch.app to deploy it.")
        }
        guard fm.isExecutableFile(atPath: path) else {
            return MonitoringCheck(title: "Bridge", state: .unavailable,
                                   summary: "Bridge is not executable",
                                   detail: "Present at \(path); relaunch Perch.app to redeploy it.")
        }
        var details = [path]
        if let attrs = try? fm.attributesOfItem(atPath: path) {
            var parts: [String] = []
            if let size = (attrs[.size] as? NSNumber)?.doubleValue {
                parts.append(String(format: "%.0f KB", size / 1024))
            }
            if let mtime = attrs[.modificationDate] as? Date {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "yyyy-MM-dd HH:mm"
                parts.append("modified \(df.string(from: mtime))")
            }
            if !parts.isEmpty {
                details.append(parts.joined(separator: ", "))
            }
        }
        return MonitoringCheck(title: "Bridge", state: .ready,
                               summary: "Bridge deployed",
                               detail: details.joined(separator: " · "))
    }

    static func socketCheck() -> MonitoringCheck {
        let path = PerchPaths.socketPath
        guard FileManager.default.fileExists(atPath: path) else {
            return MonitoringCheck(title: "Runtime", state: .unavailable,
                                   summary: "Local event server is not running",
                                   detail: "No socket at \(path).")
        }
        if socketAcceptsConnection(path) {
            return MonitoringCheck(title: "Runtime", state: .ready,
                                   summary: "Local event server is listening",
                                   detail: path)
        }
        return MonitoringCheck(title: "Runtime", state: .unavailable,
                               summary: "Socket exists but no server is listening",
                               detail: path)
    }

    /// True when something accepts a connection on the unix socket. The
    /// server treats the immediately-closed probe connection as a malformed
    /// (empty) request and drops it — harmless.
    private static func socketAcceptsConnection(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path) - 1 // keep NUL terminator
        guard pathBytes.count <= capacity else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, size)
            }
        }
        return result == 0
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.string(from: Date())
    }

    private static func render(_ check: MonitoringCheck) -> String {
        let status: String
        switch check.state {
        case .checking: status = "CHECKING"
        case .ready: status = "OK"
        case .needsAttention: status = "NEEDS ATTENTION"
        case .unavailable: status = "UNAVAILABLE"
        }
        let detail = check.detail.map { " — \($0)" } ?? ""
        return "\(check.title): \(status) — \(check.summary)\(detail)"
    }
}
