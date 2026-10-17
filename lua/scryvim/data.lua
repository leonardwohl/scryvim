--- Card store. The only module that knows the cache format.
local config = require('scryvim.config')
local http = require('scryvim.http')

local M = {}

M.BULK_URL = 'https://api.scryfall.com/bulk-data/oracle-cards'

local BUILD_SCRIPT = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), 'build.lua')

local state = {
  byname = {},
  lower_names = {},
  count = 0,
  loaded = false,
  started = false,
  updating = false,
  waiters = {},
  last_error = nil,
  subscribers = {},
  stage = nil,
  progress_subscribers = {},
}

local function notify(msg, level)
  vim.notify('scryvim: ' .. msg, level or vim.log.levels.INFO)
end

function M.paths()
  local dir = config.get().cache_dir
  return {
    dir = dir,
    cards = dir .. '/cards.json',
    meta = dir .. '/meta.json',
    bulk = dir .. '/oracle-cards.jsonl.gz',
  }
end

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local s = f:read('*a')
  f:close()
  return s
end

local function write_atomic(path, s)
  local tmp = path .. '.tmp'
  local f, err = io.open(tmp, 'wb')
  if not f then
    return nil, err
  end
  f:write(s)
  f:close()
  return os.rename(tmp, path)
end

function M.read_meta()
  local s = read_file(M.paths().meta)
  local ok, meta = pcall(vim.json.decode, s or '')
  return ok and type(meta) == 'table' and meta or nil
end

local function write_meta(meta)
  return write_atomic(M.paths().meta, vim.json.encode(meta))
end

local JSON_OPTS = { luanil = { object = true, array = true } }

