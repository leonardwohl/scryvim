if vim.g.loaded_scryvim then
  return
end
vim.g.loaded_scryvim = true

if vim.fn.has('nvim-0.11') ~= 1 then
  vim.notify('scryvim requires Neovim 0.11 or newer', vim.log.levels.WARN)
  return
end

local scryvim = require('scryvim')

local ok, err = pcall(scryvim.register_filetypes)
if not ok then
  vim.notify('scryvim: ' .. tostring(err), vim.log.levels.ERROR)
end

vim.api.nvim_create_user_command('Scryvim', scryvim.command, {
  nargs = '+',
  range = true,
  complete = scryvim.complete,
  desc = 'scryvim: search | sort | update | info',
})

vim.keymap.set('n', '<Plug>(scryvim-search)', function()
  scryvim.search()
end, { desc = 'scryvim: search Scryfall' })
vim.keymap.set('n', '<Plug>(scryvim-sort)', function()
  scryvim.sort()
end, { desc = 'scryvim: sort block by mana value' })
vim.keymap.set('x', '<Plug>(scryvim-sort)', function()
  local a, b = vim.fn.line('v'), vim.fn.line('.')
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
  scryvim.sort(0, math.min(a, b), math.max(a, b))
end, { desc = 'scryvim: sort selection by mana value' })

vim.lsp.config('scryvim', {
  cmd = function(dispatchers)
    return require('scryvim.lsp').create(dispatchers)
  end,
  filetypes = { 'deck' },
})
vim.lsp.enable('scryvim')

vim.api.nvim_create_autocmd('LspAttach', {
  group = vim.api.nvim_create_augroup('scryvim', { clear = true }),
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client.name == 'scryvim' and require('scryvim.config').get().inlay_hints then
      vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
    end
  end,
})
