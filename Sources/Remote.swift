import Dispatch
import Foundation

/// `imswitch remote -- <command>` runs <command> inside a pty and copies bytes
/// between it and the real terminal, watching the upstream direction for one
/// escape sequence.
///
/// That sequence is how a Neovim with no route back to the Mac — inside a
/// container, behind tailcat, three ssh hops away — asks for a switch: it
/// writes the bytes to its own terminal and they ride the stream that is
/// already there. Nothing is tunnelled, nothing listens, and nothing is
/// installed in the environment. It is the same mechanism Neovim's own OSC 52
/// clipboard uses to reach the Mac from a remote host.
///
/// Nothing in here may write to stdout or stderr once the proxy is running:
/// both are the user's terminal, and a stray log line would land in the middle
/// of their editor.
enum Remote {
    static func run(_ command: [String]) -> Never {
        guard let program = command.first else {
            FileHandle.standardError.write(Data("imswitch: remote needs a command to run\n".utf8))
            exit(2)
        }

        // A pipeline or a script has no terminal to proxy, and wrapping one in
        // a pty would change what the child sees. Run it unchanged; the switch
        // channel is simply absent, which is what every other imswitch path
        // does when it has nothing to talk to.
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            exit(spawnAndWait(command, fileActions: nil, attributes: nil))
        }

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
            let name = ptsname(master)
        else {
            FileHandle.standardError.write(Data("imswitch: cannot allocate a pty\n".utf8))
            exit(1)
        }
        let slavePath = String(cString: name)
        // The child must not inherit the master: it would keep the pty open
        // after the child exits and the read loop would never see EOF.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        // Hold the slave open across the spawn. Two reasons, and the first is
        // not obvious: on macOS TIOCSWINSZ against the master fails with -1
        // until some process has opened the slave, so the size below would be
        // silently dropped and the child would start at 0x0 — full-screen
        // programs draw themselves into nothing until the first resize.
        // O_NOCTTY because this process must not adopt the pty as its own
        // controlling terminal; the child does that, by path, in a new session.
        let slave = open(slavePath, O_RDWR | O_NOCTTY)

