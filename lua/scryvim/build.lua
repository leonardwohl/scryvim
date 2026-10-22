--- Bulk Oracle Cards file -> stripped cards.json, and Scryfall's oracle tag
--- list -> tags.txt.
---
--- Runs as a child process: `nvim --clean -l build.lua [--tags] <in> <out>`.
--- Also required as a module for `strip()`. Must not require other scryvim
--- modules, since the child runs with `--clean`.
local M = {}

M.excluded_layouts = {
  token = true,
  double_faced_token = true,
  emblem = true,
  art_series = true,
  planar = true,
  scheme = true,
  vanguard = true,
}

local FIELDS = {
  'name',
  'oracle_id',
  'mana_cost',
  'cmc',
  'type_line',
  'oracle_text',
  'power',
  'toughness',
  'loyalty',
  'defense',
  'produced_mana',
  'scryfall_uri',
}

local FACE_FIELDS = {
  'name',
  'mana_cost',
  'type_line',
  'oracle_text',
  'power',
  'toughness',
  'loyalty',
  'defense',
}

local function pick(src, fields)
  local out = {}
  for _, f in ipairs(fields) do
    local v = src[f]
    if v ~= nil and v ~= vim.NIL then
      out[f] = v
    end
  end
  return out
end

--- Keep only the fields scryvim uses.
---@param card table Scryfall card object
---@return table
function M.strip(card)
  local out = pick(card, FIELDS)
  if type(card.card_faces) == 'table' then
    out.card_faces = {}
    for i, face in ipairs(card.card_faces) do
      out.card_faces[i] = pick(face, FACE_FIELDS)
    end
  end
  return out
end

function M.keep(card)
  return type(card) == 'table' and type(card.name) == 'string' and not M.excluded_layouts[card.layout]
end

local function is_gzip(path)
  local f = assert(io.open(path, 'rb'))
  local magic = f:read(2)
  f:close()
  return magic == '\31\139'
end

--- Accepts JSONL as well as Scryfall's one-object-per-line JSON array
--- (lines wrapped in `[`/`]` with trailing commas), gzipped or not.
---@param input string
---@param output string
---@return integer count
function M.run(input, output)
  local stream
  if is_gzip(input) then
    stream = assert(io.popen("gzip -dc '" .. input:gsub("'", "'\\''") .. "'", 'r'))
  else
    stream = assert(io.open(input, 'rb'))
  end
  local cards = {}
  for line in stream:lines() do
    line = line:gsub('^%s*%[?', ''):gsub(',?%]?%s*$', '')
    if line ~= '' then
      local card = vim.json.decode(line, { luanil = { object = true, array = true } })
      if M.keep(card) then
        cards[#cards + 1] = M.strip(card)
      end
    end
  end
  stream:close()
  if #cards == 0 then
    error('no cards parsed from ' .. input)
  end

  -- A JSON array with one card per line, so the loader can decode it in
  -- small chunks without blocking the editor.
  local lines = {}
  for i, card in ipairs(cards) do
    lines[i] = vim.json.encode(card)
  end
  local tmp = output .. '.tmp'
  local f = assert(io.open(tmp, 'wb'))
  f:write('[\n', table.concat(lines, ',\n'), '\n]\n')
  f:close()
  assert(os.rename(tmp, output))
  return #cards
end

--- Oracle tag list (`{ data = { { label, oracle_ids }, ... } }`) -> a
--- text file of oracle id per line, so a lookup is a plain string search
--- rather than decoding the whole list. The first line is a JSON header
--- with the labels, sorted; then `<oracle id>\t<label indices>` per card,
--- indices ascending and comma-separated.
---@param input string
---@param output string
---@return integer count cards with tags
function M.tags(input, output)
  local f = assert(io.open(input, 'rb'))
  local obj = vim.json.decode(f:read('*a'), { luanil = { object = true, array = true } })
  f:close()
  local list = type(obj) == 'table' and obj.data
  if type(list) ~= 'table' or #list == 0 then
    error('no tags parsed from ' .. input)
  end
  local tags = {}
  for _, tag in ipairs(list) do
    if type(tag) == 'table' and type(tag.label) == 'string' and type(tag.oracle_ids) == 'table' then
      tags[#tags + 1] = tag
    end
  end
  table.sort(tags, function(a, b)
    return a.label < b.label
  end)
  local labels, cards, ids = {}, {}, {}
  for i, tag in ipairs(tags) do
    labels[i] = tag.label
    for _, id in ipairs(tag.oracle_ids) do
      if type(id) == 'string' then
        if not cards[id] then
          cards[id] = {}
          ids[#ids + 1] = id
        end
        local c = cards[id]
        -- A tag that lists a card twice.
        if c[#c] ~= i then
          c[#c + 1] = i
        end
      end
    end
  end
  local lines = { vim.json.encode({ labels = labels }) }
  for _, id in ipairs(ids) do
    lines[#lines + 1] = id .. '\t' .. table.concat(cards[id], ',')
  end
  local tmp = output .. '.tmp'
  local out = assert(io.open(tmp, 'wb'))
  out:write(table.concat(lines, '\n'), '\n')
  out:close()
  assert(os.rename(tmp, output))
  return #ids
end

if (...) ~= 'scryvim.build' then
  local run, input, output = M.run, _G.arg[1], _G.arg[2]
  if input == '--tags' then
    run, input, output = M.tags, _G.arg[2], _G.arg[3]
  end
  local ok, err = pcall(run, input, output)
  if not ok then
    io.stderr:write(tostring(err) .. '\n')
    os.exit(1)
  end
  return
end

return M
