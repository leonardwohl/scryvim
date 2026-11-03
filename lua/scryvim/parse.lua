--- Pure decklist line parser. No Neovim state.
local M = {}

--- Byte just past a sideboard marker (`SB:` or `Sideboard:`, any case) at
--- `pos`, or nil when there is none.
local function sb_marker(line, pos)
  local word, after = line:match('^(%a+):%s*()', pos)
  if word and (word:lower() == 'sb' or word:lower() == 'sideboard') then
    return after
  end
end

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
  pos = sb_marker(line, pos) or pos

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

local function trim(s)
  return s:match('^%s*(.-)%s*$')
end

--- A comment line, with `count` set for count lines: `'query'` (with
--- `query` and an optional `label`) for `// <label> (<query>)` or the older
--- `// count <label>: <query>`, `'mana'` for `// count mana symbols` and
--- `'cards'` for `// count cards`.
---
--- In the header form the query is the balanced parenthesized group that
--- ends the line, so it can hold parentheses of its own. It needs a
--- Scryfall operator (`:`, `=`, `<`, `>` or `!`), so a comment like
--- `// cut these (too slow)` stays a plain comment.
local function comment(rest)
  local label, q = nil, rest:match('^[Cc]ount:(.*)$')
  if not q then
    label, q = rest:match('^[Cc]ount%s([^:]*):(.*)$')
  end
  if not q then
    local l, group = rest:match('^(.-)%s*(%b())%s*$')
    if group and group:find('[:=<>!]') then
      label, q = l, group:sub(2, -2)
    end
  end
  q = q and trim(q)
  if q and q ~= '' then
    label = label and trim(label)
    return { kind = 'comment', count = 'query', query = q, label = label ~= '' and label or nil }
  end
  local words = trim(rest):lower()
  if words:match('^count%s+mana%s+symbols$') then
    return { kind = 'comment', count = 'mana' }
  elseif words:match('^count%s+cards$') then
    return { kind = 'comment', count = 'cards' }
  end
  return { kind = 'comment' }
end

--- Parse one decklist line into `card`, `section`, `comment` or `blank`.
--- Count lines are comments with a `count` field (see `comment` above).
---@param line string
---@return table
function M.parse(line)
  if line:match('^%s*$') then
    return { kind = 'blank' }
  end
  local rest = line:match('^%s*//%s*(.*)$') or line:match('^%s*#%s*(.*)$')
  if rest then
    return comment(rest)
  end
  local word = line:match('^%s*(%a+)%s*:?%s*$')
  if word and SECTIONS[word:lower()] then
    return { kind = 'section', name = word }
  end
  -- A bare `SB:` has no name; treat it as a section header.
  return M.card(line) or { kind = 'section', name = line:match('^%s*(.-)%s*$') }
end

--- Sections whose cards are outside the main deck.
M.SIDE_SECTIONS = { sideboard = true, maybeboard = true }

--- True for a card line marked `SB:` or `Sideboard:` (a sideboard card
--- outside a section).
---@param parsed table
---@return boolean
function M.is_sb(parsed)
  return parsed.kind == 'card' and sb_marker(parsed.prefix, parsed.prefix:match('^%s*()')) ~= nil
end

--- True for lines that separate sortable blocks.
function M.is_divider(parsed)
  return parsed.kind ~= 'card'
end

return M
