-- Wiring only. The module itself loads on the first event, so a machine with
-- no daemon pays nothing at startup.
if vim.g.loaded_imswitch == 1 then return end
vim.g.loaded_imswitch = 1

local group = vim.api.nvim_create_augroup('imswitch', { clear = true })

-- Mirrors the default `events` in lua/imswitch/init.lua; setup() re-wires this
-- group when that list is overridden.
vim.api.nvim_create_autocmd({ 'FocusGained', 'InsertLeave', 'CmdlineEnter' }, {
  group = group,
  desc = 'imswitch: force the macOS input source to the configured target',
  callback = function(ev)
    require('imswitch').on_event(ev.event)
  end,
})

-- Mirrors CHANNELS in lua/imswitch/init.lua. Completion has to answer without
-- loading the module, for the same reason the event list above is duplicated;
-- the module validates whatever actually arrives.
vim.api.nvim_create_user_command('Imswitch', function(a)
  require('imswitch').command(a.args)
end, {
  nargs = '?',
  complete = function() return { 'all', 'socket', 'sequence' } end,
  desc = 'imswitch: force a switch, or pick the channels to send it on',
})
