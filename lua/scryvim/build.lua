--- Bulk Oracle Cards file -> stripped cards.json.
---
--- Runs as a child process: `nvim --clean -l build.lua <in> <out>`.
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
  'mana_cost',
  'cmc',
  'type_line',
  'oracle_text',
  'power',
  'toughness',
  'loyalty',
  'defense',
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

  local tmp = output .. '.tmp'
  local f = assert(io.open(tmp, 'wb'))
  f:write(vim.json.encode(cards))
  f:close()
  assert(os.rename(tmp, output))
  return #cards
end

if (...) ~= 'scryvim.build' then
  local input, output = _G.arg[1], _G.arg[2]
  local ok, err = pcall(M.run, input, output)
  if not ok then
    io.stderr:write(tostring(err) .. '\n')
    os.exit(1)
  end
  return
end

return M
