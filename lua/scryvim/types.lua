--- Card types for coloring card names (semantic tokens).
local M = {}

--- Semantic token types, in priority order: a card with several types takes
--- the first one listed here.
M.TYPES = { 'land', 'creature', 'artifact', 'enchantment', 'planeswalker', 'battle', 'instant', 'sorcery' }

--- 0-based index of each type in the token legend, which is also its rank.
M.INDEX = {}
for i, t in ipairs(M.TYPES) do
  M.INDEX[t] = i - 1
end

--- Default links: groups every colorscheme styles, picked to give the
--- common types different colors.
M.LINKS = {
  land = 'String',
  creature = 'Type',
  artifact = 'Constant',
  enchantment = 'Function',
  planeswalker = 'Statement',
  battle = 'Special',
  instant = 'Identifier',
  sorcery = 'PreProc',
}

--- Highlight group for a type: `@lsp.type.creature.deck`. Scoped to the
--- deck filetype so other language servers' tokens are unaffected.
function M.group(t)
  return '@lsp.type.' .. t .. '.deck'
end

--- The card's type for coloring, from its front face, or nil when it has
--- none of `M.TYPES` (tokens, emblems).
---@param card table
---@return string|nil
function M.of(card)
  local face = card.card_faces and card.card_faces[1]
  local type_line = (face and face.type_line) or card.type_line or ''
  -- Supertypes and card types come before the dash; subtypes after.
  type_line = type_line:match('^(.-) //') or type_line
  type_line = type_line:match('^(.-) —') or type_line
  local best
  for word in type_line:lower():gmatch('%a+') do
    if M.INDEX[word] and (not best or M.INDEX[word] < M.INDEX[best]) then
      best = word
    end
  end
  return best
end

--- Define the default links. Existing definitions win.
function M.setup_highlights()
  for t, target in pairs(M.LINKS) do
    vim.api.nvim_set_hl(0, M.group(t), { default = true, link = target })
  end
end

return M
