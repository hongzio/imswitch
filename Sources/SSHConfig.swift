import Foundation

enum SSHConfig {
    static let snippet = """
        # --- imswitch BEGIN ---
        # Order matters: ssh takes the first value it sees for each keyword, so
        # the exception block has to sit above Host *.
        Host github.com gitlab.com ssh.github.com
            ClearAllForwardings yes
            ControlMaster no

        Host *
            RemoteForward 57377 %d/.local/state/imswitch/imswitch.sock
            ExitOnForwardFailure no
            ServerAliveInterval 30
            ServerAliveCountMax 3
            ControlMaster auto
            ControlPath ~/.ssh/cm-%C
            ControlPersist 10m
        # --- imswitch END ---
        """
}
