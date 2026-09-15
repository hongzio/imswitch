import Dispatch
import Foundation

enum SocketPath {
    static var directory: String {
        NSHomeDirectory() + "/.local/state/imswitch"
    }

    static var `default`: String {
        directory + "/imswitch.sock"
    }
}

enum SocketError: Error, CustomStringConvertible {
    case pathTooLong(String, Int)
    case syscall(String, Int32)
    case unsafeStateDirectory(String, String)
    case alreadyRunning(String)

    var description: String {
        switch self {
        case let .pathTooLong(path, limit):
            return "socket path is \(path.utf8.count) bytes, limit is \(limit - 1): \(path)"
        case let .syscall(name, err):
            return "\(name) failed: \(String(cString: strerror(err))) (errno \(err))"
        case let .unsafeStateDirectory(path, why):
            return "refusing to use state directory \(path): \(why)"
        case let .alreadyRunning(path):
            return "another imswitch daemon is already listening on \(path)"
        }
    }
}

/// Path stashed for the termination handlers. A C signal handler may only touch
/// async-signal-safe things, so we keep a plain C string around and do nothing
/// in there but `unlink` and `_exit`.
private var gSocketPathForSignal: UnsafeMutablePointer<CChar>?

private func installTerminationHandlers(path: String) {
    gSocketPathForSignal = strdup(path)
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig) { received in
            if let p = gSocketPathForSignal { unlink(p) }
            _exit(128 &+ received)
        }
    }
}

/// Newline-delimited text over AF_UNIX. One request, one response, then the
/// connection is done — `nc -U` is a complete client.
final class SocketServer {
    typealias Handler = (String) -> String

    private let path: String
    /// Invoked on the main queue; TIS wants the main thread.
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "com.hongzio.imswitch.accept")
    private let connectionQueue = DispatchQueue(
        label: "com.hongzio.imswitch.connection", attributes: .concurrent)
    /// Bounds how many connections can be in flight. Without it, anything that
    /// can reach the socket — including whatever shares a host at the far end of
    /// an ssh RemoteForward — can open connections faster than they retire and
    /// starve every real request until it stops.
    private static let maxConcurrentConnections = 16
    private let connectionSlots = DispatchSemaphore(value: maxConcurrentConnections)
    /// Wall-clock budget for one request. SO_RCVTIMEO is a *per-read* timeout
    /// that every byte resets, so a client dripping one byte at a time could
    /// otherwise hold a slot for hours. A real client — local or across an ssh
    /// tunnel — sends its whole line in one write, so this only ever bites
    /// misbehaving ones, and keeping it short is what makes slots turn over
    /// during a flood.
    private static let connectionDeadline: TimeInterval = 2

    init(path: String = SocketPath.default, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// `createDirectory(attributes:)` applies the mode only to directories it
    /// actually creates, so a pre-existing one — restored from a backup, synced,
    /// or planted — can be group- or world-writable. Anyone who can write there
    /// can unlink our 0600 socket and bind their own in its place, which makes
    /// the socket's own mode irrelevant.
    private func prepareStateDirectory() throws {
        let dir = SocketPath.directory
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        var info = stat()
        guard lstat(dir, &info) == 0 else { throw SocketError.syscall("lstat", errno) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw SocketError.unsafeStateDirectory(dir, "not a directory")
        }
        guard info.st_uid == getuid() else {
            throw SocketError.unsafeStateDirectory(dir, "owned by uid \(info.st_uid), not \(getuid())")
        }
        if (info.st_mode & (S_IWGRP | S_IWOTH)) != 0 {
            // Tighten rather than refuse — this is usually an old directory, not
            // an attack — but verify the tightening took.
            chmod(dir, 0o700)
            guard lstat(dir, &info) == 0 else { throw SocketError.syscall("lstat", errno) }
            guard (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
                throw SocketError.unsafeStateDirectory(dir, "writable by group or other")
            }
            log("tightened permissions on \(dir) to 0700")
        }
    }

    /// A live daemon answers a connect(); only a stale entry left by SIGKILL or
    /// a panic does not. Unlinking unconditionally would steal the socket from a
    /// healthy instance and leave it running with no way in.
    private func isPathServedByLiveDaemon(_ path: String) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }

        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { return false }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(probe, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    func start() throws {
        try prepareStateDirectory()

        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path, capacity) }

        if isPathServedByLiveDaemon(path) { throw SocketError.alreadyRunning(path) }
        // Whatever a SIGKILL or a panic left behind.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }
        // Non-blocking: the accept loop drains until EAGAIN, and a blocking
        // accept would park the accept queue forever.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }

        // bind() honours the umask, and chmod after bind races a fast client.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw SocketError.syscall("bind", err)
        }

        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw SocketError.syscall("listen", err)
        }

        listenFD = fd
        installTerminationHandlers(path: path)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // EAGAIN/EWOULDBLOCK: drained.
            }
            // Over capacity: hang up now rather than queueing work that would
            // sit behind a flood. Legitimate clients retry on the next event.
            guard connectionSlots.wait(timeout: .now()) == .success else {
                close(client)
                continue
            }
            let slots = connectionSlots
            connectionQueue.async { [weak self] in
                defer { slots.signal() }
                guard let self else {
                    close(client)
                    return
                }
                self.serve(client)
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }

        // BSD hands the accepted socket back with the listener's flags; clear
        // them so the receive/send timeouts below actually apply.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK)

        // A wedged client must never wedge the daemon.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let request = readLine(fd, deadline: Date().addingTimeInterval(Self.connectionDeadline))
        else { return }
        let response = DispatchQueue.main.sync { handler(request) }
        writeAll(fd, response + "\n")
    }

    private func readLine(_ fd: Int32, limit: Int = 4096, deadline: Date) -> String? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        while buffer.count < limit {
            // The socket timeout is per-read and every byte resets it; this is
            // what actually bounds a drip-feeding client.
            if Date() >= deadline { return nil }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }  // EOF: take whatever arrived.
            if let newline = chunk[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(contentsOf: chunk[0..<newline])
                break
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func writeAll(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            // SIGPIPE is ignored process-wide, so a client that already hung up
            // surfaces here as EPIPE instead of killing us.
            let n = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            offset += n
        }
        return true
    }
}
