import Foundation

/// The non-`serve` verbs: connect, send one line, print the reply.
enum Client {
    /// Exit status: 0 when the daemon answered `ok`/`pong`, 1 otherwise.
    static func run(_ command: String, path: String = SocketPath.default) -> Int32 {
        guard let reply = send(command, path: path, quiet: false) else { return 1 }
        print(reply)
        return (reply == "pong" || reply.hasPrefix("ok")) ? 0 : 1
    }

    /// One line in, one line out; nil when the daemon could not be reached.
    ///
    /// `quiet` is for callers that own the user's terminal. `imswitch remote`
    /// proxies a pty, so a diagnostic on stderr would land in the middle of
    /// whatever the user is looking at.
    @discardableResult
    static func send(
        _ command: String, path: String = SocketPath.default, quiet: Bool = true
    ) -> String? {
        func complain(_ message: String) {
            guard !quiet else { return }
            FileHandle.standardError.write(Data(message.utf8))
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            complain("imswitch: socket: \(String(cString: strerror(errno)))\n")
            return nil
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else {
            complain("imswitch: socket path too long: \(path)\n")
            return nil
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let why = String(cString: strerror(errno))
            complain(
                "imswitch: cannot reach the daemon at \(path) (\(why))\n"
                    + "imswitch: is it running?  brew services start imswitch\n")
            return nil
        }

        let request = Array((command + "\n").utf8)
        var offset = 0
        while offset < request.count {
            let n = request.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), request.count - offset)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                complain("imswitch: write failed\n")
                return nil
            }
            offset += n
        }

        // Bounded for the same reason the daemon bounds the request: whatever is
        // on the other end of this path may not be the daemon.
        let replyLimit = 4096
        var reply = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        while reply.count < replyLimit {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            if let newline = chunk[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                reply.append(contentsOf: chunk[0..<newline])
                break
            }
            reply.append(contentsOf: chunk[0..<n])
        }

        return String(decoding: reply, as: UTF8.self)
    }
}
