--- Oracle tags (otags) per card, for the preview pane.
---
--- Card objects don't carry tags, and an `otag:` search only says which
--- cards have one given tag. Scryfall's tag list has every oracle tag with
--- the oracle ids of its cards (about 23 MB), so it is downloaded once, for
--- the first card the pane shows, and refreshed after `max_age_days` like
--- the card data. A child Neovim turns it into tags.txt (see build.lua).
local config = require('scryvim.config')
local http = require('scryvim.http')

local M = {}

M.URL = 'https://api.scryfall.com/private/tags/oracle'

local BUILD_SCRIPT = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), 'build.lua')

local state = {
  -- tags.txt as read, searched for each oracle id.
  text = nil,
  labels = nil,
  -- Oracle id -> labels, for ids already looked up.
  by_id = {},
  started = false,
  updating = false,
  last_error = nil,
  subscribers = {},
  waiters = {},
}

function M.paths()
  local dir = config.get().cache_dir
  return { dir = dir, tags = dir .. '/tags.txt', download = dir .. '/oracle-tags.json' }
end

local function load(path)
  local f = io.open(path, 'rb')
  if not f then
    return false
  end
  local s = f:read('*a')
  f:close()
  local nl = s:find('\n', 1, true)
  local ok, head = pcall(vim.json.decode, nl and s:sub(1, nl - 1) or '')
  if not ok or type(head) ~= 'table' or type(head.labels) ~= 'table' then
    return false
  end
  state.text, state.labels, state.by_id = s, head.labels, {}
  return true
end

--- Subscribe to the tags loading, or failing to. Returns an unsubscribe
--- function.
function M.on_ready(fn)
  local key = {}
  state.subscribers[key] = fn
  return function()
    state.subscribers[key] = nil
  end
end

--- Download the tag list and rebuild tags.txt. A failed update keeps the
--- tags already loaded. `cb(err)` runs on the main loop.
---@param cb? fun(err: string|nil)
function M.update(cb)
  state.started = true
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
    state.last_error = err
    for _, fn in pairs(state.subscribers) do
      pcall(fn)
    end
    local waiters = state.waiters
    state.waiters = {}
    for _, fn in ipairs(waiters) do
      fn(err)
    end
  end

  http.download(M.URL, paths.download, function(derr)
    if derr then
      return finish(derr)
    end
    vim.system(
      { vim.v.progpath, '--clean', '-l', BUILD_SCRIPT, '--tags', paths.download, paths.tags },
      { text = true },
      vim.schedule_wrap(function(res)
        os.remove(paths.download)
        if res.code ~= 0 then
          local stderr = vim.trim(res.stderr or '')
          return finish(stderr ~= '' and stderr or ('tag build exited ' .. res.code))
        end
        if not load(paths.tags) then
          return finish('invalid tag cache ' .. paths.tags)
        end
        finish(nil)
      end)
    )
  end)
end

--- Load tags.txt on first use; download or refresh it as configured.
function M.ensure()
  if state.started then
    return
  end
  state.started = true
  local cfg = config.get()
  local path = M.paths().tags
  local stat = vim.uv.fs_stat(path)
  if stat and load(path) then
    if os.time() - stat.mtime.sec > cfg.max_age_days * 86400 then
      M.update()
    end
  elseif cfg.auto_download then
    M.update()
  else
    state.last_error = 'not downloaded; run :Scryvim update'
  end
end

--- The oracle tags of the card with `oracle_id`, sorted. Nil while the tag
--- list is downloading, and nil with an error when there is none.
---@param oracle_id string
---@return string[]|nil labels, string|nil err
function M.get(oracle_id)
  M.ensure()
  if not state.text then
    return nil, not state.updating and state.last_error or nil
  end
  local labels = state.by_id[oracle_id]
  if not labels then
    labels = {}
    local _, e = state.text:find('\n' .. oracle_id .. '\t', 1, true)
    if e then
      local stop = state.text:find('\n', e + 1, true) or #state.text + 1
      for i in state.text:sub(e + 1, stop - 1):gmatch('%d+') do
        labels[#labels + 1] = state.labels[tonumber(i)]
      end
    end
    state.by_id[oracle_id] = labels
  end
  return labels
end

function M.info()
  local stat = vim.uv.fs_stat(M.paths().tags)
  return {
    ready = state.text ~= nil,
    updating = state.updating,
    fetched_at = stat and stat.mtime.sec or nil,
    last_error = state.last_error,
  }
end

--- Test helper: forget all loaded state.
function M._reset()
  state.text, state.labels, state.by_id = nil, nil, {}
  state.started, state.updating, state.last_error = false, false, nil
  state.waiters = {}
end

return M
