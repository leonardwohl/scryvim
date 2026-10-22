--- Deck stats for the statusline and winbar: the deck's size and its mana
--- symbols by type, such as `60 cards  {W} 12  {R} 23.5`. Like the count
--- lines, they leave out the sideboard and maybeboard, but need no line in
--- the deck.
---
--- `%{%v:lua.require'scryvim'.statusline()%}` in 'statusline' or 'winbar'
--- shows them; `lua/lualine/components/scryvim.lua` is the lualine
--- component.
local colors = require('scryvim.colors')
local config = require('scryvim.config')
local count = require('scryvim.count')
local data = require('scryvim.data')
local render = require('scryvim.render')
local symbols = require('scryvim.symbols')

local M = {}

--- Options for `M.chunks()`: what to show.
M.DEFAULTS = { cards = true, lands = false, mana = true }

-- Buffer -> { tick, ready, stats }, so redraws don't reparse the deck.
local cache = {}
local subscribed = false

local function subscribe()
  if subscribed then
    return
  end
  subscribed = true
  -- Typed names become full card names and mana costs once the store
  -- loads, and nothing else redraws the bars then.
  data.on_ready(function()
    cache = {}
    vim.cmd.redrawstatus({ bang = true })
  end)
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    group = vim.api.nvim_create_augroup('scryvim.statusline', { clear = true }),
    callback = function(args)
      cache[args.buf] = nil
    end,
  })
end

--- Stats for the deck in `buf`, or nil when it isn't a deck. `lands` and
--- `mana` are nil until the card data is loaded, since they need it.
---@param buf integer
---@return { cards: integer, lands: integer|nil, mana: table<string, number>|nil }|nil
function M.stats(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= 'deck' then
    return nil
  end
  subscribe()
  local tick, ready = vim.api.nvim_buf_get_changedtick(buf), data.ready()
  local hit = cache[buf]
  if hit and hit.tick == tick and hit.ready == ready then
    return hit.stats
  end
  local entries = count.entries(vim.api.nvim_buf_get_lines(buf, 0, -1, false), data.get)
  local stats = count.stats(entries, ready and data.get or nil)
  cache[buf] = { tick = tick, ready = ready, stats = stats }
  return stats
end

--- `{ text, color }` chunks for the deck in `buf`, with the mana symbols'
--- color names (`'red'`), or `{}` when it isn't a deck or has no cards.
---@param buf integer
---@param opts? { cards?: boolean, lands?: boolean, mana?: boolean }
---@return { [1]: string, [2]: string|nil }[]
function M.chunks(buf, opts)
  opts = vim.tbl_extend('force', M.DEFAULTS, opts or {})
  local stats = M.stats(buf)
  if not stats or stats.cards == 0 then
    return {}
  end
  local out = {}
  local function add(chunk)
    if #out > 0 then
      out[#out + 1] = { '  ' }
    end
    out[#out + 1] = chunk
  end
  if opts.cards then
    add({ render.plural(stats.cards, 'card') })
  end
  if opts.lands and stats.lands then
    add({ render.plural(stats.lands, 'land') })
  end
  if opts.mana and stats.mana and next(stats.mana) then
    for i, chunk in ipairs(colors.mana_chunks(symbols.format(stats.mana))) do
      if i == 1 then
        add(chunk)
      else
        out[#out + 1] = chunk
      end
    end
  end
  return out
end

--- Plain text for the deck in `buf`: `60 cards  {W} 12  {R} 23.5`.
---@param buf? integer
---@param opts? { cards?: boolean, lands?: boolean, mana?: boolean }
---@return string
function M.text(buf, opts)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return table.concat(vim.tbl_map(function(c)
    return c[1]
  end, M.chunks(buf, opts)))
end

--- Statusline text for the window being drawn, mana symbols in their colors
--- with `colors` on. For a `%{% %}` item in 'statusline' or 'winbar'.
---@param opts? { cards?: boolean, lands?: boolean, mana?: boolean }
---@return string
function M.statusline(opts)
  local win = vim.g.statusline_winid
  local buf = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) or vim.api.nvim_get_current_buf()
  local color = config.get().colors
  local out = {}
  for _, c in ipairs(M.chunks(buf, opts)) do
    local text = c[1]:gsub('%%', '%%%%')
    out[#out + 1] = c[2] and color and ('%#' .. colors.group(c[2]) .. '#' .. text .. '%*') or text
  end
  return table.concat(out)
end

function M._reset()
  cache = {}
end

return M
