import Foundation

enum SSHConfig {
    static let snippet = """
        # --- imswitch BEGIN ---
        # This block gives every host you SSH into a loopback-reachable channel to
        # the imswitch daemon on this Mac, and turns SSH connection sharing on
        # globally. Read the SSH section of the imswitch README before keeping it
        # on a machine where either of those is unacceptable.

        # ControlMaster is first-value-wins, so this block has to stay above
        # Host *. It matches literal names only, not aliases.
        Host github.com gitlab.com ssh.github.com bitbucket.org codeberg.org git.sr.ht ssh.dev.azure.com
            ControlMaster no

        Host *
            # The bind address is explicit on purpose. Without it, a remote sshd
            # running `GatewayPorts yes` publishes this on the wildcard address
            # instead of loopback, and ExitOnForwardFailure no means you would
            # never hear about it.
            RemoteForward 127.0.0.1:57377 %d/.local/state/imswitch/imswitch.sock
            ExitOnForwardFailure no
            ServerAliveInterval 30
            ServerAliveCountMax 3
            ControlMaster auto
            ControlPath ~/.ssh/cm-%C
            # Long enough to keep one master per host while you are working,
            # short enough that a pre-authenticated channel does not outlive the
            # session by minutes.
            ControlPersist 30

        # RemoteForward accumulates rather than first-value-wins, so ordering does
        # not stop it — clearing does. ClearAllForwardings is applied after the
        # whole config is parsed, which is why this block works below Host *, and
        # `Match final` re-evaluates after HostName substitution, which is what
        # catches an alias such as `Host gh` -> `HostName github.com`.
        Match final host github.com,gitlab.com,ssh.github.com,altssh.gitlab.com,bitbucket.org,codeberg.org,git.sr.ht,ssh.dev.azure.com,vs-ssh.visualstudio.com,git-codecommit.*.amazonaws.com,*.googlesource.com
            ClearAllForwardings yes
        # --- imswitch END ---
        """
}
