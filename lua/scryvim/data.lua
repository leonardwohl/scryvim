--- Card store. The only module that knows the cache format.
local config = require('scryvim.config')
local http = require('scryvim.http')

local M = {}

M.BULK_URL = 'https://api.scryfall.com/bulk-data/oracle-cards'

local BUILD_SCRIPT = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), 'build.lua')

local state = {
  byname = {},
  names = {},
  lower_names = {},
  count = 0,
  loaded = false,
  started = false,
  updating = false,
  waiters = {},
  last_error = nil,
  subscribers = {},
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

--- Replace the in-memory store with `cards`.
---@param cards table[]
function M.index(cards)
  local byname, names, lower_names = {}, {}, {}
  for _, card in ipairs(cards) do
    local key = card.name:lower()
    if not byname[key] then
      byname[key] = card
      names[#names + 1] = card.name
    end
    local face = card.card_faces and card.card_faces[1]
    if face and face.name then
      local fkey = face.name:lower()
      byname[fkey] = byname[fkey] or card
    end
  end
  table.sort(names, function(a, b)
    return a:lower() < b:lower()
  end)
  for i, name in ipairs(names) do
    lower_names[i] = name:lower()
  end
  state.byname, state.names, state.lower_names = byname, names, lower_names
  state.count = #names
  state.loaded = true
  for _, fn in pairs(state.subscribers) do
    pcall(fn)
  end
end

--- Load a stripped cards.json file into the store.
---@return boolean ok, string|nil err
function M.load_file(path)
  local s = read_file(path)
  if not s then
    return false, 'cannot read ' .. path
  end
  local ok, cards = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  if not ok or type(cards) ~= 'table' then
    return false, 'invalid card cache ' .. path
  end
  M.index(cards)
  return true
end

function M.ready()
  return state.loaded
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

  http.get_json(M.BULK_URL, function(err, bulk)
    if err then
      return finish(err)
    end
    if not bulk.download_uri then
      return finish('bulk-data response has no download_uri')
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
    http.download(bulk.download_uri, paths.bulk, function(derr)
      if derr then
        return finish(derr)
      end
      M.build(paths.bulk, paths.cards, function(berr)
        os.remove(paths.bulk)
        if berr then
          return finish(berr)
        end
        write_meta({ updated_at = bulk.updated_at, checked_at = os.time() })
        local ok, lerr = M.load_file(paths.cards)
        if not ok then
          return finish(lerr)
        end
        state.last_error = nil
        if opts.announce then
          notify(('card data updated (%d cards)'):format(state.count))
        end
        finish(nil)
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
  if vim.uv.fs_stat(paths.cards) then
    local ok, err = M.load_file(paths.cards)
    if ok then
      local meta = M.read_meta()
      local checked = meta and meta.checked_at or 0
      if os.time() - checked > cfg.max_age_days * 86400 then
        M.update()
      end
      return
    end
    state.last_error = err
  end
  if cfg.auto_download then
    notify('downloading Scryfall card data…')
    M.update({ announce = true })
  else
    notify('no card data; run :Scryvim update', vim.log.levels.WARN)
  end
end

function M.info()
  local meta = M.read_meta() or {}
  return {
    count = state.count,
    ready = state.loaded,
    updating = state.updating,
    updated_at = meta.updated_at,
    checked_at = meta.checked_at,
    age_days = meta.checked_at and (os.time() - meta.checked_at) / 86400 or nil,
    cache_dir = M.paths().dir,
    last_error = state.last_error,
  }
end

--- Test helper: forget all loaded state.
function M._reset()
  state.byname, state.names, state.lower_names = {}, {}, {}
  state.count, state.loaded, state.started, state.updating = 0, false, false, false
  state.waiters, state.last_error, state.subscribers = {}, nil, {}
end

return M
