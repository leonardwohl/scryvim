--- Pure: count colored, colorless and snow mana symbols in mana costs.
---
--- Each symbol counts once for its type: `{R}` is 1 R. Generic mana (`{2}`,
--- `{X}`) doesn't count. A hybrid symbol splits its 1 between its halves,
--- so `{R/G}` is 0.5 R and 0.5 G, and `{2/R}` is 0.5 R, since its generic
--- half doesn't count. Phyrexian halves the rest: `{R/P}` is 0.5 R and
--- `{G/W/P}` is 0.25 G and 0.25 W. Half mana (`{HR}`) is 0.5.
local M = {}

--- Counted symbol types, in display order.
M.TYPES = { 'W', 'U', 'B', 'R', 'G', 'C', 'S' }

local COUNTED = { W = true, U = true, B = true, R = true, G = true, C = true, S = true }

--- Color names from `scryvim.colors`, for highlighting.
M.COLORS = {
  W = 'white',
  U = 'blue',
  B = 'black',
  R = 'red',
  G = 'green',
  C = 'colorless',
  S = 'colorless',
}

local function add_symbol(sym, out, n)
  local parts = vim.split(sym:upper(), '/', { plain = true })
  if #parts > 1 and parts[#parts] == 'P' then
    parts[#parts] = nil
    n = n / 2
  end
  local share = n / #parts
  for _, part in ipairs(parts) do
    local half = part:match('^H(.)$')
    local t, w = half or part, half and share / 2 or share
    if COUNTED[t] then
      out[t] = (out[t] or 0) + w
    end
  end
end

--- Add the symbols in `cost`, times `n`, to `out`.
---@param cost string|nil
---@param out? table<string, number>
---@param n? number
---@return table<string, number>
function M.cost(cost, out, n)
  out = out or {}
  for sym in (cost or ''):gmatch('{([^}]+)}') do
    add_symbol(sym, out, n or 1)
  end
  return out
end

--- Add the symbols in every mana cost of `card`, times `n`, to `out`. Cards
--- with more than one cost (split cards, adventures, modal double-faced
--- cards) count each.
---@param card table
---@param out? table<string, number>
---@param n? number
---@return table<string, number>
function M.card(card, out, n)
  out = out or {}
  local faces = false
  for _, face in ipairs(card.card_faces or {}) do
    if face.mana_cost and face.mana_cost ~= '' then
      faces = true
      M.cost(face.mana_cost, out, n)
    end
  end
  if not faces then
    M.cost(card.mana_cost, out, n)
  end
  return out
end

--- Totals over deck entries, by quantity. Unknown cards are skipped.
---@param entries { name: string, count: integer }[]
---@param lookup fun(name: string): table|nil
---@return table<string, number>
function M.entries(entries, lookup)
  local out = {}
  for _, e in ipairs(entries) do
    local card = lookup(e.name)
    if card then
      M.card(card, out, e.count)
    end
  end
  return out
end

--- `{ text, color }` chunks for totals: `{W} 3  {R} 12.5`. Types with no
--- symbols are left out.
---@param totals table<string, number>
---@return { [1]: string, [2]: string|nil }[]
function M.chunks(totals)
  local out = {}
  for _, t in ipairs(M.TYPES) do
    local v = totals[t]
    if v and v > 0 then
      if #out > 0 then
        out[#out + 1] = { '  ' }
      end
      out[#out + 1] = { '{' .. t .. '}', M.COLORS[t] }
      out[#out + 1] = { (' %g'):format(v) }
    end
  end
  if #out == 0 then
    out[1] = { 'no mana symbols' }
  end
  return out
end

--- Totals as plain text.
---@param totals table<string, number>
---@return string
function M.format(totals)
  return table.concat(vim.tbl_map(function(c)
    return c[1]
  end, M.chunks(totals)))
end

return M
