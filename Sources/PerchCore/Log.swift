import Foundation
import os

/// File-backed logger shared by the app and the bridge. The bridge must keep
/// stdout pristine (Claude/Codex parse it), so diagnostics go here and to
/// os_log only.
public enum PerchLog {
    private static let osLog = Logger(subsystem: "dev.evan.perch", category: "perch")
    private static let queue = DispatchQueue(label: "dev.evan.perch.log")
    private static let maxLogBytes: UInt64 = 5 * 1024 * 1024

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func info(_ message: String, category: String = "app") {
        osLog.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        append(level: "INFO", category: category, message: message)
    }

    public static func warn(_ message: String, category: String = "app") {
        osLog.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        append(level: "WARN", category: category, message: message)
    }

    public static func error(_ message: String, category: String = "app") {
        osLog.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        append(level: "ERROR", category: category, message: message)
    }

    /// Drain pending writes. Short-lived processes (the bridge) must call this
    /// before exit(), or queued lines die with the process.
    public static func flush() {
        queue.sync {}
    }

    private static func append(level: String, category: String, message: String) {
        let line = "\(timestampFormatter.string(from: Date())) \(level) [\(category)] \(message)\n"
        queue.async {
            do {
                try PerchPaths.ensureAppSupportDir()
                let url = PerchPaths.logFile
                rotateIfNeeded(url)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil,
                                                   attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                // Logging must never take anything down with it.
            }
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > maxLogBytes else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
