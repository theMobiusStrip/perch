import Darwin
import Dispatch
import Foundation
import PerchCore

/// Unix-domain SOCK_STREAM server the bridge CLI talks to. One connection per
/// bridge invocation:
///
/// 1. Bridge sends one `BridgeEnvelope` JSON line, then half-closes its write
///    side (`shutdown(SHUT_WR)`).
/// 2. We read the line, invoke `handler`. The handler calls the reply callback
///    exactly once, eventually; we then write one `BridgeReply` JSON line and
///    close. Handlers reply immediately (observe-only, no parked
///    decisions); if one hasn't after 30s we fail open with
///    `BridgeReply.empty`.
/// 3. Read cap 10 MB per line; oversize/malformed → log, reply empty, close.
///
/// The reply callback is safe to call from any thread and idempotent (second
/// call is a no-op). All socket work runs on a private serial queue.
final class UnixSocketServer {
    typealias Handler = @Sendable (BridgeEnvelope, @escaping @Sendable (BridgeReply) -> Void) -> Void

    static let maxLineBytes = 10 * 1024 * 1024
    static let replyGuardSeconds: TimeInterval = 30

    private struct SocketError: Error, CustomStringConvertible {
        let description: String
    }

    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.evan.perch.socket-server")

    // Mutated on `queue` only (start() uses queue.sync to publish).
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]
    private var running = false

    init(socketPath: String = PerchPaths.socketPath, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    // MARK: - Lifecycle

    func start() throws {
        var alreadyRunning = false
        queue.sync { alreadyRunning = running }
        if alreadyRunning { return }

        if socketPath == PerchPaths.socketPath {
            try PerchPaths.ensureAppSupportDir()
        } else {
            let dir = (socketPath as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError(description: "socket() failed: \(Self.errnoString())")
        }
        var cleanupFD = true
        defer { if cleanupFD { close(fd) } }

        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path) - 1 // keep NUL terminator
        guard pathBytes.count <= capacity else {
            throw SocketError(description: "socket path too long (\(pathBytes.count) > \(capacity)): \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        // Unlink a stale socket from a previous run; ENOENT is fine.
        unlink(socketPath)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw SocketError(description: "bind(\(socketPath)) failed: \(Self.errnoString())")
        }

        if chmod(socketPath, 0o600) != 0 {
            PerchLog.warn("chmod 0600 on socket failed: \(Self.errnoString())", category: "socket")
        }

        guard Darwin.listen(fd, 16) == 0 else {
            let message = "listen() failed: \(Self.errnoString())"
            unlink(socketPath)
            throw SocketError(description: message)
        }

        Self.setNonBlocking(fd)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let path = socketPath
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.setCancelHandler {
            close(fd)
            unlink(path)
        }

        cleanupFD = false
        queue.sync {
            listenFD = fd
            acceptSource = source
            running = true
        }
        source.resume()
        PerchLog.info("listening on \(socketPath)", category: "socket")
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            listenFD = -1
            acceptSource?.cancel() // cancel handler closes the fd and unlinks the path
            acceptSource = nil
            // Fail every in-flight connection open; each writes an empty
            // reply, closes, and removes itself from the registry.
            for connection in connections.values {
                connection.failOpen()
            }
            PerchLog.info("stopped", category: "socket")
        }
    }

    // MARK: - Accept loop (on queue)

    private func acceptPending() {
        while running, listenFD >= 0 {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK { return }
                if err == EINTR { continue }
                PerchLog.warn("accept() failed: \(Self.errnoString(err))", category: "socket")
                return
            }

            _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
            var yes: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            Self.setNonBlocking(clientFD)

            let connection = BridgeConnection(fd: clientFD, queue: queue, handler: handler) { [weak self] finished in
                // Runs on `queue`.
                self?.connections.removeValue(forKey: ObjectIdentifier(finished))
            }
            connections[ObjectIdentifier(connection)] = connection
            connection.begin()
        }
    }

    // MARK: - Helpers

    fileprivate static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    fileprivate static func errnoString(_ err: Int32 = errno) -> String {
        "\(String(cString: strerror(err))) (errno \(err))"
    }
}

// MARK: - Per-connection state machine

/// One accepted bridge connection. All state is mutated on the server's serial
/// queue; `submitReply` is the only entry point callable from any thread (it
/// is idempotent and hops to the queue).
///
/// fd lifetime rule: the read dispatch source must be fully cancelled (its
/// cancel handler run) before the fd is closed. `tryComplete` therefore only
/// proceeds once `sourceRetired` is set by the cancel handler.
private final class BridgeConnection {
    private let fd: Int32
    private let queue: DispatchQueue
    private let handler: UnixSocketServer.Handler
    private let onFinish: (BridgeConnection) -> Void

    // On-queue state.
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var lineHandled = false
    private var sourceRetired = false
    private var pendingReply: BridgeReply?
    private var closed = false

