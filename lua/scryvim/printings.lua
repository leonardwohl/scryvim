--- Specific printings: card lines with a set code (`4 Lightning Bolt (M10)
--- 146`, `[M10]`) looked up on Scryfall for their image, and a picker that
--- sets a line's printing.
---
--- Lookups are saved to `printings.json` in the cache dir, so each printing
--- is asked about once. A printing Scryfall doesn't have is remembered for
--- the session only, so a fixed typo or a newly added printing is found.
local build = require('scryvim.build')
local config = require('scryvim.config')
local http = require('scryvim.http')
local parse = require('scryvim.parse')
local render = require('scryvim.render')

local M = {}

M.API = 'https://api.scryfall.com'

--- `printings[key] = { name, faces, image, scryfall_uri }`, loaded from disk
--- for `loaded_dir`.
local printings, loaded_dir = {}, nil

--- `missing[key] = true` for printings Scryfall said it doesn't have.
local missing = {}

local function path(dir)
  return dir .. '/printings.json'
end

local function read_disk(dir)
  local f = io.open(path(dir), 'rb')
  if not f then
    return {}
  end
  local s = f:read('*a')
  f:close()
  local ok, obj = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  return ok and type(obj) == 'table' and type(obj.printings) == 'table' and obj.printings or {}
end

local function sync()
  local dir = config.get().cache_dir
  if dir ~= loaded_dir then
    loaded_dir, printings, missing = dir, read_disk(dir), {}
  end
  return dir
end

local function save()
  local dir = sync()
  -- Keep what other instances saved meanwhile.
  for k, v in pairs(read_disk(dir)) do
    if printings[k] == nil and type(v) == 'table' then
      printings[k] = v
    end
  end
  vim.fn.mkdir(dir, 'p')
  local tmp = ('%s.%d.tmp'):format(path(dir), vim.fn.getpid())
  local f = io.open(tmp, 'wb')
  if not f then
    return
  end
  f:write(vim.json.encode({ printings = printings }))
  f:close()
  os.rename(tmp, path(dir))
end

--- The lookup key for a set code and collector number, or a set code and
--- card name when the line has no number.
---@param set string
---@param number string|nil
---@param name string
---@return string
function M.key(set, number, name)
  return number and (set:lower() .. '/' .. number) or (set:lower() .. '//' .. name:lower())
end

--- The Scryfall API URL for a printing.
function M.url(set, number, name)
  if number then
    return ('%s/cards/%s/%s'):format(M.API, http.urlencode(set:lower()), http.urlencode(number))
  end
  return ('%s/cards/named?exact=%s&set=%s'):format(M.API, http.urlencode(name), http.urlencode(set:lower()))
end

-- What the page needs from a Scryfall card object.
local function keep(obj)
  local card = build.strip(obj)
  local faces = {}
  for i, face in ipairs(card.card_faces or {}) do
    faces[i] = face.name
  end
  local front = card.card_faces and card.card_faces[1]
  return {
    name = card.name,
    faces = #faces > 0 and faces or nil,
    image = card.image or (front and front.image),
    scryfall_uri = type(card.scryfall_uri) == 'string' and card.scryfall_uri:match('^[^?#]+') or nil,
  }
end

