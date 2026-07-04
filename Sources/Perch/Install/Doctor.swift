import Foundation
import PerchCore

/// Aggregated integration health check: bridge deployed? socket live?
/// Claude/Codex hook status, Codex version + trust reminder. Rendered as
/// plain monospaced text in the menu-bar alert and by `Perch --doctor`.
enum Doctor {
    static func report() -> String {
        var lines: [String] = []
        lines.append("Perch Doctor — \(AppVersion.string) — \(timestamp())")
        lines.append("")
        lines.append(bridgeLine())
        lines.append(socketLine())
        lines.append(ClaudeHookInstaller.status())
        lines.append(CodexHookInstaller.status())
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
        return lines.joined(separator: "\n")
    }

    // MARK: - Checks

    private static func bridgeLine() -> String {
        let path = PerchPaths.bridgeInstallPath.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return "Bridge: NOT DEPLOYED — expected at \(path); launch Perch.app once to deploy."
        }
        guard fm.isExecutableFile(atPath: path) else {
            return "Bridge: present at \(path) but NOT EXECUTABLE — relaunch Perch.app to redeploy."
        }
        var detail = ""
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
                detail = " (\(parts.joined(separator: ", ")))"
            }
        }
        return "Bridge: OK at \(path)\(detail)"
    }

    private static func socketLine() -> String {
        let path = PerchPaths.socketPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "Socket: no socket at \(path) — Perch's server has not started."
        }
        return socketAcceptsConnection(path)
            ? "Socket: live at \(path)"
            : "Socket: file exists at \(path) but nothing is listening — is Perch running?"
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
}
