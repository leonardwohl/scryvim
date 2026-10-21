--- Minimal Scryfall HTTP client: curl via vim.system, per-endpoint rate limits.
local M = {}

M.version = '0.1.0'

local USER_AGENT = 'scryvim/' .. M.version
local ACCEPT = 'application/json;q=0.9,*/*;q=0.8'

--- Prefix for `/cards/search` requests; append the urlencoded query.
M.SEARCH_URL = 'https://api.scryfall.com/cards/search?q='

local SLOW = { ['/cards/search'] = true, ['/cards/named'] = true, ['/cards/collection'] = true }
local SLOW_MS, FAST_MS = 500, 100

local next_slot = {}

local function split_url(url)
  local host, path = url:match('^%a+://([^/?#]+)([^?#]*)')
  return host or '', (path ~= nil and path ~= '') and path or '/'
end

--- Run `fn` no sooner than the endpoint's minimum interval after the
--- previous request to that endpoint. Requests queue in call order.
local function throttle(url, fn)
  local host, path = split_url(url)
  local interval = SLOW[path] and SLOW_MS or FAST_MS
  local key = host .. path
  local now = vim.uv.now()
  local slot = math.max(now, next_slot[key] or 0)
  next_slot[key] = slot + interval
  if slot <= now then
    fn()
  else
    vim.defer_fn(fn, slot - now)
  end
end

--- Overridable for tests.
function M._system(cmd, on_exit)
  return vim.system(cmd, { text = true }, on_exit)
end

local function curl(url, extra)
  local cmd = { 'curl', '-sS', '-L', '-H', 'User-Agent: ' .. USER_AGENT, '-H', 'Accept: ' .. ACCEPT }
  vim.list_extend(cmd, extra)
  cmd[#cmd + 1] = url
  return cmd
end

local function rate_limited(url)
  local msg = 'scryvim: Scryfall rate limit hit (HTTP 429); request aborted: ' .. url
  vim.notify(msg, vim.log.levels.WARN)
  return msg
end

--- GET a JSON endpoint. `cb(err, obj)` runs on the main loop.
---
--- Scryfall error objects become `err`, except a 404 from `/cards/search`,
--- which means "no matches" and yields an empty list (keeping any
--- `warnings` about ignored query terms).
---@param url string
---@param cb fun(err: string|nil, obj: table|nil)
function M.get_json(url, cb)
  throttle(url, function()
    M._system(
      curl(url, { '--compressed', '-w', '\n%{http_code}' }),
      vim.schedule_wrap(function(res)
        if res.code ~= 0 then
          return cb('curl failed: ' .. vim.trim(res.stderr or ''))
        end
        local body, status = (res.stdout or ''):match('^(.*)\n(%d+)$')
        status = tonumber(status) or 0
        if status == 429 then
          return cb(rate_limited(url))
        end
        local ok, obj = pcall(vim.json.decode, body or '', { luanil = { object = true, array = true } })
        if not ok or type(obj) ~= 'table' then
          return cb(('invalid response from %s (HTTP %d)'):format(url, status))
        end
        if obj.object == 'error' then
          local _, path = split_url(url)
          if status == 404 and path == '/cards/search' then
            return cb(nil, { object = 'list', data = {}, has_more = false, total_cards = 0, warnings = obj.warnings })
          end
          return cb(('Scryfall error (%s): %s'):format(obj.code or status, obj.details or 'unknown'))
        end
        if status >= 400 then
          return cb(('HTTP %d from %s'):format(status, url))
        end
        cb(nil, obj)
      end)
    )
  end)
end

--- Download `url` to `path`. `cb(err)` runs on the main loop.
---@param url string
---@param path string
---@param cb fun(err: string|nil)
function M.download(url, path, cb)
  throttle(url, function()
    M._system(
      curl(url, { '--compressed', '-o', path, '-w', '%{http_code}' }),
      vim.schedule_wrap(function(res)
        local status = tonumber(vim.trim(res.stdout or '')) or 0
        if res.code ~= 0 or status ~= 200 then
          os.remove(path)
          if status == 429 then
            return cb(rate_limited(url))
          end
          return cb(('download failed (HTTP %d): %s'):format(status, vim.trim(res.stderr or '')))
        end
        cb(nil)
      end)
    )
  end)
end

function M.urlencode(s)
  return (s:gsub('[^%w%-_%.~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

return M
