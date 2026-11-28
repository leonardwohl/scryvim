--- Count deck cards matching a Scryfall query.
---
--- The query runs on Scryfall, restricted to the deck's names:
--- `(<query>) (!"A" or !"B" ...)`. Results are matched back to deck entries
--- by full name, since `!"Lightning Bolt"` also finds cards with a face of
--- that name.
local config = require('scryvim.config')
local curve = require('scryvim.curve')
local data = require('scryvim.data')
local http = require('scryvim.http')
local parse = require('scryvim.parse')
local symbols = require('scryvim.symbols')

local M = {}

--- Scryfall silently truncates longer queries (measured: 1002 bytes worked,
--- 1039 did not), which surfaces as an "unclosed parentheses" error.
M.MAX_QUERY = 1000

--- `cache[query][lower full name] = matched`. Saved to `counts.json` in
--- the cache dir, and dropped when the card data changes.
local cache = {}

--- `bad[query] = err` for queries Scryfall warned about, which won't
--- improve on a resend. Not saved.
local bad = {}

--- `inflight[query][lower full name] = request` for names asked about and
--- not answered yet, so a recount waits on that answer instead of asking
--- again.
local inflight = {}

--- How long after new results they're written to disk.
M.SAVE_DELAY_MS = 1000

-- What `cache` was loaded for: the cache dir and the card data's
-- updated_at. Without card data on disk, nothing is saved.
local disk = { dir = nil, version = nil, timer = nil, dirty = false }

local function counts_path(dir)
  return dir .. '/counts.json'
end

local function read_disk(dir, version)
  local f = io.open(counts_path(dir), 'rb')
  if not f then
    return {}
  end
  local s = f:read('*a')
  f:close()
  local ok, obj = pcall(vim.json.decode, s)
  if not ok or type(obj) ~= 'table' or obj.version ~= version or type(obj.queries) ~= 'table' then
    return {}
  end
  return obj.queries
end

-- Copy answers from `from` into `into` that `into` doesn't have.
local function merge(into, from)
  for query, names in pairs(from) do
    if type(query) == 'string' and type(names) == 'table' then
      local known = into[query] or {}
      into[query] = known
      for name, matched in pairs(names) do
        if type(name) == 'string' and type(matched) == 'boolean' and known[name] == nil then
          known[name] = matched
        end
      end
    end
  end
end

--- Write the cache to disk now, merged with what other instances saved.
function M.save()
  if disk.timer then
    disk.timer:stop()
  end
  if not disk.dirty or not disk.version then
    return
  end
  disk.dirty = false
  merge(cache, read_disk(disk.dir, disk.version))
  vim.fn.mkdir(disk.dir, 'p')
  local path = counts_path(disk.dir)
  local tmp = ('%s.%d.tmp'):format(path, vim.fn.getpid())
  local f = io.open(tmp, 'wb')
  if not f then
    return
  end
  -- An empty table encodes as `[]`; fine, it decodes to an empty table.
  f:write(vim.json.encode({ version = disk.version, queries = cache }))
  f:close()
  os.rename(tmp, path)
end

local function save_later()
  if not disk.version then
    return
  end
  disk.dirty = true
  if not disk.timer then
    disk.timer = assert(vim.uv.new_timer())
    vim.api.nvim_create_autocmd('VimLeavePre', {
      group = vim.api.nvim_create_augroup('scryvim.count', { clear = true }),
      callback = M.save,
    })
  end
  disk.timer:stop()
  disk.timer:start(M.SAVE_DELAY_MS, 0, vim.schedule_wrap(M.save))
end

-- Point `cache` at the current cache dir and card data, loading what was
-- saved for them.
local function sync()
  local dir = config.get().cache_dir
  local meta = data.read_meta()
  local version = meta and type(meta.updated_at) == 'string' and meta.updated_at or nil
  if dir == disk.dir and version == disk.version then
    return
  end
  M.save()
  cache, bad = {}, {}
  disk.dir, disk.version, disk.dirty = dir, version, false
  if version then
    merge(cache, read_disk(dir, version))
  end
end

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

