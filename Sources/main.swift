import Foundation

/// nvim writes one line and hangs up without reading the reply, so the first
/// response would otherwise kill the daemon. Must happen before anything else.
signal(SIGPIPE, SIG_IGN)

let usage = """
    imswitch — force the macOS input source from Neovim, locally or anywhere

    usage: imswitch <command>

      serve         menu bar app + unix socket server (what brew services runs,
                    and what a Finder/`open` launch runs with no arguments)
      switch        switch to the configured target; no-op if already there
      get           print the current input source ID
      ping          liveness check
      remote -- CMD run CMD behind a pty, so a Neovim inside it can reach this
                    Mac with no tunnel (docker exec, orb, tailcat ssh, ...)

    socket: \(SocketPath.default)
    """

let arguments = CommandLine.arguments

// No verb means the bundle was launched as an app — by Finder, by `open`, or
// by a LaunchAgent that omits the argument. Serve.
switch arguments.count > 1 ? arguments[1] : "serve" {
case "serve":
    Daemon.run()

case "switch", "get", "ping":
    exit(Client.run(arguments[1]))

case "remote":
    // Everything after the verb is the user's command, verbatim. A leading
    // `--` is accepted and dropped so that flags meant for that command are
    // never mistaken for imswitch's own.
    var rest = Array(arguments.dropFirst(2))
    if rest.first == "--" { rest.removeFirst() }
    Remote.run(rest)

case "-h", "--help", "help":
    print(usage)
    exit(0)

default:
    FileHandle.standardError.write(Data("imswitch: unknown command '\(arguments[1])'\n\n".utf8))
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
