--- Pure: card -> display strings (hover markdown, completion detail).
local M = {}

local function nonempty(s)
  return s ~= nil and s ~= '' and s or nil
end

--- Top-level mana cost, falling back to the front face.
function M.mana_cost(card)
  local face = card.card_faces and card.card_faces[1]
  return nonempty(card.mana_cost) or (face and nonempty(face.mana_cost)) or nil
end

local function block(face)
  local out = {}
  local cost = nonempty(face.mana_cost)
  out[#out + 1] = '**' .. face.name .. '**' .. (cost and ('  ' .. cost) or '')
  if nonempty(face.type_line) then
    out[#out + 1] = '*' .. face.type_line .. '*'
  end
  -- One line per ability, with no blank lines between: previews show the
  -- markdown as written, so every blank line costs a row.
  if nonempty(face.oracle_text) then
    out[#out + 1] = face.oracle_text
  end
  local stats
  if face.power or face.toughness then
    stats = 'P/T: ' .. (face.power or '?') .. '/' .. (face.toughness or '?')
  elseif face.loyalty then
    stats = 'Loyalty: ' .. face.loyalty
  elseif face.defense then
    stats = 'Defense: ' .. face.defense
  end
  if stats then
    out[#out + 1] = stats
  end
  return table.concat(out, '\n')
end

--- Hover and preview markdown. Multi-face cards get one block per face,
--- separated by a blank line.
---@param card table
---@return string
function M.markdown(card)
  local blocks = {}
  if card.card_faces and #card.card_faces > 0 then
    for _, face in ipairs(card.card_faces) do
      blocks[#blocks + 1] = block(face)
    end
  else
    blocks[1] = block(card)
  end
  return table.concat(blocks, '\n\n')
end

--- `<mana_cost> · <type_line>`, omitting empty parts.
function M.detail(card)
  local cost = M.mana_cost(card)
  local type_line = nonempty(card.type_line)
  if cost and type_line then
    return cost .. ' · ' .. type_line
  end
  return cost or type_line or ''
end

return M
