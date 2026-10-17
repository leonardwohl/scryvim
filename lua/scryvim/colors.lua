--- Card and mana colors: semantic token classification, mana symbol
--- highlighting and the default highlight groups.
local M = {}

--- Semantic token legend. Types are a card's color identity; the `land`
--- modifier marks lands so they can be styled separately.
M.TOKEN_TYPES = { 'white', 'blue', 'black', 'red', 'green', 'multicolor', 'colorless' }
M.TOKEN_MODIFIERS = { 'land' }

local TYPE_INDEX = {}
for i, t in ipairs(M.TOKEN_TYPES) do
  TYPE_INDEX[t] = i - 1
end

local COLOR_NAMES = { W = 'white', U = 'blue', B = 'black', R = 'red', G = 'green' }

--- Token type for a card's color identity, or nil when the card data has no
--- color identity (a cache built before it was recorded).
---@param card table
---@return string|nil
function M.identity(card)
  local ci = card.color_identity
  if type(ci) ~= 'table' then
    return nil
  end
  if #ci == 0 then
    return 'colorless'
  elseif #ci > 1 then
    return 'multicolor'
  end
  return COLOR_NAMES[ci[1]]
end

--- True when the card's front face is a land.
function M.is_land(card)
  local front = (card.type_line or ''):match('^(.-)%s*//') or card.type_line or ''
  return front:find('Land', 1, true) ~= nil
end

--- `{type, modifiers}` indices for a semantic token, or nil.
function M.token(card)
  local t = M.identity(card)
  if not t then
    return nil
  end
  return TYPE_INDEX[t], M.is_land(card) and 1 or 0
end

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

--- Split a mana cost into `{ text, color }` chunks, one per `{…}` symbol.
--- Text between symbols (the ` // ` of split cards) has no color.
---@param cost string
---@return { [1]: string, [2]: string|nil }[]
function M.mana_chunks(cost)
  local chunks = {}
  local pos = 1
  for s, sym, e in cost:gmatch('(){([^}]*)}()') do
    if s > pos then
      chunks[#chunks + 1] = { cost:sub(pos, s - 1) }
    end
    chunks[#chunks + 1] = { '{' .. sym .. '}', symbol_color(sym) }
    pos = e
  end
  if pos <= #cost then
    chunks[#chunks + 1] = { cost:sub(pos) }
  end
  return chunks
end

--- Highlight group for a color name: `ScryvimRed`, or `ScryvimManaRed` for
--- mana symbols.
function M.group(color, mana)
  return 'Scryvim' .. (mana and 'Mana' or '') .. color:sub(1, 1):upper() .. color:sub(2)
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

--- Define the default highlight groups. Existing definitions win, so
--- colorschemes and user config can override any of them.
function M.setup_highlights()
  local palette = PALETTE[vim.o.background] or PALETTE.dark
  local set = vim.api.nvim_set_hl
  for _, color in ipairs(M.TOKEN_TYPES) do
    local c = palette[color]
    set(0, M.group(color), { default = true, fg = c[1], ctermfg = c[2] })
    set(0, M.group(color, true), { default = true, link = M.group(color) })
    set(0, '@lsp.type.' .. color .. '.deck', { default = true, link = M.group(color) })
  end
end

return M
