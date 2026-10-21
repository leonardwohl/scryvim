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
  desc = 'scryvim: search | sort | count | mana | update | info',
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

local group = vim.api.nvim_create_augroup('scryvim', { clear = true })

require('scryvim.colors').setup_highlights()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = group,
  callback = function()
    require('scryvim.colors').setup_highlights()
  end,
})

-- Narrow hover windows opened from deck buffers and color their mana symbols.
vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'markdown',
  callback = function(args)
    local win = require('scryvim.hover').deck_float(args.buf)
    if not win then
      return
    end
    local cfg = require('scryvim.config').get()
    require('scryvim.hover').fit(win, cfg.hover.max_width)
    if cfg.colors then
      require('scryvim.colors').highlight_buf(args.buf)
    end
  end,
})

-- Live totals on `// count: <query>` and `// count mana symbols` lines.
vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = 'deck',
  callback = function(args)
    if require('scryvim.config').get().counts then
      require('scryvim.tally').attach(args.buf)
    end
  end,
})

vim.api.nvim_create_autocmd('LspAttach', {
  group = group,
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    local cfg = require('scryvim.config').get()
    if not (client and client.name == 'scryvim' and cfg.inlay_hints) then
      return
    end
    -- Colored mana costs replace the single-color inlay hints.
    if cfg.colors then
      require('scryvim.mana').attach(args.buf)
    else
      vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
    end
  end,
})

vim.api.nvim_create_autocmd('LspDetach', {
  group = group,
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client.name == 'scryvim' then
      require('scryvim.mana').detach(args.buf)
    end
  end,
})
