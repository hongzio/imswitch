import Foundation

/// The non-`serve` verbs: connect, send one line, print the reply.
enum Client {
    /// Exit status: 0 when the daemon answered `ok`/`pong`, 1 otherwise.
    static func run(_ command: String, path: String = SocketPath.default) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            FileHandle.standardError.write(Data("imswitch: socket: \(String(cString: strerror(errno)))\n".utf8))
            return 1
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else {
            FileHandle.standardError.write(Data("imswitch: socket path too long: \(path)\n".utf8))
            return 1
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
            FileHandle.standardError.write(Data((
                "imswitch: cannot reach the daemon at \(path) (\(why))\n"
                + "imswitch: is it running?  brew services start imswitch\n").utf8))
            return 1
        }

        let request = Array((command + "\n").utf8)
        var offset = 0
        while offset < request.count {
            let n = request.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), request.count - offset)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                FileHandle.standardError.write(Data("imswitch: write failed\n".utf8))
                return 1
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

        let text = String(decoding: reply, as: UTF8.self)
        print(text)
        return (text == "pong" || text.hasPrefix("ok")) ? 0 : 1
    }
}
