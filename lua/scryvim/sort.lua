--- Pure: sort decklist lines by mana value. No Neovim state.
local curve = require('scryvim.curve')
local parse = require('scryvim.parse')

local M = {}

local function sort_block(block, lookup)
  local keyed = {}
  for i, entry in ipairs(block) do
    local card = lookup(entry.parsed.name)
    local group = not card and 3 or curve.is_land(card) and 2 or 1
    keyed[i] = {
      line = entry.line,
      group = group,
      cmc = card and card.cmc or 0,
      name = (card and card.name or entry.parsed.name):lower(),
      idx = i,
    }
  end
  table.sort(keyed, function(a, b)
    if a.group ~= b.group then
      return a.group < b.group
    end
    if a.group == 1 and a.cmc ~= b.cmc then
      return a.cmc < b.cmc
    end
    if a.group ~= 3 and a.name ~= b.name then
      return a.name < b.name
    end
    return a.idx < b.idx
  end)
  local out = {}
  for i, k in ipairs(keyed) do
    out[i] = k.line
  end
  return out
end

--- Sort each block of card lines independently; dividers stay in place.
---@param lines string[]
---@param lookup fun(name: string): table|nil
---@return string[]
function M.lines(lines, lookup)
  local out, block = {}, {}
  local function flush()
    for _, l in ipairs(sort_block(block, lookup)) do
      out[#out + 1] = l
    end
    block = {}
  end
  for _, line in ipairs(lines) do
    local parsed = parse.parse(line)
    if parse.is_divider(parsed) then
      flush()
      out[#out + 1] = line
    else
      block[#block + 1] = { line = line, parsed = parsed }
    end
  end
  flush()
  return out
end

--- 1-based inclusive bounds of the card block containing `row`, or nil if
--- `row` is a divider.
---@param lines string[]
---@param row integer
---@return integer|nil, integer|nil
function M.block_at(lines, row)
  local function is_card(i)
    return lines[i] ~= nil and not parse.is_divider(parse.parse(lines[i]))
  end
  if not is_card(row) then
    return nil
  end
  local first, last = row, row
  while is_card(first - 1) do
    first = first - 1
  end
  while is_card(last + 1) do
    last = last + 1
  end
  return first, last
end

--- Card lines below `row` that a count line at `row` gathers, as
--- `{ row = i, name = full name }`. A count line in the main deck takes
--- main-deck cards (not Sideboard, Maybeboard or `SB:` lines); one inside
--- a Sideboard or Maybeboard section takes cards from that section only.
---@param lines string[]
---@param row integer
---@param lookup fun(name: string): table|nil
---@return { row: integer, name: string }[]
function M.candidates(lines, row, lookup)
  local zones, zone, side = {}, 'main', false
  for i, line in ipairs(lines) do
    local p = parse.parse(line)
    if p.kind == 'section' then
      side = parse.SIDE_SECTIONS[p.name:lower()] or false
      zone = side and i or 'main'
    end
    if p.kind == 'card' then
      zones[i] = (not side and parse.is_sb(p)) and 'sb' or zone
    else
      zones[i] = zone
    end
  end
  local out = {}
  for i = row + 1, #lines do
    local p = parse.parse(lines[i])
    if p.kind == 'card' and zones[i] == zones[row] then
      local card = lookup(p.name)
      out[#out + 1] = { row = i, name = card and card.name or p.name }
    end
  end
  return out
end

--- Move the card lines at `rows` (all below `row`) into a block directly
--- under `row`, sorted by mana value. A blank line separates the block from
--- cards that were already under `row`. Returns the new lines `row + 1..`.
---@param lines string[]
---@param row integer
---@param rows integer[]
---@param lookup fun(name: string): table|nil
---@return string[]
function M.gather(lines, row, rows, lookup)
  local take = {}
  for _, r in ipairs(rows) do
    take[r] = true
  end
  local block, rest = {}, {}
  for i = row + 1, #lines do
    local list = take[i] and block or rest
    list[#list + 1] = lines[i]
  end
  for i, l in ipairs(block) do
    block[i] = { line = l, parsed = parse.parse(l) }
  end
  local out = sort_block(block, lookup)
  if #out > 0 and rest[1] and not parse.is_divider(parse.parse(rest[1])) then
    out[#out + 1] = ''
  end
  for _, l in ipairs(rest) do
    out[#out + 1] = l
  end
  return out
end

return M
