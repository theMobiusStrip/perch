import Darwin
import Foundation
import PerchCore

/// Reusable incremental line reader shared by the transcript tailers.
///
/// Remembers a byte offset (and inode) per file path and, on each call to
/// `readNewLines`, returns only the complete ('\n'-terminated) lines appended
/// since the previous call. Handles:
///  - truncation: stored offset > current size → reset to 0 and re-read;
///  - file replacement: inode change → reset to 0 and re-read;
///  - partial trailing line: bytes after the last newline are left unconsumed
///    until the terminating newline lands.
///
/// NOT thread-safe by design — confine each instance to a single dispatch
/// queue (each tailer owns one).
final class FileTailer {

    private struct State {
        var offset: UInt64
        /// nil = unknown (seeded without opening); adopted on first real read.
        var inode: UInt64?
    }

    private var states: [String: State] = [:]

    /// Paths currently tracked.
    var trackedPaths: [String] { Array(states.keys) }

    func isTracking(_ path: String) -> Bool {
        states[path] != nil
    }

    /// Adopt a file at an explicit byte offset without opening it
    /// (cheap seeding from directory-enumeration attributes).
    func seed(path: String, offset: UInt64) {
        states[path] = State(offset: offset, inode: nil)
    }

    /// Adopt a file with its offset at the current end (skip existing content).
    func seedAtEnd(path: String) {
        var st = stat()
        if stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0 {
            states[path] = State(offset: UInt64(st.st_size), inode: UInt64(st.st_ino))
        } else {
            states[path] = State(offset: 0, inode: nil)
        }
    }

    func forget(path: String) {
        states.removeValue(forKey: path)
    }

    func offset(for path: String) -> UInt64? {
        states[path]?.offset
    }

    /// Read every complete new line since the last call. First call for an
    /// unseeded path reads from the start of the file. Errors (missing file,
    /// permission) are tolerated and yield [].
    func readNewLines(path: String, maxBytes: Int = 16 * 1024 * 1024) -> [String] {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0 else {
            return []
        }
        let size = UInt64(st.st_size)
        let inode = UInt64(st.st_ino)

        var state = states[path] ?? State(offset: 0, inode: nil)
        if let known = state.inode, known != inode {
            // File was replaced (atomic rename etc.) — start over.
            state = State(offset: 0, inode: inode)
        }
        state.inode = inode
        if state.offset > size {
            // Truncated — start over.
            state.offset = 0
        }
        guard size > state.offset else {
            states[path] = state
            return []
        }

        var skippedAhead = false
        var delta = size - state.offset
        if delta > UInt64(maxBytes) {
            // Huge backlog: jump near the end and drop the first (partial) line.
            state.offset = size - UInt64(maxBytes)
            delta = UInt64(maxBytes)
            skippedAhead = true
            PerchLog.warn("Tail backlog exceeds \(maxBytes) bytes for \((path as NSString).lastPathComponent); skipping ahead",
                          category: "tail")
        }

        var data = Data(capacity: Int(delta))
        var readOffset = state.offset
        var remaining = Int(delta)
        let chunkSize = 1 << 20
        var buf = [UInt8](repeating: 0, count: min(chunkSize, remaining))
        while remaining > 0 {
            let want = min(buf.count, remaining)
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                pread(fd, raw.baseAddress, want, off_t(readOffset))
            }
            guard n > 0 else { break }
            data.append(contentsOf: buf[0..<n])
            readOffset += UInt64(n)
            remaining -= n
        }

        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            // No complete line yet — leave offset so the partial tail is
            // re-read once its newline arrives.
            states[path] = state
            return []
        }
        let consumed = data.prefix(through: lastNewline)
        state.offset += UInt64(consumed.count)
        states[path] = state

        let text = String(decoding: consumed, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if skippedAhead, !lines.isEmpty {
            lines.removeFirst() // fragment of a line we jumped into
        }
        return lines
    }
}