--- True when `printing` is a printing of the card named `name` (its full
--- name or a face's).
---@param printing table
---@param name string
---@return boolean
function M.matches(printing, name)
  local n = name:lower()
  if printing.name:lower() == n then
    return true
  end
  for _, face in ipairs(printing.faces or {}) do
    if face:lower() == n then
      return true
    end
  end
  return false
end

--- The printings on card lines in `lines`: `{ key, set, number, name }`,
--- each once.
---@param lines string[]
---@return table[]
function M.wanted(lines)
  local out, seen = {}, {}
  for _, line in ipairs(lines) do
    local p = parse.parse(line)
    if p.kind == 'card' and p.set then
      local key = M.key(p.set, p.number, p.name)
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = { key = key, set = p.set, number = p.number, name = p.name }
      end
    end
  end
  return out
end

--- The saved printing for `key`, or nil.
---@param key string
---@return table|nil
function M.get(key)
  sync()
  return printings[key]
end

--- Look up the `wanted` printings that aren't known yet. `cb(problems)`
--- runs on the main loop once all are answered; each problem is
--- `{ key, missing = true }` for a printing Scryfall doesn't have, or
--- `{ key, err }` for a request that failed.
---@param wanted table[]
---@param cb fun(problems: table[])
function M.resolve(wanted, cb)
  sync()
  local problems, pending, added = {}, 0, false
  local function done()
    if added then
      save()
    end
    table.sort(problems, function(a, b)
      return a.key < b.key
    end)
    cb(problems)
  end
  for _, w in ipairs(wanted) do
    if missing[w.key] then
      problems[#problems + 1] = { key = w.key, missing = true }
    elseif not printings[w.key] then
      pending = pending + 1
      http.get_json(M.url(w.set, w.number, w.name), function(err, obj)
        -- Scryfall answers an unknown collector number with a 404 and an
        -- unknown set code with an HTML 400.
        if
          err and (err:find('not_found', 1, true) or err:find('%(HTTP 40[04]%)$') or err:find('bad_request', 1, true))
        then
          missing[w.key] = true
          problems[#problems + 1] = { key = w.key, missing = true }
        elseif err then
          problems[#problems + 1] = { key = w.key, err = err }
        elseif type(obj) == 'table' and obj.object == 'card' then
          printings[w.key] = keep(obj)
          added = true
        else
          problems[#problems + 1] = { key = w.key, err = 'unexpected response' }
        end
        pending = pending - 1
        if pending == 0 then
          done()
        end
      end)
    end
  end
  if pending == 0 then
    vim.schedule(done)
  end
end

--- Test helper: forget lookups.
function M._reset()
  printings, loaded_dir, missing = {}, nil, {}
end

-- Picker ---------------------------------------------------------------------

--- `(M10) 146` for a printing.
local function code(card)
  return ('(%s) %s'):format(card.set:upper(), card.collector_number)
end

--- One picker line: set code and number, set name, release date.
---@param card table
---@param current? string the line's key, marked with `*`
function M.format_item(card, current)
  local mark = current and M.key(card.set, card.collector_number, card.name) == current and '*' or ' '
  return ('%s %-16s %-40s %s'):format(mark, code(card), card.set_name or '', card.released_at or '')
end

--- `line` with its printing set to `card`'s, keeping the count, `SB:` and
--- anything after an old set code and number (such as `*F*`).
---@param line string
---@param card table
---@return string
function M.set_line(line, card)
  local p = assert(parse.card(line))
  local head = line:sub(1, p.name_range[2])
  local suffix = line:sub(p.name_range[2] + 1)
  local rest = suffix
  if p.set then
    rest = suffix:gsub('^%s+[%(%[][^%)%]]*[%)%]]', '', 1)
    if p.number then
      rest = rest:gsub('^%s+[^%s%*]+', '', 1)
    end
  end
  return head .. ' ' .. code(card) .. (rest:gsub('%s+$', ''))
end

-- Extra fields a printing needs in the picker.
local function strip_printing(obj)
  local card = build.strip(obj)
  card.set = obj.set
  card.set_name = obj.set_name
  card.collector_number = obj.collector_number
  card.released_at = obj.released_at
  card.rarity = obj.rarity
  return card
end

--- `:Scryvim printing`: pick a printing of the card on line `row` (1-based)
--- of `bufnr`, newest first, and set the line to it.
---@param bufnr integer
---@param row integer
function M.pick(bufnr, row)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  local p = parse.parse(line)
  if p.kind ~= 'card' then
    vim.notify('scryvim: no card on this line', vim.log.levels.WARN)
    return
  end
  local data = require('scryvim.data')
  local known = data.ready() and data.get(p.name)
  local name = known and known.name or p.name
  local current = p.set and M.key(p.set, p.number, p.name)
  local picker = require('scryvim.picker')
  local cfg = config.get()
  local query = ('!"%s" unique:prints order:released direction:desc'):format((name:gsub('"', '\\"')))
  vim.notify('scryvim: finding printings of ' .. name .. '…', vim.log.levels.INFO)
  picker.fetch(query, cfg.search.max_pages, function(err, cards)
    if err then
      vim.notify('scryvim: printings: ' .. err, vim.log.levels.WARN)
      return
    end
    if #cards == 0 then
      vim.notify('scryvim: no printings of ' .. name, vim.log.levels.INFO)
      return
    end
    local adapter = picker.adapter(cfg.picker)
    adapter.pick(cards, {
      prompt = 'Printings: ' .. name,
      color = cfg.colors,
      format_item = function(card)
        return M.format_item(card, current)
      end,
      ordinal = function(card)
        return M.format_item(card)
      end,
      preview = function(card)
        local info = ('**%s** %s · %s%s'):format(
          code(card),
          card.set_name or '',
          card.released_at or '',
          card.rarity and (' · ' .. card.rarity) or ''
        )
        return info .. '\n\n' .. render.markdown(card)
      end,
      on_choose = function(chosen)
        local card = chosen[1]
        if not card or not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        -- The line may have moved or changed while the picker was open.
        local now = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
        if now ~= line then
          vim.notify('scryvim: the line changed; run :Scryvim printing again', vim.log.levels.WARN)
          return
        end
        vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { M.set_line(line, card) })
      end,
    })
  end, nil, strip_printing)
end

return M
