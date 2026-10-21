--- Count deck cards matching a Scryfall query.
---
--- The query runs on Scryfall, restricted to the deck's names:
--- `(<query>) (!"A" or !"B" ...)`. Results are matched back to deck entries
--- by full name, since `!"Lightning Bolt"` also finds cards with a face of
--- that name.
local http = require('scryvim.http')
local parse = require('scryvim.parse')

local M = {}

--- Scryfall silently truncates longer queries (measured: 1002 bytes worked,
--- 1039 did not), which surfaces as an "unclosed parentheses" error.
M.MAX_QUERY = 1000

--- `cache[query][lower full name] = matched`, for this session.
local cache = {}

--- Deck entries in `lines`, quantities summed per card. Without `all`,
--- Sideboard and Maybeboard sections and `SB:` lines are skipped.
---@param lines string[]
---@param lookup fun(name: string): table|nil
---@param all? boolean
---@return { name: string, count: integer }[]
function M.entries(lines, lookup, all)
  local out, byname, side = {}, {}, false
  for _, line in ipairs(lines) do
    local p = parse.parse(line)
    if p.kind == 'section' then
      side = parse.SIDE_SECTIONS[p.name:lower()] or false
    elseif p.kind == 'card' and (all or not (side or parse.is_sb(p))) then
      local card = lookup(p.name)
      local name = card and card.name or p.name
      local key = name:lower()
      local e = byname[key]
      if not e then
        e = { name = name, count = 0 }
        byname[key] = e
        out[#out + 1] = e
      end
      e.count = e.count + p.count
    end
  end
  return out
end

-- Scryfall doesn't take `\"` inside a quoted name (it warns and drops the
-- term), so a name with double quotes is single-quoted instead.
local function exact(name)
  if name:find('"', 1, true) and not name:find("'", 1, true) then
    return "!'" .. name .. "'"
  end
  return '!"' .. name:gsub('"', '\\"') .. '"'
end

--- Split `names` into queries of at most `M.MAX_QUERY` bytes.
---@param query string
---@param names string[]
---@return string[][]|nil batches, string|nil err
function M.batches(query, names)
  local head = '(' .. query .. ') ('
  local out, batch, len = {}, {}, #head + 1
  for _, name in ipairs(names) do
    local term = exact(name)
    local add = #term + (#batch > 0 and 4 or 0)
    if #batch > 0 and len + add > M.MAX_QUERY then
      out[#out + 1] = batch
      batch, len, add = {}, #head + 1, #term
    end
    if len + add > M.MAX_QUERY then
      return nil, ('query too long for Scryfall (limit %d characters)'):format(M.MAX_QUERY)
    end
    batch[#batch + 1] = name
    len = len + add
  end
  if #batch > 0 then
    out[#out + 1] = batch
  end
  return out
end

function M.build_query(query, names)
  local terms = {}
  for i, name in ipairs(names) do
    terms[i] = exact(name)
  end
  return '(' .. query .. ') (' .. table.concat(terms, ' or ') .. ')'
end

--- Count the cards in `entries` that match `query`. Matches are cached per
--- query and card, so a recount only asks Scryfall about new cards. A
--- query with terms Scryfall ignores (an unknown keyword) is an error.
--- `cb(err, result)` runs on the main loop.
---@param query string
---@param entries { name: string, count: integer }[]
---@param cb fun(err: string|nil, result: { total: integer, matches: { name: string, count: integer }[] }|nil)
function M.run(query, entries, cb)
  query = vim.trim(query)
  local known = cache[query] or {}
  cache[query] = known

  local function finish()
    local result = { total = 0, matches = {} }
    for _, e in ipairs(entries) do
      if known[e.name:lower()] then
        result.total = result.total + e.count
        result.matches[#result.matches + 1] = e
      end
    end
    cb(nil, result)
  end

  local unknown = {}
  for _, e in ipairs(entries) do
    if known[e.name:lower()] == nil then
      unknown[#unknown + 1] = e.name
    end
  end
  if #unknown == 0 then
    return vim.schedule(finish)
  end
  local batches, err = M.batches(query, unknown)
  if not batches then
    return vim.schedule(function()
      cb(err)
    end)
  end

  local pending, failed = #batches, nil
  for _, batch in ipairs(batches) do
    http.get_json(http.SEARCH_URL .. http.urlencode(M.build_query(query, batch)), function(gerr, obj)
      -- Scryfall drops terms it can't parse and warns; without them a typo
      -- like `prodces:r` would match the whole deck.
      local warnings = obj and type(obj.warnings) == 'table' and #obj.warnings > 0 and obj.warnings
      if gerr or warnings then
        -- "... was ignored" no longer holds: the count is refused instead.
        failed = failed or gerr or (table.concat(warnings, ' '):gsub(' was ignored%.', '.'))
      else
        -- At most a page's worth of cards per batch, so no paging.
        local found = {}
        for _, card in ipairs(obj.data or {}) do
          if type(card.name) == 'string' then
            found[card.name:lower()] = true
          end
          -- A deck line may name only the front face of a card that the
          -- store doesn't know yet.
          local face = card.card_faces and card.card_faces[1]
          if face and type(face.name) == 'string' then
            found[face.name:lower()] = true
          end
        end
        for _, name in ipairs(batch) do
          known[name:lower()] = found[name:lower()] or false
        end
      end
      pending = pending - 1
      if pending == 0 then
        if failed then
          return cb(failed)
        end
        finish()
      end
    end)
  end
end

function M._reset()
  cache = {}
end

return M