--- Totals for the deck `entries`: `cards` by quantity, `lands` and the
--- `mana` symbols by type. Without `lookup` (card data not loaded),
--- `lands` and `mana` are nil.
---@param entries { name: string, count: integer }[]
---@param lookup? fun(name: string): table|nil
---@return { cards: integer, lands: integer|nil, mana: table<string, number>|nil }
function M.stats(entries, lookup)
  local stats = { cards = 0, lands = lookup and 0 or nil }
  for _, e in ipairs(entries) do
    stats.cards = stats.cards + e.count
    local card = lookup and lookup(e.name)
    if card and curve.is_land(card) then
      stats.lands = stats.lands + e.count
    end
  end
  stats.mana = lookup and symbols.entries(entries, lookup) or nil
  return stats
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
--- query and card, so a recount only asks Scryfall about new cards, and a
--- card already being asked about is waited on, not asked again. With the
--- card data loaded, names it doesn't know (half-typed ones) count as no
--- match without asking. A query with terms Scryfall ignores (an unknown
--- keyword) is an error. `cb(err, result)` runs on the main loop.
---
--- With `opts.wanted`, requests still queued once it returns false (and
--- that no other count still wants) are dropped, and `cb` gets
--- `http.DROPPED`.
---@param query string
---@param entries { name: string, count: integer }[]
---@param cb fun(err: string|nil, result: { total: integer, matches: { name: string, count: integer }[] }|nil)
---@param opts? { wanted?: fun(): boolean }
function M.run(query, entries, cb, opts)
  query = vim.trim(query)
  sync()
  if bad[query] then
    local err = bad[query]
    return vim.schedule(function()
      cb(err)
    end)
  end
  local known = cache[query] or {}
  cache[query] = known
  local flying = inflight[query] or {}
  inflight[query] = flying
  local wanted = opts and opts.wanted or true
  local lookup = data.ready() and data.get or nil

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

  -- Requests already on the way that this count needs, and names to ask.
  local waits, seen, unknown = {}, {}, {}
  for _, e in ipairs(entries) do
    local key = e.name:lower()
    if known[key] == nil and not seen[key] and not (lookup and not lookup(e.name)) then
      seen[key] = true
      local req = flying[key]
      if req then
        if not waits[req] then
          waits[req] = true
          waits[#waits + 1] = req
          req.wanted[#req.wanted + 1] = wanted
        end
      else
        unknown[#unknown + 1] = e.name
      end
    end
  end
  if #unknown == 0 and #waits == 0 then
    return vim.schedule(finish)
  end
  local batches, err = M.batches(query, unknown)
  if not batches then
    return vim.schedule(function()
      cb(err)
    end)
  end

  local pending, failed = #waits + #batches, nil
  local function done(rerr)
    failed = failed or rerr
    pending = pending - 1
    if pending == 0 then
      if failed then
        return cb(failed)
      end
      finish()
    end
  end
  for _, req in ipairs(waits) do
    req.waiters[#req.waiters + 1] = done
  end

  for _, batch in ipairs(batches) do
    local req = { wanted = { wanted }, waiters = { done } }
    for _, name in ipairs(batch) do
      flying[name:lower()] = req
    end
    local function settle(rerr)
      for _, name in ipairs(batch) do
        if flying[name:lower()] == req then
          flying[name:lower()] = nil
        end
      end
      for _, w in ipairs(req.waiters) do
        w(rerr)
      end
    end
    http.get_json(http.SEARCH_URL .. http.urlencode(M.build_query(query, batch)), function(gerr, obj)
      -- Scryfall drops terms it can't parse and warns; without them a typo
      -- like `prodces:r` would match the whole deck.
      local warnings = obj and type(obj.warnings) == 'table' and #obj.warnings > 0 and obj.warnings
      if gerr then
        return settle(gerr)
      end
      if warnings then
        -- "... was ignored" no longer holds: the count is refused instead.
        local werr = table.concat(warnings, ' '):gsub(' was ignored%.', '.')
        bad[query] = werr
        return settle(werr)
      end
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
      save_later()
      settle(nil)
    end, {
      wanted = function()
        for _, w in ipairs(req.wanted) do
          if w == true or w() then
            return true
          end
        end
        return false
      end,
    })
  end
end

--- For tests: forget all answers, in memory only.
function M._reset()
  if disk.timer then
    disk.timer:stop()
  end
  cache, bad, inflight = {}, {}, {}
  disk.dir, disk.version, disk.dirty = nil, nil, false
end

return M
