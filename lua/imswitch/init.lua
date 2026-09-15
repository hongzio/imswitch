--- imswitch — force the macOS input source back to the configured target
--- whenever Neovim moves into command input.
---
--- Talks to the Imswitch.app daemon over a unix socket when nvim runs on the
--- Mac, or over 127.0.0.1:57377 when it runs behind an `ssh -R` tunnel. The
--- whole module is written so that a missing daemon or a dead tunnel costs
--- nothing and says nothing.

local uv = vim.uv or vim.loop

local M = {}

--- Mirrored in plugin/imswitch.lua, which wires the autocmds at startup
--- without loading this module. Change both, or override via setup().
M.config = {
  socket = nil, -- defaults to ~/.local/state/imswitch/imswitch.sock
  host = '127.0.0.1',
  port = 57377,
  throttle_ms = 150,
  connect_timeout_ms = 1000,
  failure_threshold = 3,
  cooldown_ms = 60 * 1000,
  events = { 'FocusGained', 'InsertLeave', 'CmdlineEnter' },
}

local state = {
  endpoint = nil,
  last_send = 0,
  failures = 0,
  cooldown_until = 0,
}

local loopback = { ['127.0.0.1'] = true, ['::1'] = true, ['localhost'] = true }

local function now_ms()
  return uv.hrtime() / 1e6
end

local function home()
  return uv.os_homedir() or vim.env.HOME or ''
end

--- Resolved on the first event rather than at startup: the socket may not
--- exist yet when nvim launches, and a remote nvim has no socket at all.
local function resolve_endpoint()
  local function tcp(host, port)
    return { kind = 'tcp', host = host, port = port, label = 'tcp ' .. host .. ':' .. port }
  end
  local function pipe(path)
    return { kind = 'pipe', path = path, label = 'pipe ' .. path }
  end

  local override = vim.env.IMSWITCH_ADDR
  if override and override ~= '' then
    local host, port = override:match('^(.+):(%d+)$')
    if host then
      -- The override exists to reach an ssh -R tunnel, which always lands on
      -- loopback. A non-loopback address would turn every ':' into an outbound
      -- packet announcing that the user is at their editor, to whoever set the
      -- variable — so ignore it and fall through to the defaults.
      if loopback[host] then return tcp(host, tonumber(port)) end
    else
      return pipe(override)
    end
  end

  local path = M.config.socket or (home() .. '/.local/state/imswitch/imswitch.sock')
  path = (path:gsub('^~', function() return home() end))
  local stat = uv.fs_stat(path)
  if stat and stat.type == 'socket' then return pipe(path) end

  return tcp(M.config.host, M.config.port)
end

--- One connection per event. The payload is a few bytes at human speed, and a
--- persistent connection over an ssh RemoteForward dies quietly with the
--- tunnel — reconnecting turns a dead tunnel into one failed connect().
local function send(endpoint, done)
  local handle = endpoint.kind == 'pipe' and uv.new_pipe(false) or uv.new_tcp()
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

  -- connect() into a half-dead tunnel can hang indefinitely; handles must not
  -- pile up.
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

  local ok, result, connect_err
  if endpoint.kind == 'pipe' then
    ok, result, connect_err = pcall(handle.connect, handle, endpoint.path, on_connect)
  else
    ok, result, connect_err = pcall(handle.connect, handle, endpoint.host, endpoint.port, on_connect)
  end
  if not ok then
    finish(false, result)
  elseif result == nil then
    -- luv reports some failures by returning nil, err rather than raising, and
    -- then never calls on_connect. Without this the watchdog is the only thing
    -- that notices, a full second later.
    finish(false, connect_err)
  end
end

local function record(ok)
  if ok then
    state.failures = 0
    return
  end

  state.failures = state.failures + 1
  if state.failures >= M.config.failure_threshold then
    -- No daemon and no tunnel on this machine: stop eating a refused connect
    -- on every ':'.
    state.failures = 0
    state.cooldown_until = now_ms() + M.config.cooldown_ms
    -- Drop the cached endpoint so the daemon can come back as the other kind.
    state.endpoint = nil
  end
end

--- @param opts table|nil `force` skips throttle and cooldown, `on_result` is
---        called with (ok, err, endpoint) once the write settles.
--- @return boolean sent whether a request actually went out
function M.fire(opts)
  opts = opts or {}

  local t = now_ms()
  if not opts.force then
    if t < state.cooldown_until then return false end
    -- Leading edge, not a trailing debounce: right after ':' the *next*
    -- keystroke already has to be ASCII. Fire now, drop the rest of the
    -- window — every request converges on the same state, so queueing is
    -- pointless.
    if t - state.last_send < M.config.throttle_ms then return false end
  end
  state.last_send = t

  local endpoint = state.endpoint
  if not endpoint then
    endpoint = resolve_endpoint()
    state.endpoint = endpoint
  end

  send(endpoint, function(ok, err)
    record(ok)
    if opts.on_result then opts.on_result(ok, err, endpoint) end
  end)
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
  local endpoint = state.endpoint or resolve_endpoint()
  return {
    endpoint = endpoint.label,
    failures = state.failures,
    cooldown_remaining_ms = math.max(0, math.floor(state.cooldown_until - now_ms())),
  }
end

--- :Imswitch — the debugging escape hatch. Clears the cooldown, forces a
--- request through, and reports the endpoint it resolved. The only place in
--- the plugin allowed to talk to the user.
function M.command()
  state.failures = 0
  state.cooldown_until = 0
  state.endpoint = nil

  local endpoint = resolve_endpoint()
  state.endpoint = endpoint
  M.fire({
    force = true,
    on_result = function(ok, err)
      vim.schedule(function()
        vim.notify(
          ('imswitch: %s -> %s'):format(endpoint.label, ok and 'ok' or ('failed: ' .. tostring(err))),
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
