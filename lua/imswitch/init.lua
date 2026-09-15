--- imswitch — force the macOS input source back to the configured target
--- whenever Neovim moves into command input.
---
--- Three channels, and which ones apply is decided per event:
---
---   * the daemon's unix socket, when nvim runs on the Mac itself;
---   * an escape sequence written to nvim's own terminal, when it does not. It
---     rides the stream that is already there, back to an `imswitch remote --`
---     on the Mac, which strips it and asks the daemon. Nothing is tunnelled,
---     nothing listens, and nothing is installed at the far end — so a
---     container, a tailcat host and three ssh hops all work the same way, and
---     so does a `--network none` container with no shell worth speaking of;
---   * the same sequence written *directly to the session's tty*, for when a
---     multiplexer sits in between. tmux, herdr and screen are terminal
---     emulators: they parse a pane's bytes into a grid and re-render it, and a
---     sequence that owns no cell has nowhere to live, so it is dropped. But
---     the multiplexer is only one program in that session — the session's own
---     pty is a device file any process of the same user can open. Writing
---     there goes under the multiplexer rather than through it. See the README
---     for the three lines of shell that record the path.
---
--- Nothing is remembered between events. The channel is resolved from what is
--- true right now, which is what lets a three-day-old nvim inside tmux pick up
--- a proxy that only started this morning.

local uv = vim.uv or vim.loop

local M = {}

--- Mirrored in plugin/imswitch.lua, which wires the autocmds at startup
--- without loading this module. Change both, or override via setup().
M.config = {
  socket = nil, -- defaults to ~/.local/state/imswitch/imswitch.sock
  tty_hints = nil, -- defaults to ~/.local/state/imswitch/tty.d
  throttle_ms = 150,
  connect_timeout_ms = 1000,
  events = { 'FocusGained', 'InsertLeave', 'CmdlineEnter' },
}

local state = { last_send = 0 }

local ESC = '\27'
--- APC, not OSC: 777 and 1337 already belong to urxvt and iTerm2, and a
--- sequence that reaches a real terminal instead of the proxy has to be
--- swallowed in silence rather than drawn. Terminals ignore APC they do not
--- recognise.
local SEQUENCE = ESC .. '_imswitch;switch' .. ESC .. '\\'
--- tmux drops escape sequences it does not know. It forwards them only when the
--- pane opts in with `set -g allow-passthrough on`, and only inside a DCS
--- wrapper whose every inner ESC is doubled.
local TMUX_SEQUENCE = ESC .. 'Ptmux;' .. (SEQUENCE:gsub(ESC, ESC .. ESC)) .. ESC .. '\\'

local function now_ms()
  return uv.hrtime() / 1e6
end

local function home()
  return uv.os_homedir() or vim.env.HOME or ''
end

local function state_dir()
  local base = vim.env.XDG_STATE_HOME
  if base == nil or base == '' then base = home() .. '/.local/state' end
  return base .. '/imswitch'
end

local function socket_path()
  local path = M.config.socket or (home() .. '/.local/state/imswitch/imswitch.sock')
  return (path:gsub('^~', function() return home() end))
end

