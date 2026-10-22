--- Public API. Heavy modules are required lazily.
local config = require('scryvim.config')

local M = {}

-- `nil` or 0 is the current buffer.
local function buf(b)
  return (b == nil or b == 0) and vim.api.nvim_get_current_buf() or b
end

-- The command's line range, or nothing without one.
local function range(o)
  if o.range > 0 then
    return o.line1, o.line2
  end
end

-- Start loading the card data; warn and return false when it isn't there.
local function ready()
  local data = require('scryvim.data')
  data.ensure()
  if not data.ready() then
    vim.notify('scryvim: card data is not loaded yet', vim.log.levels.WARN)
    return false
  end
  return true
end

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
--- range, sorts the block under the cursor, or on a count line gathers
--- its matching cards under it.
---@param bufnr? integer
---@param first? integer
---@param last? integer
function M.sort(bufnr, first, last)
  bufnr = buf(bufnr)
  local data = require('scryvim.data')
  local sort = require('scryvim.sort')
  if not ready() then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if not first then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local parsed = require('scryvim.parse').parse(lines[row])
    if parsed.count == 'query' then
      return M.gather(bufnr, row, parsed.query, lines)
    end
    first, last = sort.block_at(lines, row)
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

--- Move the cards below the count line at `row` that match `query` into a
--- block directly under it, sorted by mana value. Cards above stay put.
---@param bufnr integer
---@param row integer
---@param query string
---@param lines string[]
function M.gather(bufnr, row, query, lines)
  local data = require('scryvim.data')
  local sort = require('scryvim.sort')
  local candidates = sort.candidates(lines, row, data.get)
  if #candidates == 0 then
    return
  end
  local entries, seen = {}, {}
  for _, c in ipairs(candidates) do
    if not seen[c.name:lower()] then
      seen[c.name:lower()] = true
      entries[#entries + 1] = { name = c.name, count = 1 }
    end
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  require('scryvim.count').run(query, entries, function(err, result)
    if err then
      vim.notify('scryvim: ' .. err, vim.log.levels.ERROR)
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
      vim.notify('scryvim: buffer changed while sorting; run sort again', vim.log.levels.WARN)
      return
    end
    local matched = {}
    for _, e in ipairs(result.matches) do
      matched[e.name:lower()] = true
    end
    local rows = {}
    for _, c in ipairs(candidates) do
      if matched[c.name:lower()] then
        rows[#rows + 1] = c.row
      end
    end
    local tail = vim.list_slice(lines, row + 1)
    local gathered = sort.gather(lines, row, rows, data.get)
    if not vim.deep_equal(tail, gathered) then
      vim.api.nvim_buf_set_lines(bufnr, row, -1, false, gathered)
    end
  end)
end

--- Count deck cards matching the Scryfall `query`, by quantity. Counts
--- lines `first..last` (1-based, inclusive) when given, otherwise the whole
--- buffer without Sideboard and Maybeboard.
---@param query string
---@param bufnr? integer
---@param first? integer
---@param last? integer
function M.count(query, bufnr, first, last)
  query = vim.trim(query or '')
  if query == '' then
    vim.notify('scryvim: usage: :Scryvim count {query}', vim.log.levels.ERROR)
    return
  end
  bufnr = buf(bufnr)
  local data = require('scryvim.data')
  local count = require('scryvim.count')
  data.ensure()
  local lines = vim.api.nvim_buf_get_lines(bufnr, first and first - 1 or 0, last or -1, false)
  local entries = count.entries(lines, data.get, first ~= nil)
  if #entries == 0 then
    vim.notify('scryvim: no cards to count', vim.log.levels.WARN)
    return
  end
  count.run(query, entries, function(err, result)
    if err then
      vim.notify('scryvim: ' .. err, vim.log.levels.ERROR)
      return
    end
    table.sort(result.matches, function(a, b)
      if a.count ~= b.count then
        return a.count > b.count
      end
      return a.name < b.name
    end)
    local out = { ('%d %s match %s'):format(result.total, result.total == 1 and 'card' or 'cards', query) }
    for _, e in ipairs(result.matches) do
      out[#out + 1] = ('%4d %s'):format(e.count, e.name)
    end
    vim.notify(table.concat(out, '\n'), vim.log.levels.INFO)
  end)
end

--- Count the mana symbols in the deck's mana costs, by type and quantity.
--- Lines `first..last` (1-based, inclusive) when given, otherwise the whole
--- buffer without Sideboard and Maybeboard.
---@param bufnr? integer
---@param first? integer
---@param last? integer
function M.mana(bufnr, first, last)
  bufnr = buf(bufnr)
  local data = require('scryvim.data')
  local count = require('scryvim.count')
  local symbols = require('scryvim.symbols')
  if not ready() then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, first and first - 1 or 0, last or -1, false)
  local entries = count.entries(lines, data.get, first ~= nil)
  if #entries == 0 then
    vim.notify('scryvim: no cards to count', vim.log.levels.WARN)
    return
  end
  vim.notify('Mana symbols: ' .. symbols.format(count.stats(entries, data.get).mana), vim.log.levels.INFO)
end

--- Deck stats for 'statusline' and 'winbar': the deck's size and mana
--- symbols, as `%{%v:lua.require'scryvim'.statusline()%}`.
---@param opts? { cards?: boolean, lands?: boolean, mana?: boolean }
---@return string
function M.statusline(opts)
  return require('scryvim.statusline').statusline(opts)
end

--- Toggle the preview pane on the right of the current tab.
function M.pane()
  require('scryvim.pane').toggle()
end

--- Force a card data refresh, and an oracle tags one.
function M.update()
  require('scryvim.data').update({ force = true, announce = true })
  if require('scryvim.config').get().pane.tags then
    require('scryvim.tags').update()
  end
end

function M.info()
  local i = require('scryvim.data').info()
  local lines = {
    ('cards:      %d%s'):format(i.count, i.stage and (' (' .. i.stage .. ')') or ''),
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
    M.sort(0, range(o))
  end,
  count = function(o)
    M.count(table.concat(vim.list_slice(o.fargs, 2), ' '), 0, range(o))
  end,
  mana = function(o)
    M.mana(0, range(o))
  end,
  pane = function()
    M.pane()
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
    vim.notify('scryvim: usage: :Scryvim {search|sort|count|mana|pane|update|info}', vim.log.levels.ERROR)
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
