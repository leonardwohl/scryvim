--- Pure: sort decklist lines by mana value. No Neovim state.
local parse = require('scryvim.parse')

local M = {}

local function is_land(card)
  local face = card.card_faces and card.card_faces[1]
  local type_line = (face and face.type_line) or card.type_line or ''
  return type_line:find('Land', 1, true) ~= nil
end

local function sort_block(block, lookup)
  local keyed = {}
  for i, entry in ipairs(block) do
    local card = lookup(entry.parsed.name)
    local group = not card and 3 or is_land(card) and 2 or 1
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

return M