        // Start the child at the terminal's current size.
        var size = winsize()
        if ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &size) == 0 {
            _ = ioctl(master, UInt(TIOCSWINSZ), &size)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opening the slave *by path* in the child is what acquires the
        // controlling terminal: POSIX_SPAWN_SETSID has already made the child a
        // session leader by this point, and a session leader that opens a
        // terminal without O_NOCTTY takes it as its ctty. A dup2 of an
        // inherited fd would not — the child would have a tty on its fds but no
        // ctty, and ^C, ^Z and /dev/tty would all be dead.
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var pid: pid_t = 0
        let spawned = spawn(command, &pid, &actions, &attributes)
        // The second reason: a slave fd left open here would keep the pty alive
        // after the child exits, and the read loop would wait for an EOF that
        // never comes.
        if slave >= 0 { close(slave) }
        guard spawned == 0 else {
            // Still safe to talk: raw mode is not on yet.
            let why = String(cString: strerror(spawned))
            FileHandle.standardError.write(Data("imswitch: cannot run \(program): \(why)\n".utf8))
            exit(127)
        }

        enterRawMode()
        installHandlers()
        let status = proxy(master: master, pid: pid)
        restoreTerminal()
        exit(status)
    }

    // MARK: - The loop

    private static func proxy(master: Int32, pid: pid_t) -> Int32 {
        var scanner = SequenceScanner()
        let requester = SwitchRequester()

        var winchFDs: [Int32] = [-1, -1]
        if pipe(&winchFDs) == 0 {
            _ = fcntl(winchFDs[0], F_SETFL, fcntl(winchFDs[0], F_GETFL, 0) | O_NONBLOCK)
            _ = fcntl(winchFDs[1], F_SETFL, fcntl(winchFDs[1], F_GETFL, 0) | O_NONBLOCK)
            gWinchWriteFD = winchFDs[1]
            signal(SIGWINCH) { _ in
                var byte: UInt8 = 1
                _ = write(gWinchWriteFD, &byte, 1)
            }
        }

        var fds = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: master, events: Int16(POLLIN), revents: 0),
            pollfd(fd: winchFDs[0], events: Int16(POLLIN), revents: 0),
        ]
        var input = [UInt8](repeating: 0, count: 16384)
        var output = [UInt8]()
        output.reserveCapacity(16384)

        loop: while true {
            // Safety valve for a writer that stops mid-escape. It can be
            // generous: the only thing the scanner ever holds is a prefix of
            // our own literal, so a wait costs a delayed ESC that nothing else
            // writes, while flushing early breaks a sequence that arrived
            // fragmented — which is exactly what a laggy ssh hop does to it.
            let timeout: Int32 = scanner.isHoldingBytes ? 500 : -1
            let ready = poll(&fds, nfds_t(fds.count), timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                output.removeAll(keepingCapacity: true)
                scanner.flush(into: &output)
                writeAll(STDOUT_FILENO, output)
                continue
            }

            if fds[2].revents & Int16(POLLIN) != 0 {
                var drain = [UInt8](repeating: 0, count: 64)
                while read(winchFDs[0], &drain, drain.count) > 0 {}
                var size = winsize()
                if ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &size) == 0 {
                    _ = ioctl(master, UInt(TIOCSWINSZ), &size)
                }
            }

            if fds[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                let n = read(STDIN_FILENO, &input, input.count)
                if n > 0 {
                    writeAll(master, input, count: n)
                } else if n == 0 || errno != EINTR {
                    // The terminal is gone or closed. Stop watching it; the
                    // child may still have output to flush. A negative fd makes
                    // poll skip the slot.
                    fds[0].fd = -1
                }
            }

            if fds[1].revents & Int16(POLLIN | POLLHUP) != 0 {
                let n = read(master, &input, input.count)
                if n > 0 {
                    output.removeAll(keepingCapacity: true)
                    let hits = input.withUnsafeBufferPointer { buffer in
                        scanner.feed(UnsafeBufferPointer(rebasing: buffer[0..<n]), into: &output)
                    }
                    writeAll(STDOUT_FILENO, output)
                    if hits > 0 { requester.fire() }
                } else if n == 0 || errno != EINTR {
                    // EOF, or EIO once the last slave fd closes: the child is
                    // done and the pty has nothing left to give.
                    break loop
                }
            }
        }

        // Whatever the scanner was still holding belongs to the terminal.
        output.removeAll(keepingCapacity: true)
        scanner.flush(into: &output)
        writeAll(STDOUT_FILENO, output)

        // The child's last keystroke may have asked for a switch that is
        // still in flight. Exiting here would drop it mid-connection.
        requester.drain(.milliseconds(300))

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        close(master)
        return exitCode(from: status)
    }

    // MARK: - Terminal state

    /// Raw mode, because every byte belongs to the child: the pty's own line
    /// discipline is what turns ^C into SIGINT, and doing it twice would eat
    /// the byte before the child ever saw it.
    private static func enterRawMode() {
        guard tcgetattr(STDIN_FILENO, &gSavedTermios) == 0 else { return }
        gTermiosSaved = true
        var raw = gSavedTermios
        cfmakeraw(&raw)
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    private static func restoreTerminal() {
        guard gTermiosSaved else { return }
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &gSavedTermios)
    }

    /// A terminal left in raw mode is a terminal the user has to `reset`. The
    /// handlers exist so that being killed does not do that to them.
    private static func installHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(sig) { received in
                if gTermiosSaved { _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &gSavedTermios) }
                _exit(128 &+ received)
            }
        }
    }

    // MARK: - Process helpers

    private static func spawn(
        _ command: [String], _ pid: inout pid_t,
        _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>?,
        _ attributes: UnsafeMutablePointer<posix_spawnattr_t?>?
    ) -> Int32 {
        var argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }
        // posix_spawnp, not posix_spawn: the command is whatever the user types
        // at a shell prompt — `docker`, `orb`, `tailcat` — and it has to be
        // found on PATH the same way.
        return posix_spawnp(&pid, command[0], actions, attributes, &argv, environ)
    }

    private static func spawnAndWait(
        _ command: [String],
        fileActions: UnsafeMutablePointer<posix_spawn_file_actions_t?>?,
        attributes: UnsafeMutablePointer<posix_spawnattr_t?>?
    ) -> Int32 {
        var pid: pid_t = 0
        let spawned = spawn(command, &pid, fileActions, attributes)
        guard spawned == 0 else {
            let why = String(cString: strerror(spawned))
            FileHandle.standardError.write(Data("imswitch: cannot run \(command[0]): \(why)\n".utf8))
            return 127
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return exitCode(from: status)
    }

    /// The shell convention: a signalled child reports as 128 + the signal.
    private static func exitCode(from status: Int32) -> Int32 {
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        return 128 &+ (status & 0x7f)
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], count: Int? = nil) -> Bool {
        let total = count ?? bytes.count
        var offset = 0
        while offset < total {
            let n = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), total - offset)
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

/// Held for the signal handlers, which may only touch async-signal-safe things
/// — `tcsetattr` is on that list, `print` is not. Plain globals rather than
/// type members because a @convention(c) handler may not capture context, and
/// naming a static property counts as capturing.
private var gSavedTermios = termios()
private var gTermiosSaved = false
/// Self-pipe: SIGWINCH has to reach the poll loop, and the handler itself
/// cannot safely do the ioctl dance.
private var gWinchWriteFD: Int32 = -1

