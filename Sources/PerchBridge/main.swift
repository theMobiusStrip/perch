import Darwin
import Dispatch
import Foundation
import PerchCore

// perch-bridge — invoked by Claude Code / Codex hooks and the Claude
// statusline. Reliability contract:
//
//   * NEVER exit nonzero on a Perch-side failure (exit 2 means DENY to
//     Claude Code — forbidden as a failure mode).
//   * NEVER print anything to stdout except the intended reply/statusline
//     text (Claude/Codex parse stdout; garbage corrupts decisions).
//   * Any error → log via PerchLog, print nothing, exit 0 (fail-open: the
//     agent falls through to its normal terminal prompt).
//
// Plain BSD sockets + poll(); no AppKit, no Network.framework.

private enum BridgeMode {
    case hook(AgentKind)
    case statusline
}

private let replyLineCapBytes = 10 * 1024 * 1024

/// PerchLog writes on an async queue; exit() without draining it loses the
/// lines. Every bridge exit goes through here.
private func exitBridge(_ code: Int32 = 0) -> Never {
    PerchLog.flush()
    exit(code)
}

private func runBridge() -> Never {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let mode = parseMode(args) else {
        PerchLog.warn("unrecognized arguments: \(args.joined(separator: " ")) — exiting silently", category: "bridge")
        exitBridge()
    }

    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = try? JSONValue(parsing: stdinData) else {
        PerchLog.warn("malformed stdin payload (\(stdinData.count) bytes) — exiting silently", category: "bridge")
        exitBridge()
    }

    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    switch mode {
    case .hook(let agent):
        runHook(agent: agent, payload: payload, nowMs: nowMs)
    case .statusline:
        runStatusline(payload: payload, rawPayload: stdinData, nowMs: nowMs)
    }
}

private func parseMode(_ args: [String]) -> BridgeMode? {
    var mode: BridgeMode?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--statusline":
            mode = .statusline
        case "--hook":
            guard i + 1 < args.count, let agent = AgentKind(rawValue: args[i + 1]) else { return nil }
            mode = .hook(agent)
            i += 1
        default:
            break // ignore unknown flags (forward compatibility)
        }
        i += 1
    }
    return mode
}

// MARK: - Hook mode

private func runHook(agent: AgentKind, payload: JSONValue, nowMs: Int64) -> Never {
    let envelope = BridgeEnvelope(kind: .hook, agent: agent, receivedAtMs: nowMs, payload: payload)

    // Observe-only: every event is fire-and-forget with a short ack window.
    // Perch never writes a decision back, so no hook — PermissionRequest
    // included — ever holds the agent hostage; the terminal prompt appears
    // exactly as it would without Perch.
    if let reply = forwardToSocket(envelope: envelope, replyTimeout: 5),
       let stdout = reply.stdout {
        try? FileHandle.standardOutput.write(contentsOf: Data((stdout.encodedString() + "\n").utf8))
    }
    // nil reply / timeout / EOF / garbage → print nothing. Always exit 0.
    exitBridge()
}

// MARK: - Statusline mode

private func runStatusline(payload: JSONValue, rawPayload: Data, nowMs: Int64) -> Never {
    // Socket forward is fire-and-forget best effort, in parallel with the
    // chained/fallback output below.
    let envelope = BridgeEnvelope(kind: .statusline, agent: .claude, receivedAtMs: nowMs, payload: payload)
    let forwardDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        _ = forwardToSocket(envelope: envelope, replyTimeout: 1)
        forwardDone.signal()
    }

    let config = PerchConfig.load()
    var printed = false
    if let command = config.originalClaudeStatusline?["command"]?.string, !command.isEmpty {
        if let output = runChainedStatusline(command: command, stdinData: rawPayload), !output.isEmpty {
            try? FileHandle.standardOutput.write(contentsOf: output) // verbatim
            printed = true
        }
    }
    if !printed {
        let line = fallbackStatusLine(payload: payload)
        if !line.isEmpty {
            try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    _ = forwardDone.wait(timeout: .now() + 2)
    exitBridge()
}

/// Runs the user's original statusline command via `/bin/sh -c`, piping the
/// payload to its stdin. 4s timeout, then SIGTERM/SIGKILL. nil on failure.
private func runChainedStatusline(command: String, stdinData: Data) -> Data? {
    final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ newValue: Data) { lock.lock(); data = newValue; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let inPipe = Pipe()
    let outPipe = Pipe()
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        PerchLog.warn("chained statusline failed to launch: \(error)", category: "bridge")
        return nil
    }

    DispatchQueue.global(qos: .userInitiated).async {
        try? inPipe.fileHandleForWriting.write(contentsOf: stdinData)
        try? inPipe.fileHandleForWriting.close()
    }

    let box = OutputBox()
    let readDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        box.set(outPipe.fileHandleForReading.readDataToEndOfFile())
        readDone.signal()
    }

    if readDone.wait(timeout: .now() + 4) == .timedOut {
        PerchLog.warn("chained statusline timed out after 4s — terminating", category: "bridge")
        process.terminate()
        if readDone.wait(timeout: .now() + 0.5) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = readDone.wait(timeout: .now() + 0.5)
        }
        return nil
    }
    return box.get()
}