    // Any-thread idempotence guard for the reply callback.
    private let replyLock = NSLock()
    private var replyFired = false

    init(fd: Int32,
         queue: DispatchQueue,
         handler: @escaping UnixSocketServer.Handler,
         onFinish: @escaping (BridgeConnection) -> Void) {
        self.fd = fd
        self.queue = queue
        self.handler = handler
        self.onFinish = onFinish
    }

    /// Called on `queue` right after registration.
    func begin() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [weak self] in
            self?.sourceRetired = true
            self?.tryComplete()
        }
        readSource = source
        source.resume()

        // Absolute fail-open guard: if no reply has fired 30s after accept,
        // send an empty reply and close (the bridge itself gives up at 5s).
        queue.asyncAfter(deadline: .now() + UnixSocketServer.replyGuardSeconds) { [weak self] in
            guard let self, !self.closed else { return }
            if self.submitReply(.empty) {
                PerchLog.warn("reply guard (\(Int(UnixSocketServer.replyGuardSeconds))s) fired — failing open", category: "socket")
            }
        }
    }

    /// Fail the connection open (empty reply). Safe from any thread.
    func failOpen() {
        _ = submitReply(.empty)
    }

    // MARK: Reading (on queue)

    private func readAvailable() {
        guard !lineHandled else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > UnixSocketServer.maxLineBytes {
                    PerchLog.warn("oversize envelope (\(buffer.count) bytes) — replying empty", category: "socket")
                    handleLine(nil)
                    return
                }
                if let newline = buffer.firstIndex(of: 0x0A) {
                    handleLine(Data(buffer[buffer.startIndex..<newline]))
                    return
                }
                continue
            }
            if n == 0 {
                // EOF (bridge half-closed). Tolerate a missing trailing newline.
                if buffer.isEmpty {
                    PerchLog.warn("connection closed without payload", category: "socket")
                    handleLine(nil)
                } else {
                    handleLine(buffer)
                }
                return
            }
            let err = errno
            if err == EINTR { continue }
            if err == EAGAIN || err == EWOULDBLOCK { return }
            PerchLog.warn("read() failed: \(UnixSocketServer.errnoString(err))", category: "socket")
            handleLine(nil)
            return
        }
    }

    /// On queue. `data` is the raw envelope line (without newline) or nil for
    /// EOF-without-data / oversize / read-error cases.
    private func handleLine(_ data: Data?) {
        guard !lineHandled else { return }
        lineHandled = true
        buffer = Data()
        // Done reading; retire the source (its cancel handler unblocks the
        // eventual write+close). Also prevents EOF-spin while we wait for the
        // handler's reply.
        readSource?.cancel()

        guard let data else {
            _ = submitReply(.empty)
            return
        }
        guard let envelope = BridgeFraming.decodeLine(BridgeEnvelope.self, from: data) else {
            PerchLog.warn("malformed envelope (\(data.count) bytes) — replying empty", category: "socket")
            _ = submitReply(.empty)
            return
        }

        let reply: @Sendable (BridgeReply) -> Void = { [weak self] value in
            _ = self?.submitReply(value)
        }
        handler(envelope, reply)
    }

    // MARK: Replying (any thread)

    /// Idempotent: returns true only for the call that won.
    @discardableResult
    private func submitReply(_ reply: BridgeReply) -> Bool {
        replyLock.lock()
        let alreadyFired = replyFired
        replyFired = true
        replyLock.unlock()
        guard !alreadyFired else { return false }

        queue.async { [self] in
            pendingReply = reply
            if let source = readSource, !sourceRetired {
                source.cancel() // e.g. fail-open before any line arrived
            }
            tryComplete()
        }
        return true
    }

    /// On queue. Completes once both the reply is pending and the read source
    /// has fully retired (safe to close the fd).
    private func tryComplete() {
        guard !closed, sourceRetired, let reply = pendingReply else { return }
        closed = true
        readSource = nil

        if let line = try? BridgeFraming.encodeLine(reply) {
            writeAll(line)
        } else {
            PerchLog.error("failed to encode BridgeReply", category: "socket")
        }
        close(fd)
        onFinish(self)
    }

    /// On queue. Best-effort full write of the reply line to the nonblocking
    /// fd, bounded at 5s (replies are tiny; this never blocks in practice).
    private func writeAll(_ data: Data) {
        let deadline = Date().addingTimeInterval(5)
        var offset = 0
        let count = data.count
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < count {
                let n = write(fd, base + offset, count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n == 0 { return }
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK {
                    if Date() >= deadline {
                        PerchLog.warn("reply write timed out", category: "socket")
                        return
                    }
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 100)
                    continue
                }
                PerchLog.warn("reply write failed: \(UnixSocketServer.errnoString(err))", category: "socket")
                return
            }
        }
    }
}
