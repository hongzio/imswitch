# imswitch

Force the macOS input source back to ASCII the moment Neovim expects command
keys — from a local terminal, from an SSH session, or from inside a container.

Leave a Hangul IME on, return to vim, and every normal-mode key is gone:
`hjkl` arrives as `ㅗㅓㅏㅣ`. The fix is to tie three Neovim events —
`FocusGained`, `InsertLeave`, `CmdlineEnter` — to a macOS input source switch.
The catch is that vim is not always on the Mac. It also runs over SSH on EC2
and inside containers, and a remote process cannot reach the Text Input
Sources API.

So the switching lives on the Mac, in one process, and Neovim just pokes it.

## How it works

```
Imswitch.app (LSUIElement, menu bar)        ← managed by brew services
├── NSStatusItem ─ pick the target input source / enable / status
└── unix socket ─ ~/.local/state/imswitch/imswitch.sock
         ▲                          ▲
         │ local nvim               │ remote nvim over an ssh -R tunnel
                                    (127.0.0.1:57377 on the remote side)
```

One binary, two roles. `imswitch serve` is the menu bar app *and* the socket
server; every other verb is a small CLI client that talks to it. The protocol
is newline-delimited text and always answers, so `nc -U` is a complete client.

The plugin never reverts to Hangul — switching back is yours to do, the way you
always have (F17). IMEs with sub-modes do not restore reliably, so imswitch
does not try.

The target input source is **not** hardcoded. It is chosen from the menu bar
and stored in the app's defaults, so swapping Gureum for Apple's 2-set layout,
or anything else, needs no code change.

## Install

### Homebrew

```sh
brew trust hongzio/tap          # Homebrew 7 refuses to load untrusted third-party taps
brew tap hongzio/tap
brew install --HEAD imswitch
brew services start imswitch
```

`brew services` installs the LaunchAgent into `~/Library/LaunchAgents` and
bootstraps it into `gui/$UID`, the Aqua session. Both TIS and `NSStatusItem`
require that session — do not hand-write the plist.

### From source

```sh
./build.sh          # -> build/Imswitch.app, ad-hoc signed
open build/Imswitch.app
```

Launching the bundle with no arguments — from Finder, from `open`, or from a
LaunchAgent that omits it — is the same as `imswitch serve`.

Requires only the Command Line Tools: `Carbon.framework`, `TextInputSources.h`
and the Swift module map all ship there, so no full Xcode install is needed.

## Neovim

The plugin wires itself; `setup()` is only for overriding defaults.

```lua
vim.pack.add({ { src = 'https://github.com/hongzio/imswitch' } })
```

```lua
require('imswitch').setup({
  socket = '~/.local/state/imswitch/imswitch.sock',
  host = '127.0.0.1',
  port = 57377,
  throttle_ms = 150,
  connect_timeout_ms = 1000,
  failure_threshold = 3,
  cooldown_ms = 60 * 1000,
  events = { 'FocusGained', 'InsertLeave', 'CmdlineEnter' },
})
```

`$IMSWITCH_ADDR` overrides the endpoint for one session: `host:port` is TCP,
anything else is a socket path.

`:Imswitch` clears the cooldown, forces a request through, and reports the
endpoint it resolved. It is the only part of the plugin that ever talks to
you.

Behaviour worth knowing:

- **Endpoint resolution is lazy.** Nothing happens at startup. On the first
  event the plugin stats the local socket; if it is there, it uses it,
  otherwise it falls through to TCP `127.0.0.1:57377` — which is where the
  `ssh -R` tunnel lands on a remote box.
- **Leading-edge throttle, not a trailing debounce.** Right after `:` the
  *next* keystroke already has to be ASCII, so the request goes out
  immediately and repeats inside the 150 ms window are dropped. Every request
  converges on the same state, so queueing would buy nothing.
- **A fresh connection per event.** The payload is seven bytes at human speed,
  and a persistent connection over an `ssh` RemoteForward dies silently with
  the tunnel. Reconnecting turns a dead tunnel into one failed `connect()`.
- **`FocusGained` is skipped while composing prose** (insert, replace,
  terminal, select). Coming back from another app mid-syllable must not steal
  the composition. `InsertLeave` and `CmdlineEnter` *are* the move into
  command input, so they always fire.
- **Silent when there is nothing to talk to.** Three consecutive failures buy
  a 60-second cooldown, and the endpoint cache is dropped so the daemon can
  come back as the other kind. No messages, no lag, and recovery needs no
  restart.

## SSH

```sh
imswitch ssh-config >> ~/.ssh/config
```

```sshconfig
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
```

Three things about this block are load-bearing:

- **Order.** ssh takes the first value it sees for each keyword, so the
  exception block has to sit *above* `Host *`.
- **The remote end is TCP, not a unix socket.** `StreamLocalBindUnlink` exists
  only in the *remote* `sshd_config`. A remote unix socket left behind by an
  unclean exit would block forwarding for every later session; a TCP port is
  released when the session ends.
- **`ControlMaster` is effectively required.** OpenSSH never retries a failed
  remote forward, so without a shared connection the second session to a host
  stays tunnel-less forever. Sharing the connection means one tunnel per host
  and the problem disappears. Git hosts are excluded above, since a shared
  master there is a nuisance.

## Commands

| command | what it does | reply |
|---|---|---|
| `imswitch serve` | menu bar app + socket server (also the no-argument default) | — |
| `imswitch switch` | switch to the configured target; no-op if already there | `ok switched` / `ok noop` / `ok disabled` / `err ...` |
| `imswitch get` | current input source ID | `ok <source-id>` |
| `imswitch ping` | liveness check | `pong` |
| `imswitch ssh-config` | print the ssh_config snippet | (text) |

