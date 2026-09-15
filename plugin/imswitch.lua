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

vim.api.nvim_create_user_command('Imswitch', function()
  require('imswitch').command()
end, { desc = 'imswitch: force a switch and report the channel it resolved' })