--- Accumulates cards into a new index; `finish()` swaps it in.
local function indexer()
  local byname, from_face, lower_names = {}, {}, {}
  local self = {}

  function self.add(card)
    if type(card) ~= 'table' or type(card.name) ~= 'string' then
      return
    end
    local key = card.name:lower()
    -- A card's own name wins over another card's front-face name.
    if not byname[key] or from_face[key] then
      lower_names[#lower_names + 1] = key
      byname[key], from_face[key] = card, nil
    end
    local face = card.card_faces and card.card_faces[1]
    if face and face.name then
      local fkey = face.name:lower()
      if not byname[fkey] then
        byname[fkey], from_face[fkey] = card, true
      end
    end
  end

  function self.finish()
    table.sort(lower_names)
    state.byname, state.lower_names = byname, lower_names
    state.count = #lower_names
    state.loaded = true
    for _, fn in pairs(state.subscribers) do
      pcall(fn)
    end
  end

  return self
end

--- Replace the in-memory store with `cards`.
---@param cards table[]
function M.index(cards)
  local ix = indexer()
  for _, card in ipairs(cards) do
    ix.add(card)
  end
  ix.finish()
end

--- Load a stripped cards.json file into the store, blocking until done.
---@return boolean ok, string|nil err
function M.load_file(path)
  local s = read_file(path)
  if not s then
    return false, 'cannot read ' .. path
  end
  local ok, cards = pcall(vim.json.decode, s, JSON_OPTS)
  if not ok or type(cards) ~= 'table' then
    return false, 'invalid card cache ' .. path
  end
  M.index(cards)
  return true
end

M.LOAD_SLICE_MS = 8

local load_generation = 0

--- Load cards.json without blocking: decode a slice of lines per event-loop
--- turn. The current store stays in use until the new one is complete.
--- `cb(err)` runs on the main loop.
---@param path string
---@param cb? fun(err: string|nil)
function M.load_file_async(path, cb)
  cb = cb or function() end
  load_generation = load_generation + 1
  local generation = load_generation
  local s = read_file(path)
  if not s then
    return vim.schedule(function()
      cb('cannot read ' .. path)
    end)
  end
  if s:sub(1, 2) ~= '[\n' then
    -- Not one card per line (written by an older version): decode in one go.
    return vim.schedule(function()
      local ok, err = M.load_file(path)
      cb(not ok and err or nil)
    end)
  end
  local ix = indexer()
  local pos = 3
  local function step()
    -- A newer load replaced this one; it reports instead.
    if generation ~= load_generation then
      return
    end
    local deadline = vim.uv.hrtime() + M.LOAD_SLICE_MS * 1e6
    repeat
      local e = s:find('\n', pos, true)
      if not e then
        ix.finish()
        return cb(nil)
      end
      local line = s:sub(pos, e - 1)
      pos = e + 1
      if line ~= ']' and line ~= '' then
        if line:sub(-1) == ',' then
          line = line:sub(1, -2)
        end
        local ok, card = pcall(vim.json.decode, line, JSON_OPTS)
        if not ok then
          load_generation = load_generation + 1
          return cb('invalid card cache ' .. path)
        end
        ix.add(card)
      end
    until vim.uv.hrtime() > deadline
    -- A timer (not vim.schedule) so pending input is handled between slices.
    vim.defer_fn(step, 0)
  end
  vim.defer_fn(step, 0)
end

function M.ready()
  return state.loaded
end

--- What a running update is doing: 'checking', 'downloading', 'building',
--- 'loading', or nil when idle.
function M.stage()
  return state.stage
end

--- Subscribe to stage changes: `fn(stage)`. Returns an unsubscribe function.
function M.on_progress(fn)
  local key = {}
  state.progress_subscribers[key] = fn
  return function()
    state.progress_subscribers[key] = nil
  end
end

local function set_stage(stage)
  state.stage = stage
  for _, fn in pairs(state.progress_subscribers) do
    pcall(fn, stage)
  end
end

--- Subscribe to store (re)loads. Returns an unsubscribe function.
function M.on_ready(fn)
  local key = {}
  state.subscribers[key] = fn
  return function()
    state.subscribers[key] = nil
  end
end

---@param name string
---@return table|nil
function M.get(name)
  return state.byname[name:lower()]
end

--- Case-insensitive: prefix matches first, then substring matches.
---@param prefix string
---@param limit? integer default 50
---@return table[]
function M.complete(prefix, limit)
  limit = limit or 50
  local p = prefix:lower()
  local out, prefixed = {}, {}
  for i, lname in ipairs(state.lower_names) do
    if #out >= limit then
      return out
    end
    if lname:sub(1, #p) == p then
      prefixed[i] = true
      out[#out + 1] = state.byname[lname]
    end
  end
  for i, lname in ipairs(state.lower_names) do
    if #out >= limit then
      break
    end
    if not prefixed[i] and lname:find(p, 1, true) then
      out[#out + 1] = state.byname[lname]
    end
  end
  return out
end

--- Run build.lua in a child Neovim. `cb(err)` runs on the main loop.
function M.build(input, output, cb)
  vim.system(
    { vim.v.progpath, '--clean', '-l', BUILD_SCRIPT, input, output },
    { text = true },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 then
        return cb(vim.trim(res.stderr or '') ~= '' and vim.trim(res.stderr) or ('build exited ' .. res.code))
      end
      cb(nil)
    end)
  )
end

--- Download and rebuild the card cache.
---@param opts? { force?: boolean, announce?: boolean }
---  force: rebuild even if Scryfall's updated_at matches the cache.
---  announce: notify on success.
---@param cb? fun(err: string|nil)
function M.update(opts, cb)
  opts = opts or {}
  if cb then
    state.waiters[#state.waiters + 1] = cb
  end
  if state.updating then
    return
  end
  state.updating = true
  local paths = M.paths()
  vim.fn.mkdir(paths.dir, 'p')

  local function finish(err)
    state.updating = false
    set_stage(nil)
    if err then
      state.last_error = err
      notify('card data update failed: ' .. err, vim.log.levels.WARN)
    end
    local waiters = state.waiters
    state.waiters = {}
    for _, fn in ipairs(waiters) do
      fn(err)
    end
  end

  set_stage('checking')
  http.get_json(M.BULK_URL, function(err, bulk)
    if err then
      return finish(err)
    end
    -- Scryfall now publishes the JSONL file as jsonl_download_uri.
    local uri = bulk.jsonl_download_uri or bulk.download_uri
    if not uri then
      return finish('bulk-data response has no download URI')
    end
    local meta = M.read_meta()
    if not opts.force and state.loaded and meta and meta.updated_at == bulk.updated_at then
      meta.checked_at = os.time()
      write_meta(meta)
      if opts.announce then
        notify('card data is up to date')
      end
      return finish(nil)
    end
    set_stage('downloading')
    http.download(uri, paths.bulk, function(derr)
      if derr then
        return finish(derr)
      end
      set_stage('building')
      M.build(paths.bulk, paths.cards, function(berr)
        os.remove(paths.bulk)
        if berr then
          return finish(berr)
        end
        write_meta({ updated_at = bulk.updated_at, checked_at = os.time() })
        set_stage('loading')
        M.load_file_async(paths.cards, function(lerr)
          if lerr then
            return finish(lerr)
          end
          state.last_error = nil
          if opts.announce then
            notify(('card data ready (%d cards)'):format(state.count))
          end
          finish(nil)
        end)
      end)
    end)
  end)
end

--- Load the cache on first use; download or refresh as configured.
function M.ensure()
  if state.started then
    return
  end
  state.started = true
  local cfg = config.get()
  local paths = M.paths()

  local function download()
    if cfg.auto_download then
      notify('downloading Scryfall card data (about 25 MB); completion and hover start working when it finishes')
      M.update({ announce = true })
    else
      notify('no card data; run :Scryvim update', vim.log.levels.WARN)
    end
  end

  if not vim.uv.fs_stat(paths.cards) then
    return download()
  end
  set_stage('loading')
  M.load_file_async(paths.cards, function(err)
    set_stage(nil)
    if err then
      state.last_error = err
      return download()
    end
    local meta = M.read_meta()
    local checked = meta and meta.checked_at or 0
    if os.time() - checked > cfg.max_age_days * 86400 then
      M.update()
    end
  end)
end

function M.info()
  local meta = M.read_meta() or {}
  return {
    count = state.count,
    ready = state.loaded,
    updating = state.updating,
    stage = state.stage,
    updated_at = meta.updated_at,
    checked_at = meta.checked_at,
    age_days = meta.checked_at and (os.time() - meta.checked_at) / 86400 or nil,
    cache_dir = M.paths().dir,
    last_error = state.last_error,
  }
end

--- Test helper: forget all loaded state.
function M._reset()
  state.byname, state.lower_names = {}, {}
  state.count, state.loaded, state.started, state.updating = 0, false, false, false
  state.waiters, state.last_error, state.subscribers = {}, nil, {}
  state.stage, state.progress_subscribers = nil, {}
  load_generation = load_generation + 1
end

return M