Switching is idempotent by design. The triggers fire often enough that an
unconditional `TISSelectInputSource` makes the IME visibly flicker.

## Menu bar

```
현재: Han 2set
───────────────────────────
전환 대상
  ✓ ABC
    Han 2set
───────────────────────────
☑ 활성화
지금 전환 (테스트)
마지막 요청: 12:34:56
───────────────────────────
종료
```

The menu is rebuilt every time it opens, so input sources added or removed
since the last look show up immediately. Palettes (Emoji & Symbols, Press and
Hold) are filtered out — they report as selectable but are not keyboards.
"마지막 요청" is the cheapest way to tell whether a remote tunnel is alive.

## Troubleshooting

- **The switch is reverted right away, and `switched` piles up in the log.**
  Gureum's "한/영 자동 전환" re-selects Hangul per app and will fight you. Turn
  it off.
- **Nothing changes in the frontmost app.** Check System Settings → Keyboard →
  Input Sources for the per-document input source option. `defaults read` is
  stale here; look at the settings window. (Measured on macOS 26: with that
  option *on*, imswitch still works — `TISSelectInputSource` writes into the
  frontmost app's context, so the remembered source becomes the target rather
  than fighting it.)
- **`imswitch get` says `err no-current-source`.** The daemon is not in the
  Aqua session. Start it through `brew services`, not from a bare shell over
  SSH.
- **Gatekeeper blocks the app.** A local build carries no quarantine
  attribute, but if it ever does: `xattr -d com.apple.quarantine`.
- **A `docker exec` shell has no tunnel.** It never went through ssh, so the
  plugin quietly does nothing. OrbStack's `<container>@orb` is ssh and works.
- **Logs grow fast.** `CmdlineEnter` fires on `:`, `/`, `?` and on plugin
  `input()`/`confirm()` calls. Requests are not logged for that reason; if the
  file still grows, warnings are the thing to read.

## Wiring left to do

Two other repos are needed to make this installable; neither is touched here.

**`hongzio/homebrew-tap`** — one file, `Formula/imswitch.rb`. This was built and
installed end to end against Homebrew 7.0.1 before being written down here:
`swiftc` and `codesign` both run fine under Homebrew's superenv and sandbox, and
the generated LaunchAgent carries `ProcessType Interactive`, `KeepAlive` and an
`Aqua` session type.

```ruby
class Imswitch < Formula
  desc "Force the macOS input source from Neovim, locally or over SSH"
  homepage "https://github.com/hongzio/imswitch"
  license "MIT"
  head "https://github.com/hongzio/imswitch.git", branch: "main"
  # url/sha256 once v0.1.0 is tagged

  # No Xcode requirement. `depends_on xcode: :clt` is a trap: XcodeRequirement
  # only parses a version string off its tags, so :clt is ignored and a full
  # Xcode.app is demanded — the build fails on a Command Line Tools machine with
  # "A full installation of Xcode.app is required". Homebrew already requires the
  # CLT, which is all build.sh needs.
  depends_on :macos

  def install
    system "./build.sh"
    prefix.install "build/Imswitch.app"
    bin.install_symlink prefix/"Imswitch.app/Contents/MacOS/imswitch"
  end

  service do
    run [opt_prefix/"Imswitch.app/Contents/MacOS/imswitch", "serve"]
    keep_alive true
    process_type :interactive          # avoid App Nap; ':' latency is felt
    log_path var/"log/imswitch.log"
    error_log_path var/"log/imswitch.log"
  end

  test do
    assert_match "imswitch", shell_output("#{bin}/imswitch --help")
    assert_match "RemoteForward 57377", shell_output("#{bin}/imswitch ssh-config")
  end
end
```

Two things about the tap repo itself:

- **The name must be `homebrew-tap`.** Homebrew 7 requires third-party taps to be
  trusted, and a tap whose remote is not `https://github.com/<user>/homebrew-<repo>`
  counts as a *custom remote*, which can only be trusted by full URL
  (`Tap#matches_reference?`). Folding the formula into this repo does work —
  `brew tap hongzio/imswitch https://github.com/hongzio/imswitch` plus
  `brew trust --tap https://github.com/hongzio/imswitch` — but the `homebrew-`
  name is what keeps `brew trust hongzio/tap` short.
- **`brew trust` comes before `brew tap`**, otherwise tapping fails with
  "Cannot tap: invalid syntax in tap!" rather than anything about trust.

**`hongzio/hongzio.github.io`** (dotfiles) — thin wiring only:

- `nvim/lua/plugins/init.lua` — add `{ src = 'https://github.com/hongzio/imswitch' }`
  to the `vim.pack.add` list and `require('plugins.imswitch')` to the load order.
- `nvim/lua/plugins/imswitch.lua` (new) — `require('imswitch').setup({})`;
  `nvim/lua/plugins/virgil.lua` is the model.
- `init.sh` — two `check_step`/`mark_step` blocks: ① `brew trust hongzio/tap &&
  brew tap hongzio/tap && brew install --HEAD imswitch && brew services start
  imswitch`; ② `grep -q
  "imswitch BEGIN" ~/.ssh/config || imswitch ssh-config >> ~/.ssh/config`. The
  marker grep is the real idempotence guard for the ssh block — `$TMPDIR/checkpoint`
  does not survive a reboot.
- delete the empty `scripts/imswitch/` directory.

## License

MIT
