--- Public API. Heavy modules are required lazily.
local config = require('scryvim.config')

local M = {}

--- Register the `deck` filetype for the configured extensions.
function M.register_filetypes(cfg)
  local ext = {}
  for _, e in ipairs((cfg or config.get()).extensions) do
    ext[e] = 'deck'
  end
  vim.filetype.add({ extension = ext })
end

--- Optional. Opts override `vim.g.scryvim`.
---@param opts? table
function M.setup(opts)
  M.register_filetypes(config.setup(opts))
end

--- Open the Scryfall picker. Prompts when `query` is empty.
---@param query? string
function M.search(query)
  require('scryvim.picker').search(query)
end

--- Sort lines `first..last` (1-based, inclusive) by mana value. Without a
--- range, sorts the block under the cursor.
---@param bufnr? integer
---@param first? integer
---@param last? integer
function M.sort(bufnr, first, last)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local data = require('scryvim.data')
  local sort = require('scryvim.sort')
  data.ensure()
  if not data.ready() then
    vim.notify('scryvim: card data is not loaded yet', vim.log.levels.WARN)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if not first then
    first, last = sort.block_at(lines, vim.api.nvim_win_get_cursor(0)[1])
    if not first then
      return
    end
  end
  local segment = vim.list_slice(lines, first, last)
  local sorted = sort.lines(segment, data.get)
  if not vim.deep_equal(segment, sorted) then
    vim.api.nvim_buf_set_lines(bufnr, first - 1, last, false, sorted)
  end
end

--- Force a card data refresh.
function M.update()
  require('scryvim.data').update({ force = true, announce = true })
end

function M.info()
  local i = require('scryvim.data').info()
  local lines = {
    ('cards:      %d%s'):format(i.count, i.updating and ' (updating)' or ''),
    ('updated_at: %s'):format(i.updated_at or 'never'),
    ('cache age:  %s'):format(i.age_days and ('%.1f days'):format(i.age_days) or 'n/a'),
    ('cache dir:  %s'):format(i.cache_dir),
  }
  if i.last_error then
    lines[#lines + 1] = 'last error: ' .. i.last_error
  end
  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
end

M.subcommands = {
  search = function(o)
    M.search(table.concat(vim.list_slice(o.fargs, 2), ' '))
  end,
  sort = function(o)
    if o.range > 0 then
      M.sort(0, o.line1, o.line2)
    else
      M.sort(0)
    end
  end,
  update = function()
    M.update()
  end,
  info = function()
    M.info()
  end,
}

--- `:Scryvim {subcommand}` dispatcher.
function M.command(o)
  local sub = o.fargs[1]
  local fn = sub and M.subcommands[sub]
  if not fn then
    vim.notify('scryvim: usage: :Scryvim {search|sort|update|info}', vim.log.levels.ERROR)
    return
  end
  fn(o)
end

function M.complete(arglead, cmdline)
  if cmdline:match('^%S*%s+%S*$') then
    return vim.tbl_filter(function(s)
      return vim.startswith(s, arglead)
    end, vim.tbl_keys(M.subcommands))
  end
  return {}
end

return M