--- Each file in the hint directory holds the path of one live session's tty.
--- A session writes its own on login and removes it on exit, so the set is
--- "terminals currently attached to this box" — which, when more than one Mac
--- is connected, is exactly the set that should hear about a switch.
local function tty_hints()
  local dir = M.config.tty_hints or (state_dir() .. '/tty.d')
  local request = uv.fs_scandir(dir)
  if not request then return {} end

  local paths = {}
  while true do
    local name, kind = uv.fs_scandir_next(request)
    if not name then break end
    if kind ~= 'directory' then paths[#paths + 1] = dir .. '/' .. name end
  end
  return paths
end

--- @return integer how many session ttys accepted the write
local function send_to_ttys()
  local sent = 0
  for _, hint in ipairs(tty_hints()) do
    local fd = uv.fs_open(hint, 'r', 384)
    if fd then
      local body = uv.fs_read(fd, 256, 0)
      uv.fs_close(fd)
      -- Absolute paths only. The directory is 0700 and ours, but a truncated or
      -- half-written hint should fail closed rather than open something else.
      local path = body and body:match('^%s*(/[^%s]+)')
      if path then
        local flags = uv.constants.O_WRONLY + uv.constants.O_NONBLOCK
          + uv.constants.O_NOCTTY
        -- O_NOCTTY: this must never become nvim's controlling terminal.
        -- O_NONBLOCK: a tty whose reader has stopped draining must not wedge
        -- the editor, and a session that has gone away fails here immediately.
        local tty = uv.fs_open(path, flags, 384)
        if tty then
          if uv.fs_write(tty, SEQUENCE) then sent = sent + 1 end
          uv.fs_close(tty)
        end
        -- A hint that cannot be opened is left alone. Unlinking it would turn
        -- one transient error into a channel that stays dead until the next
        -- login, and the session's own exit trap already cleans up.
      end
    end
  end
  return sent
end

--- Resolved on every event, not cached: the daemon may start after nvim did,
--- and a proxy may appear or vanish under a long-lived session.
local function resolve()
  local path = socket_path()
  local stat = uv.fs_stat(path)
  if stat and stat.type == 'socket' then
    return { kind = 'pipe', path = path, label = 'pipe ' .. path }
  end

  local tmux = vim.env.TMUX ~= nil and vim.env.TMUX ~= ''
  local hints = #tty_hints()
  local label = tmux and 'terminal sequence (tmux-wrapped)' or 'terminal sequence'
  if hints > 0 then label = label .. (' + %d session tty'):format(hints) end
  return { kind = 'sequence', tmux = tmux, label = label }
end

--- One connection per event. The payload is a few bytes at human speed, and a
--- socket that has gone away has to surface as one failed connect() rather than
--- a handle held open across events.
local function send_pipe(path, done)
  local handle = uv.new_pipe(false)
  if not handle then
    return done(false, 'no handle')
  end

  local timer = uv.new_timer()
  if not timer then
    -- Without the watchdog a hung connect would strand this handle forever.
    handle:close()
    return done(false, 'no timer')
  end
  local finished = false

  local function finish(ok, err)
    if finished then return end
    finished = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if not handle:is_closing() then handle:close() end
    done(ok, err)
  end

  timer:start(M.config.connect_timeout_ms, 0, function() finish(false, 'timeout') end)

  local function on_connect(err)
    -- The watchdog may have closed the handle already.
    if finished then return end
    if err then return finish(false, err) end
    -- uv_close cancels queued writes, so the close belongs *inside* the write
    -- callback. Closing right after :write() truncates the payload.
    handle:write('switch\n', function(werr)
      finish(werr == nil, werr)
    end)
  end

  local ok, result, connect_err = pcall(handle.connect, handle, path, on_connect)
  if not ok then
    finish(false, result)
  elseif result == nil then
    -- luv reports some failures by returning nil, err rather than raising, and
    -- then never calls on_connect. Without this the watchdog is the only thing
    -- that notices, a full second later.
    finish(false, connect_err)
  end
end

--- Write straight to the terminal the UI is attached to. This is the same door
--- Neovim's own OSC 52 clipboard uses to reach the Mac from a remote host.
local function send_sequence(tmux)
  local payload = tmux and TMUX_SEQUENCE or SEQUENCE
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(payload)
  else
    -- Before nvim_ui_send existed, stderr was the way to the terminal.
    vim.api.nvim_chan_send(vim.v.stderr, payload)
  end
end

--- @param opts table|nil `force` skips the throttle, `on_result` is called with
---        (ok, err, endpoint) once the request settles.
--- @return boolean sent whether a request actually went out
function M.fire(opts)
  opts = opts or {}

  local t = now_ms()
  -- Leading edge, not a trailing debounce: right after ':' the *next* keystroke
  -- already has to be ASCII. Fire now, drop the rest of the window — every
  -- request converges on the same state, so queueing would buy nothing.
  if not opts.force and t - state.last_send < M.config.throttle_ms then
    return false
  end
  state.last_send = t

  local endpoint = resolve()
  if endpoint.kind == 'pipe' then
    send_pipe(endpoint.path, function(ok, err)
      if opts.on_result then opts.on_result(ok, err, endpoint) end
    end)
  else
    -- Both, unconditionally. Each costs a few syscalls whether or not anything
    -- is listening, so there is nothing to gain by working out which one
    -- applies — and nothing to lose if both arrive, because the daemon's switch
    -- is idempotent and the proxy collapses repeats inside 100 ms.
    send_to_ttys()
    send_sequence(endpoint.tmux)
    -- Fire and forget: the bytes leave through a one-way channel and whether
    -- anything is listening upstream is not knowable from here, which is the
    -- same silence the socket path keeps when no daemon is running.
    if opts.on_result then opts.on_result(true, nil, endpoint) end
  end
  return true
end

-- Insert, replace, terminal and select: the user is composing prose.
local prose_modes = { i = true, R = true, t = true, s = true, S = true, ['\19'] = true }

local function composing()
  return prose_modes[vim.api.nvim_get_mode().mode:sub(1, 1)] == true
end

--- Autocmd entry point. Failure must never reach the user, so everything is
--- wrapped and nothing notifies.
function M.on_event(event)
  pcall(function()
    -- Returning to a half-typed Hangul syllable must not steal the
    -- composition. InsertLeave and CmdlineEnter *are* the move into command
    -- input, so they always fire.
    if event == 'FocusGained' and composing() then return end
    M.fire()
  end)
end

function M.wire()
  local group = vim.api.nvim_create_augroup('imswitch', { clear = true })
  vim.api.nvim_create_autocmd(M.config.events, {
    group = group,
    desc = 'imswitch: force the macOS input source to the configured target',
    callback = function(ev) M.on_event(ev.event) end,
  })
end

function M.status()
  return { endpoint = resolve().label }
end

--- :Imswitch — the debugging escape hatch. Forces a request through and reports
--- the channel it resolved. The only place in the plugin allowed to talk to the
--- user.
function M.command()
  M.fire({
    force = true,
    on_result = function(ok, err, endpoint)
      vim.schedule(function()
        local outcome = ok and 'sent' or ('failed: ' .. tostring(err))
        if ok and endpoint.kind == 'sequence' then
          -- Worth saying plainly: a sequence with no `imswitch remote --`
          -- upstream is indistinguishable from one that arrived.
          outcome = 'sent (no reply on this channel)'
        end
        vim.notify(('imswitch: %s -> %s'):format(endpoint.label, outcome),
          ok and vim.log.levels.INFO or vim.log.levels.WARN)
      end)
    end,
  })
end

--- Optional; plugin/imswitch.lua already wires the defaults. Only needed to
--- override them.
function M.setup(opts)
  M.config = vim.tbl_extend('force', M.config, opts or {})
  M.wire()
end

return M