// MARK: - Scanner

/// Finds `ESC _ imswitch;switch ST` in a byte stream and removes it, passing
/// everything else through untouched.
///
/// APC rather than OSC: OSC 777 and 1337 are already taken (urxvt, iTerm2), and
/// a sequence that reaches a real terminal instead of this proxy has to be
/// swallowed silently rather than drawn. Terminals ignore APC they do not know.
///
/// The rule throughout is that anything not provably ours is passed on. A
/// mangled escape sequence is a cosmetic glitch; a swallowed byte can corrupt
/// whatever the user was actually looking at.
private struct SequenceScanner {
    private static let terminatedByST = Array("\u{1b}_imswitch;switch\u{1b}\\".utf8)
    private static let terminatedByBEL = Array("\u{1b}_imswitch;switch\u{07}".utf8)

    /// Bytes withheld because they are still a prefix of one of the two
    /// literals. The prefix rule bounds this at 19 bytes, so there is no
    /// separate cap to enforce and no way to make the proxy buffer a stream.
    private var pending: [UInt8] = []

    var isHoldingBytes: Bool { !pending.isEmpty }

    mutating func feed(_ chunk: UnsafeBufferPointer<UInt8>, into out: inout [UInt8]) -> Int {
        var hits = 0
        var index = 0
        while index < chunk.count {
            if pending.isEmpty {
                // Only ESC can begin the sequence, and terminal output is
                // overwhelmingly not ESC. Copy the run up to the next one in
                // bulk so that `cat` of a large file stays a memcpy.
                var next = index
                while next < chunk.count && chunk[next] != 0x1b { next += 1 }
                if next > index {
                    out.append(contentsOf: UnsafeBufferPointer(rebasing: chunk[index..<next]))
                }
                if next == chunk.count { break }
                pending.append(0x1b)
                index = next + 1
                continue
            }

            let byte = chunk[index]
            index += 1
            pending.append(byte)
            if pending == Self.terminatedByST || pending == Self.terminatedByBEL {
                hits += 1
                pending.removeAll(keepingCapacity: true)
                continue
            }
            if Self.isPrefix(pending) { continue }

            // Not ours. Hand back everything except the byte that broke the
            // match, then reconsider that byte alone — `ESC ESC _ …` is legal
            // input and the second ESC may start the real thing.
            pending.removeLast()
            out.append(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
            if byte == 0x1b {
                pending.append(byte)
            } else {
                out.append(byte)
            }
        }
        return hits
    }

    mutating func flush(into out: inout [UInt8]) {
        guard !pending.isEmpty else { return }
        out.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    private static func isPrefix(_ candidate: [UInt8]) -> Bool {
        for literal in [terminatedByST, terminatedByBEL]
        where candidate.count < literal.count && literal.starts(with: candidate) {
            return true
        }
        return false
    }
}

// MARK: - Talking to the daemon

/// Sends `switch` to the local daemon, off the proxy loop.
///
/// On the loop it would be a correctness bug: a wedged daemon would freeze the
/// user's terminal for as long as the client's timeouts allow. Dropping
/// requests while one is in flight costs nothing, because every request
/// converges on the same state — the same reason the Neovim side throttles on
/// the leading edge instead of queueing.
private final class SwitchRequester {
    private let queue = DispatchQueue(label: "com.hongzio.imswitch.remote")
    private let outstanding = DispatchGroup()
    private var inFlight = false
    private var lastFire: UInt64 = 0
    /// Anything that can write to the terminal can ask for a switch. That is a
    /// far smaller surface than a port — it means already being inside the
    /// user's session — but a runaway or hostile writer should still not be
    /// able to drive TIS at stream speed.
    private static let minimumInterval: UInt64 = 100 * 1_000_000

    func fire() {
        // enter() before the hop onto the queue, not inside it. The child can
        // exit in the same instant its last sequence arrives, and a drain that
        // ran before the queue block did would find an empty group and let the
        // process go — losing exactly the request the user just asked for.
        outstanding.enter()
        queue.async { [self] in
            let now = DispatchTime.now().uptimeNanoseconds
            guard !inFlight, now &- lastFire >= Self.minimumInterval else {
                outstanding.leave()
                return
            }
            inFlight = true
            lastFire = now
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                Client.send("switch")
                queue.async { self.inFlight = false }
                outstanding.leave()
            }
        }
    }

    /// Bounded, because a wedged daemon must not hold the terminal's exit.
    func drain(_ timeout: DispatchTimeInterval) {
        _ = outstanding.wait(timeout: .now() + timeout)
    }
}
