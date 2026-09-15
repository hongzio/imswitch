import Foundation

/// nvim writes one line and hangs up without reading the reply, so the first
/// response would otherwise kill the daemon. Must happen before anything else.
signal(SIGPIPE, SIG_IGN)

let usage = """
    imswitch — force the macOS input source from Neovim, locally or over SSH

    usage: imswitch <command>

      serve         menu bar app + unix socket server (what brew services runs,
                    and what a Finder/`open` launch runs with no arguments)
      switch        switch to the configured target; no-op if already there
      get           print the current input source ID
      ping          liveness check
      ssh-config    print the ssh_config snippet for the reverse tunnel

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

case "ssh-config":
    print(SSHConfig.snippet)
    exit(0)

case "-h", "--help", "help":
    print(usage)
    exit(0)

default:
    FileHandle.standardError.write(Data("imswitch: unknown command '\(arguments[1])'\n\n".utf8))
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
