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

local function block(face, spacious)
  local out = {}
  local cost = nonempty(face.mana_cost)
  out[#out + 1] = '**' .. face.name .. '**' .. (cost and ('  ' .. cost) or '')
  if nonempty(face.type_line) then
    out[#out + 1] = '*' .. face.type_line .. '*'
  end
  if spacious then
    out[#out + 1] = ''
    out[#out + 1] = '---'
  end
  -- Compact: one line per ability, with no blank lines between, since
  -- previews show the markdown as written and every blank line costs a row.
  if nonempty(face.oracle_text) then
    if spacious then
      out[#out + 1] = ''
      -- Each ability is its own paragraph in markdown.
      out[#out + 1] = (face.oracle_text:gsub('\n', '\n\n'))
    else
      out[#out + 1] = face.oracle_text
    end
  end
  local stats
  if face.power or face.toughness then
    stats = (face.power or '?') .. '/' .. (face.toughness or '?')
  elseif face.loyalty then
    stats = 'Loyalty: ' .. face.loyalty
  elseif face.defense then
    stats = 'Defense: ' .. face.defense
  end
  if stats then
    if spacious then
      out[#out + 1] = ''
    end
    out[#out + 1] = stats
  end
  return table.concat(out, '\n')
end

-- Scryfall's format keys, in the order they are listed.
local FORMATS = {
  { 'standard', 'Standard' },
  { 'pioneer', 'Pioneer' },
  { 'modern', 'Modern' },
  { 'legacy', 'Legacy' },
  { 'vintage', 'Vintage' },
  { 'pauper', 'Pauper' },
  { 'commander', 'Commander' },
  { 'oathbreaker', 'Oathbreaker' },
  { 'paupercommander', 'Pauper Commander' },
  { 'duel', 'Duel Commander' },
  { 'predh', 'PreDH' },
  { 'brawl', 'Brawl' },
  { 'standardbrawl', 'Standard Brawl' },
  { 'historic', 'Historic' },
  { 'timeless', 'Timeless' },
  { 'alchemy', 'Alchemy' },
  { 'gladiator', 'Gladiator' },
  { 'penny', 'Penny Dreadful' },
  { 'premodern', 'Premodern' },
  { 'oldschool', 'Old School' },
  { 'future', 'Future' },
}

--- `**Banned** in Legacy, Modern · **Restricted** in Vintage`, then
--- `**Game Changer** in Commander` for cards on that list, or nil when
--- none of these apply.
---@param card table
---@return string?
function M.legality(card)
  local legalities = type(card.legalities) == 'table' and card.legalities or {}
  local known, by_status = {}, { banned = {}, restricted = {} }
  for _, f in ipairs(FORMATS) do
    known[f[1]] = true
    local list = by_status[legalities[f[1]]]
    if list then
      list[#list + 1] = f[2]
    end
  end
  -- Formats Scryfall adds later, by their key, after the known ones.
  local extra = {}
  for key in pairs(legalities) do
    if not known[key] then
      extra[#extra + 1] = key
    end
  end
  table.sort(extra)
  for _, key in ipairs(extra) do
    local list = by_status[legalities[key]]
    if list then
      list[#list + 1] = key
    end
  end
  local parts = {}
  for _, status in ipairs({ 'banned', 'restricted' }) do
    local list = by_status[status]
    if #list > 0 then
      parts[#parts + 1] = ('**%s** in %s'):format(status:gsub('^%l', string.upper), table.concat(list, ', '))
    end
  end
  if card.game_changer == true then
    parts[#parts + 1] = '**Game Changer** in Commander'
  end
  return #parts > 0 and table.concat(parts, ' · ') or nil
end

--- Hover and preview markdown. Multi-face cards get one block per face,
--- separated by a blank line. With `opts.spacious`, for the preview pane,
--- a rule follows the type line, abilities are separate paragraphs and
--- faces are divided by rules. Formats the card is banned or restricted
--- in follow on a line of their own.
---@param card table
---@param opts? { spacious: boolean }
---@return string
function M.markdown(card, opts)
  local spacious = opts and opts.spacious
  local blocks = {}
  if card.card_faces and #card.card_faces > 0 then
    for _, face in ipairs(card.card_faces) do
      blocks[#blocks + 1] = block(face, spacious)
    end
  else
    blocks[1] = block(card, spacious)
  end
  local md = table.concat(blocks, spacious and '\n\n---\n\n' or '\n\n')
  local legality = M.legality(card)
  if legality then
    md = md .. (spacious and '\n\n---\n\n' or '\n') .. legality
  end
  return md
end

--- `1 card`, `2 cards`: `n` and `word`, with an `s` unless `n` is 1.
---@param n integer
---@param word string
---@return string
function M.plural(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
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
