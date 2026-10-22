--- Nerd Font icons for mana symbols, with `icons` on: `{R}` shows as 󰈸.
---
--- Each part of a symbol between its slashes gets an icon: hybrid `{W/U}`
--- shows as 󰖨/󰖌 and Phyrexian `{R/P}` as 󰈸/Φ. A symbol with a part that has
--- no icon (`{T}`, `{HR}`) stays as text. Numbers and `{X}` lose their
--- braces: `{2}{R}` shows as `2 󰈸`.
---
--- Nerd Font icons are drawn wider than the one cell Neovim gives them, so
--- a symbol right before other text gets a space after it: `{1}{R}` shows as
--- `󰲠 󰈸`. Before a space or at the end, it needs none, and within a hybrid
--- symbol the icons stay against the slash.
---
--- Strings get the icons in their text. Buffers keep the `{R}` text and
--- conceal it with the icon, so the window needs a 'conceallevel' of 2.
local config = require('scryvim.config')

local M = {}

--- Material Design icons from Nerd Fonts 3. `true` shows the part as plain
--- text without its braces, which every number (`{1}`, `{15}`) and `{X}` do
--- by default: Nerd Font's circled numbers are drawn too small to read.
M.DEFAULTS = {
  W = '\u{f05a8}', -- nf-md-white_balance_sunny
  U = '\u{f058c}', -- nf-md-water
  B = '\u{f068c}', -- nf-md-skull
  R = '\u{f0238}', -- nf-md-fire
  G = '\u{f0531}', -- nf-md-tree
  C = '\u{f070c}', -- nf-md-rhombus_outline
  S = '\u{f0717}', -- nf-md-snowflake
  X = true,
  P = 'Φ',
}

M.ns = vim.api.nvim_create_namespace('scryvim.icons')

--- Icons by symbol part, or nil with `icons` off. A table in the config
--- overrides the defaults; `false` or `''` keeps that part as `{…}` text.
---@return table<string, string|false>|nil
function M.map()
  local opt = config.get().icons
  if opt == true then
    return M.DEFAULTS
  elseif type(opt) == 'table' then
    return vim.tbl_extend('force', M.DEFAULTS, opt)
  end
end

--- The parts of the symbols in `text` that become icons: `{ start, end,
--- icon, pad, plain }` with 0-based, end-exclusive byte columns, whether the
--- icon needs a space after it, and whether it is the part's own text. The first part takes the `{` and the last
--- the `}`; the slashes between stay.
---@param text string
---@param map? table<string, string|false> from `M.map()`
---@return { [1]: integer, [2]: integer, [3]: string, [4]: boolean, [5]: boolean }[]
function M.pieces(text, map)
  local out = {}
  if not map then
    return out
  end
  for s, sym in text:gmatch('(){([%dWUBRGCXYZSTQEPH/]+)}') do
    local parts = vim.split(sym, '/', { plain = true })
    local found = {}
    for i, part in ipairs(parts) do
      local icon = map[part]
      if icon == nil and part:match('^%d+$') then
        icon = true
      end
      if icon == true then
        icon = part
      end
      if not icon or icon == '' then
        found = nil
        break
      end
      found[i] = icon
    end
    if found then
      local col = s -- 0-based column of the first part, just past the `{`
      for i, part in ipairs(parts) do
        local stop = col + #part + (i == #parts and 1 or 0)
        -- Within a hybrid symbol the icons stay against the slashes.
        local pad = i == #parts and text:sub(stop + 1, stop + 1):match('^%S$') ~= nil
        out[#out + 1] = { i == 1 and col - 1 or col, stop, found[i], pad, found[i] == part }
        col = col + #part + 1
      end
    end
  end
  return out
end

--- `text` from byte `first` to `last` (0-based, end-exclusive; the whole
--- text by default), with the `pieces` inside it replaced by their icons.
---@param text string
---@param pieces { [1]: integer, [2]: integer, [3]: string }[]
---@param first? integer
---@param last? integer
---@return string
function M.apply(text, pieces, first, last)
  first, last = first or 0, last or #text
  local out, pos = {}, first
  for _, p in ipairs(pieces) do
    if p[1] >= first and p[2] <= last then
      out[#out + 1] = text:sub(pos + 1, p[1])
      out[#out + 1] = p[4] and p[3] .. ' ' or p[3]
      pos = p[2]
    end
  end
  out[#out + 1] = text:sub(pos + 1, last)
  return table.concat(out)
end

--- `text` with its mana symbols as icons, or unchanged with `icons` off.
---@param text string
---@return string
function M.replace(text)
  local map = M.map()
  return map and M.apply(text, M.pieces(text, map)) or text
end

--- Conceal the mana symbols in `buf` with their icons, from row `first`
--- (0-based) on, replacing earlier ones there. A concealed icon is drawn in
--- its extmark's highlight, not the text's, so with `color` each one gets
--- its mana color; without, it is drawn as |hl-Conceal|.
---@param buf integer
---@param first? integer
---@param color? boolean
function M.conceal_buf(buf, first, color)
  first = first or 0
  vim.api.nvim_buf_clear_namespace(buf, M.ns, first, -1)
  local map = M.map()
  if not map then
    return
  end
  local colors = color and require('scryvim.colors')
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, first, -1, false)) do
    local row = first + i - 1
    local syms = colors and colors.symbols(line) or {}
    local function conceal(s, e, char)
      local hl
      for _, sym in ipairs(syms) do
        if s >= sym[1] and s < sym[2] then
          hl = colors.group(sym[3])
        end
      end
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, s, { end_col = e, conceal = char, hl_group = hl })
    end
    for _, p in ipairs(M.pieces(line, map)) do
      if p[5] then
        -- Plain text: hide the braces, and pad in place of the `}`.
        if line:sub(p[1] + 1, p[1] + 1) == '{' then
          conceal(p[1], p[1] + 1, '')
        end
        if line:sub(p[2], p[2]) == '}' then
          conceal(p[2] - 1, p[2], p[4] and ' ' or '')
        end
      elseif p[4] and p[2] - p[1] >= 2 then
        -- Conceal takes one character, so the space conceals the next byte
        -- and the rest is hidden.
        conceal(p[1], p[1] + 1, p[3])
        conceal(p[1] + 1, p[1] + 2, ' ')
        if p[2] > p[1] + 2 then
          conceal(p[1] + 2, p[2], '')
        end
      else
        conceal(p[1], p[2], p[3])
      end
    end
  end
end

return M
