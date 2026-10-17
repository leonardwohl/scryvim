--- Pure decklist line parser. No Neovim state.
local M = {}

local SECTIONS = {
  deck = true,
  sideboard = true,
  commander = true,
  companion = true,
  maybeboard = true,
}

--- Parse the card portion of a line.
---
--- Returns nil when there is no name, unless `allow_empty` is set (used by
--- completion while the user is still typing the name).
---
--- Byte ranges are 0-based and end-exclusive.
---@param line string
---@param allow_empty? boolean
---@return table|nil
function M.card(line, allow_empty)
  local pos = line:match('^%s*()')
  pos = line:match('^[Ss][Bb]:%s*()', pos) or pos

  local count, count_range
  local cs, digits, ce, after = line:match('^()(%d+)()[xX]?%s+()', pos)
  if cs then
    count = tonumber(digits)
    count_range = { cs - 1, ce - 1 }
    pos = after
  end

  -- Last non-whitespace byte of the line.
  local body_end = #(line:match('^(.-)%s*$'))
  local body = line:sub(1, body_end)
  local set_start = body:match('()%s+%([^()]*%).*$', pos) or body:match('()%s+%[[^%[%]]*%].*$', pos)
  local name_end = set_start and set_start - 1 or math.max(body_end, pos - 1)

  local name = line:sub(pos, name_end)
  if name == '' and not allow_empty then
    return nil
  end

  return {
    kind = 'card',
    count = count or 1,
    name = name,
    prefix = line:sub(1, pos - 1),
    suffix = line:sub(name_end + 1),
    has_set = set_start ~= nil,
    count_range = count_range,
    name_range = { pos - 1, name_end },
  }
end

--- Parse one decklist line into `card`, `section`, `comment` or `blank`.
---@param line string
---@return table
function M.parse(line)
  if line:match('^%s*$') then
    return { kind = 'blank' }
  end
  if line:match('^%s*//') or line:match('^%s*#') then
    return { kind = 'comment' }
  end
  local word = line:match('^%s*(%a+)%s*:?%s*$')
  if word and SECTIONS[word:lower()] then
    return { kind = 'section', name = word }
  end
  -- A bare `SB:` has no name; treat it as a section header.
  return M.card(line) or { kind = 'section', name = line:match('^%s*(.-)%s*$') }
end

--- True for lines that separate sortable blocks.
function M.is_divider(parsed)
  return parsed.kind ~= 'card'
end

return M
