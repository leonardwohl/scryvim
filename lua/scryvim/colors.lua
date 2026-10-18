--- Mana symbol colors: finding `{…}` symbols in text, their highlight
--- groups, and ANSI output for terminal previews.
local M = {}

M.COLORS = { 'white', 'blue', 'black', 'red', 'green', 'multicolor', 'colorless' }

local COLOR_NAMES = { W = 'white', U = 'blue', B = 'black', R = 'red', G = 'green' }

local function symbol_color(sym)
  local found
  for letter in sym:gmatch('[WUBRG]') do
    if found and found ~= letter then
      return 'multicolor'
    end
    found = letter
  end
  return found and COLOR_NAMES[found] or 'colorless'
end

--- Mana and other card symbols in `text`: `{ start, end, color }` with
--- 0-based, end-exclusive byte columns. Braces around anything that isn't a
--- card symbol (`{foo}`) are skipped.
---
--- A hybrid symbol is split in two at its first `/`, each half in its own
--- color: `{W/` white and `U}` blue, `{2/` colorless and `R}` red. A
--- Phyrexian `/P` takes the color of the rest (`{G/P}` is green).
---@param text string
---@return { [1]: integer, [2]: integer, [3]: string }[]
function M.symbols(text)
  local out = {}
  for s, sym, e in text:gmatch('(){([%dWUBRGCXYZSTQEPH/]+)}()') do
    local left, right = sym:match('^([^/]+)/(.+)$')
    if left and right ~= 'P' then
      local mid = s + #left + 1 -- just past the `/`
      out[#out + 1] = { s - 1, mid, symbol_color(left) }
      out[#out + 1] = { mid, e - 1, symbol_color(right) }
    else
      out[#out + 1] = { s - 1, e - 1, symbol_color(sym) }
    end
  end
  return out
end

--- Split text into `{ text, color }` chunks, one per `{…}` symbol. Text
--- between symbols (the ` // ` of split cards) has no color.
---@param cost string
---@return { [1]: string, [2]: string|nil }[]
function M.mana_chunks(cost)
  local chunks = {}
  local pos = 0
  for _, sym in ipairs(M.symbols(cost)) do
    if sym[1] > pos then
      chunks[#chunks + 1] = { cost:sub(pos + 1, sym[1]) }
    end
    chunks[#chunks + 1] = { cost:sub(sym[1] + 1, sym[2]), sym[3] }
    pos = sym[2]
  end
  if pos < #cost then
    chunks[#chunks + 1] = { cost:sub(pos + 1) }
  end
  return chunks
end

--- Highlight group for a color name: `ScryvimManaRed`, ...
function M.group(color)
  return 'ScryvimMana' .. color:sub(1, 1):upper() .. color:sub(2)
end

--- `{ text, hl_group }` segments for a line, as picker list formatters take.
---@param text string
---@return { [1]: string, [2]: string|nil }[]
function M.segments(text)
  return vim.tbl_map(function(chunk)
    return { chunk[1], chunk[2] and M.group(chunk[2]) }
  end, M.mana_chunks(text))
end

M.ns = vim.api.nvim_create_namespace('scryvim.colors')

--- Color every mana symbol in `buf`, replacing earlier highlights.
---@param buf integer
function M.highlight_buf(buf)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for _, sym in ipairs(M.symbols(line)) do
      vim.api.nvim_buf_set_extmark(buf, M.ns, row - 1, sym[1], { end_col = sym[2], hl_group = M.group(sym[3]) })
    end
  end
end

--- Color `buf` when it is an LSP float (hover) opened from a deck buffer.
---@param buf integer
function M.highlight_float(buf)
  local win = vim.fn.bufwinid(buf)
  local source = win ~= -1 and vim.w[win].lsp_floating_bufnr
  if source and vim.api.nvim_buf_is_valid(source) and vim.bo[source].filetype == 'deck' then
    M.highlight_buf(buf)
  end
end

--- Snacks-style extmarks (1-based rows) coloring the mana symbols in `text`.
---@param text string
---@return table[]
function M.extmarks(text)
  local out = {}
  for row, line in ipairs(vim.split(text, '\n', { plain = true })) do
    for _, sym in ipairs(M.symbols(line)) do
      out[#out + 1] = { row = row, col = sym[1], end_col = sym[2], hl_group = M.group(sym[3]) }
    end
  end
  return out
end

--- `text` with each mana symbol wrapped in a 24-bit ANSI color, for
--- previews that run in a terminal.
---@param text string
---@return string
function M.ansi(text)
  local out, pos = {}, 0
  for _, sym in ipairs(M.symbols(text)) do
    local fg = vim.api.nvim_get_hl(0, { name = M.group(sym[3]), link = false }).fg
    out[#out + 1] = text:sub(pos + 1, sym[1])
    local s = text:sub(sym[1] + 1, sym[2])
    if fg then
      s = ('\27[38;2;%d;%d;%dm%s\27[39m'):format(math.floor(fg / 65536), math.floor(fg / 256) % 256, fg % 256, s)
    end
    out[#out + 1] = s
    pos = sym[2]
  end
  out[#out + 1] = text:sub(pos + 1)
  return table.concat(out)
end

local PALETTE = {
  dark = {
    white = { '#f2e6b6', 229 },
    blue = { '#5aa9e6', 75 },
    black = { '#b48ead', 139 },
    red = { '#e5604f', 167 },
    green = { '#6cbf6c', 71 },
    multicolor = { '#e0b440', 178 },
    colorless = { '#a8a8a8', 248 },
  },
  light = {
    white = { '#9a7d1e', 136 },
    blue = { '#1f6fb5', 25 },
    black = { '#6b3d8f', 97 },
    red = { '#b8322a', 124 },
    green = { '#2e7d32', 28 },
    multicolor = { '#a67c00', 136 },
    colorless = { '#6e6e6e', 242 },
  },
}

-- Where each color comes from in the current colorscheme, best first: a
-- slot of the terminal palette (`g:terminal_color_N`, which is also the cterm
-- color number), or a highlight group's foreground. Terminal colors come
-- first: colorschemes set them to their own red, green, ..., while
-- many leave the diagnostic groups at Neovim's defaults.
local SOURCES = {
  white = { 'Normal' },
  blue = { 4, 'DiagnosticInfo' },
  black = { 5 },
  red = { 1, 'DiagnosticError' },
  green = { 2, 'DiagnosticOk' },
  multicolor = { 3, 'DiagnosticWarn' },
  colorless = { 8, 'Comment' },
}

local function from_source(src)
  if type(src) == 'number' then
    local hex = vim.g['terminal_color_' .. src]
    if type(hex) == 'string' and hex:match('^#%x%x%x%x%x%x$') then
      return hex, src
    end
    return nil, src
  end
  local hl = vim.api.nvim_get_hl(0, { name = src, link = false })
  return hl.fg and ('#%06x'):format(hl.fg), hl.ctermfg
end

--- `{ fg, ctermfg }` for a color: the first source the colorscheme defines,
--- else the built-in palette.
---@param color string
---@return { [1]: string, [2]: integer }
function M.theme_color(color)
  local fallback = (PALETTE[vim.o.background] or PALETTE.dark)[color]
  local fg, ctermfg
  for _, src in ipairs(SOURCES[color]) do
    local f, c = from_source(src)
    fg, ctermfg = fg or f, ctermfg or c
  end
  return { fg or fallback[1], ctermfg or fallback[2] }
end

--- Define the default highlight groups from the colorscheme. Existing
--- definitions win, so colorschemes and user config can override any of
--- them.
function M.setup_highlights()
  for _, color in ipairs(M.COLORS) do
    local c = M.theme_color(color)
    vim.api.nvim_set_hl(0, M.group(color), { default = true, fg = c[1], ctermfg = c[2] })
  end
  require('scryvim.types').setup_highlights()
end

return M