/// Compact fallback: `{model.display_name} · ctx {pct}%` (+ ` · 5h {pct}%`).
private func fallbackStatusLine(payload: JSONValue) -> String {
    var parts: [String] = []
    if let model = payload["model"]?.first(of: ["display_name", "id"])?.string {
        parts.append(model)
    }
    if let ctx = payload["context_window"]?["used_percentage"]?.double {
        parts.append("ctx \(Int(ctx.rounded()))%")
    }
    if let fiveHour = payload["rate_limits"]?["five_hour"]?["used_percentage"]?.double {
        parts.append("5h \(Int(fiveHour.rounded()))%")
    }
    return parts.joined(separator: " · ")
}

// MARK: - Socket plumbing (BSD sockets + poll)

/// Connects to the Perch socket, sends the envelope line, half-closes the
/// write side, and waits for one reply line. The entire transaction
/// (connect + write + read) shares a single `replyTimeout` deadline so the
/// bridge can never outlive its contract timeout blocked in connect/write.
/// Returns nil on ANY failure — callers treat nil as "print nothing, exit 0".
private func forwardToSocket(envelope: BridgeEnvelope, replyTimeout: TimeInterval) -> BridgeReply? {
    guard let line = try? BridgeFraming.encodeLine(envelope) else {
        PerchLog.warn("failed to encode envelope", category: "bridge")
        return nil
    }

    let deadline = Date().addingTimeInterval(replyTimeout)
    let path = PerchPaths.socketPath
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var yes: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path) - 1 // keep NUL terminator
    guard pathBytes.count <= capacity else {
        PerchLog.warn("socket path too long (\(pathBytes.count) > \(capacity)): \(path)", category: "bridge")
        return nil
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let connected = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    // App not running → ENOENT/ECONNREFUSED, ~instant. Silent fail-open.
    if connected != 0 {
        // Nonblocking connect in flight → wait for the result with the same
        // poll() deadline as the rest of the transaction, then check SO_ERROR.
        guard errno == EINPROGRESS || errno == EINTR else { return nil }
        guard pollUntilReady(fd: fd, events: POLLOUT, deadline: deadline) else { return nil }
        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen) == 0, soError == 0 else {
            return nil
        }
    }

    guard writeFully(fd: fd, data: line, deadline: deadline) else { return nil }
    shutdown(fd, SHUT_WR)

    guard let replyLine = readReplyLine(fd: fd, deadline: deadline) else { return nil }
    return BridgeFraming.decodeLine(BridgeReply.self, from: replyLine)
}

/// Polls `fd` for `events` until `deadline`. True when ready; false on
/// deadline expiry or poll error (EINTR retried).
private func pollUntilReady(fd: Int32, events: Int32, deadline: Date) -> Bool {
    while true {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return false }

        var pfd = pollfd(fd: fd, events: Int16(events), revents: 0)
        let waitMs = Int32(max(1, min(remaining * 1000, 60_000)))
        let pollResult = poll(&pfd, 1, waitMs)
        if pollResult < 0 {
            if errno == EINTR { continue }
            return false
        }
        if pollResult == 0 { continue } // slice elapsed; deadline re-checked above
        return true
    }
}

/// Full write on a nonblocking fd, waiting for writability with a poll()
/// deadline; false on deadline expiry or any unrecoverable error.
private func writeFully(fd: Int32, data: Data, deadline: Date) -> Bool {
    let count = data.count
    if count == 0 { return true }
    var offset = 0
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard let base = raw.baseAddress else { return false }
        while offset < count {
            let n = write(fd, base + offset, count - offset)
            if n > 0 {
                offset += n
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                guard pollUntilReady(fd: fd, events: POLLOUT, deadline: deadline) else { return false }
                continue
            }
            return false
        }
        return true
    }
}

/// Reads one newline-terminated line with a poll() deadline. Returns the line
/// without its newline, the remaining buffer on clean EOF, or nil on
/// timeout/error/oversize.
private func readReplyLine(fd: Int32, deadline: Date) -> Data? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)

    while true {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let waitMs = Int32(max(1, min(remaining * 1000, 60_000)))
        let pollResult = poll(&pfd, 1, waitMs)
        if pollResult < 0 {
            if errno == EINTR { continue }
            return nil
        }
        if pollResult == 0 { continue } // slice elapsed; deadline re-checked above

        let n = read(fd, &chunk, chunk.count)
        if n > 0 {
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > replyLineCapBytes { return nil }
            if let newline = buffer.firstIndex(of: 0x0A) {
                return Data(buffer[buffer.startIndex..<newline])
            }
            continue
        }
        if n == 0 {
            // EOF: tolerate a reply without trailing newline.
            return buffer.isEmpty ? nil : buffer
        }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { continue } // spurious poll wakeup on nonblocking fd
        return nil
    }
}

// MARK: - Entry point (top-level code, last so nothing follows the Never call)

_ = signal(SIGPIPE, SIG_IGN)
runBridge()
