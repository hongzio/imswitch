# imswitch

Force the macOS input source back to ASCII the moment Neovim expects command
keys — from a local terminal, from an ssh session, from inside a container,
from anywhere you can get a shell.

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
         │ local nvim               │ imswitch remote -- <anything>
                                    │   a pty in the middle of your terminal,
                                    │   stripping one escape sequence out of
                                    │   the stream that is already there
                                    └── remote nvim, in whatever that command
                                        got you into
```

One binary, three roles. `imswitch serve` is the menu bar app *and* the socket
server; `imswitch remote` is the pty proxy; every other verb is a small CLI
client. The protocol is newline-delimited text and always answers, so `nc -U`
is a complete client.

Two channels reach the daemon, and the plugin picks between them on every
event. On the Mac, the unix socket. Anywhere else, an escape sequence written
to the terminal, which `imswitch remote` pulls back out. There is no third
case: no tunnel, no listener, no port.

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
  throttle_ms = 150,
  connect_timeout_ms = 1000,
  events = { 'FocusGained', 'InsertLeave', 'CmdlineEnter' },
})
```

`:Imswitch` forces a request through and reports the channel it resolved. It is
the only part of the plugin that ever talks to you.

Behaviour worth knowing:

- **The channel is decided per event, and nothing is cached.** The plugin stats
  the socket; if it is there the daemon is local, so it writes to it. If it is
  not, it writes the escape sequence to its own terminal. A stat costs
  microseconds, and deciding again every time is what lets a three-day-old nvim
  inside tmux pick up an `imswitch remote` that only started this morning.
  There is no endpoint cache, no failure count and no cooldown to go stale.
- **Leading-edge throttle, not a trailing debounce.** Right after `:` the
  *next* keystroke already has to be ASCII, so the request goes out
  immediately and repeats inside the 150 ms window are dropped. Every request
  converges on the same state, so queueing would buy nothing.
- **A fresh connection per event on the socket channel.** The payload is seven
  bytes at human speed, and a socket that has gone away should surface as one
  failed `connect()` rather than a handle held open across events.
- **`FocusGained` is skipped while composing prose** (insert, replace,
  terminal, select). Coming back from another app mid-syllable must not steal
  the composition. `InsertLeave` and `CmdlineEnter` *are* the move into
  command input, so they always fire.
- **Silent when there is nothing to talk to.** A failed connect says nothing
  and costs nothing. The sequence channel cannot be acknowledged at all, so
  `:Imswitch` reports `sent (no reply on this channel)` rather than claiming an
  arrival it cannot know about.

## Remote

Anywhere that is not this Mac — a container, an OrbStack machine, a host behind
tailcat, three ssh hops — run the thing you were going to run anyway with
`imswitch remote --` in front of it:

```sh
imswitch remote -- ssh nas
imswitch remote -- docker exec -it devbox /bin/zsh
imswitch remote -- orb -m ubuntu
imswitch remote -- tailcat ssh tcXXXXXXXXX
imswitch remote -- kubectl exec -it pod/foo -- bash
```

imswitch puts a pty between your terminal and that command and copies bytes
both ways. It reads nothing and changes nothing, and removes exactly one thing:
`ESC _ imswitch;switch ESC \`, which the plugin writes to its own terminal when
it wants a switch. It rides the stream that is already there. This is the same
door Neovim's own OSC 52 clipboard uses to reach a Mac from a remote host.

Five things follow, and together they are the reason for this design:

- **The command is never parsed.** `remote` does not know what `docker` or
  `tailcat` are, and does not need to. Whatever you typed, runs.
- **Nothing is installed at the far end.** No listener, no tunnel, no file, no
  shell worth speaking of. A `--network none` container with a read-only rootfs
  works; so does a serial console.
- **Nesting is free.** `imswitch remote -- ssh a`, then `docker exec` from
  inside that: the sequence rides up through every hop.
- **It cannot be turned around to read you.** The channel is one-way, so
  nothing at the far end can poll whether you are at the keyboard. The `ssh -R`
  tunnel this replaces could.
- **Reaching it means already being in your session.** Writing to your terminal
  is the entire requirement, and anything that can do that is past every fence
  that matters.

Without a terminal — in a pipe or a script — `remote` runs the command
unchanged rather than wrapping it.

Two costs, stated plainly:

- **You have to remember the prefix.** Forget it and nothing happens, silently.
  A shell function is the usual fix:

  ```sh
  ssh() { command imswitch remote -- ssh "$@"; }
  ```

  `:Imswitch` names the channel it resolved, so "why is this not working" is
  one command away.
- **tmux needs `set -g allow-passthrough on`.** tmux drops escape sequences it
  does not know. The plugin wraps the sequence in tmux's DCS form when `$TMUX`
  is set, but the option still has to be on. Measured both ways: without it the
  sequence is dropped, with it plus the wrapper it arrives.

The sequence is APC rather than OSC because 777 and 1337 already belong to
urxvt and iTerm2, and one that reaches a real terminal instead of the proxy has
to be swallowed in silence rather than drawn.

One consequence worth knowing: the sequence travels in your terminal stream, so
anything already recording that stream — asciinema, a bastion's `script` log —
gets a mark every time you press `:`. It leaks presence to something that is
already recording you, and to nothing else.

## Commands

| command | what it does | reply |
|---|---|---|
| `imswitch serve` | menu bar app + socket server (also the no-argument default) | — |
| `imswitch switch` | switch to the configured target; no-op if already there | `ok switched` / `ok noop` / `ok disabled` / `err ...` |
| `imswitch get` | current input source ID | `ok <source-id>` |
| `imswitch ping` | liveness check | `pong` |
| `imswitch remote -- CMD` | run CMD behind a pty and carry switches out of it | (CMD's own output) |

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
"마지막 요청" is the cheapest way to tell whether a remote session is still
reaching you.

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
  attribute, but if it ever does:
  `xattr -d com.apple.quarantine build/Imswitch.app` — for a bundle you built
  yourself, not as a general habit.
- **Nothing happens in a remote nvim.** Almost always the missing
  `imswitch remote --` prefix: without the proxy the sequence reaches your real
  terminal, which ignores it. Run `:Imswitch` — it names the channel it
  resolved.
- **Nothing happens inside tmux.** `set -g allow-passthrough on`. tmux drops
  escape sequences it does not recognise, wrapper or not.
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
    # No terminal here, so `remote` runs the command unchanged -- which is
    # exactly the path a script or a pipeline takes.
    assert_equal "ok", shell_output("#{bin}/imswitch remote -- /bin/echo ok").strip
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
- `init.sh` — one `check_step`/`mark_step` block: `brew trust hongzio/tap &&
  brew tap hongzio/tap && brew install --HEAD imswitch && brew services start
  imswitch`. Nothing is appended to `~/.ssh/config` any more; there is no ssh
  config to keep idempotent.
- `zsh/` — the `ssh()` wrapper from the Remote section, and whichever of
  `docker`/`orb`/`tailcat` are worth the same treatment.
- `tmux.conf` — `set -g allow-passthrough on`.
- delete the empty `scripts/imswitch/` directory.

## License

MIT
