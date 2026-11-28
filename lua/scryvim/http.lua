--- Minimal Scryfall HTTP client: curl via vim.system, per-endpoint rate limits.
local M = {}

M.version = '1.0.0'

local USER_AGENT = 'scryvim/' .. M.version
local ACCEPT = 'application/json;q=0.9,*/*;q=0.8'

--- Prefix for `/cards/search` requests; append the urlencoded query.
M.SEARCH_URL = 'https://api.scryfall.com/cards/search?q='

local SLOW = { ['/cards/search'] = true, ['/cards/named'] = true, ['/cards/collection'] = true }
--- Scryfall allows 2 requests a second on the slow endpoints; leave a margin
--- so network jitter can't land two requests closer than 500 ms apart.
M.SLOW_MS, M.FAST_MS = 600, 100
--- How long an endpoint rests after a 429 before its queue moves again.
M.BACKOFF_MS = 30000

--- Message passed to a callback whose request was dropped unsent.
M.DROPPED = 'request dropped: no longer needed'

-- Endpoint -> { items, next_at, waiting }
local queues = {}

local function split_url(url)
  local host, path = url:match('^%a+://([^/?#]+)([^?#]*)')
  return host or '', (path ~= nil and path ~= '') and path or '/'
end

-- Slow endpoints each have a queue; every other path on a host shares one,
-- so lookups like `/cards/m10/146` and `/cards/m10/147` are spaced out too.
local function queue_for(url)
  local host, path = split_url(url)
  local key = host .. (SLOW[path] and path or '/*')
  local q = queues[key]
  if not q then
    q = { items = {}, next_at = 0, waiting = false, interval = SLOW[path] and M.SLOW_MS or M.FAST_MS }
    queues[key] = q
  end
  return q
end

-- Send what the queue allows now, and wake up when the next one may go.
-- An item whose `wanted()` turns false is dropped when it reaches the
-- front, without using a slot.
local function pump(q)
  if q.waiting then
    return
  end
  while #q.items > 0 do
    local item = q.items[1]
    if item.wanted and not item.wanted() then
      table.remove(q.items, 1)
      item.drop()
    else
      local now = vim.uv.now()
      if q.next_at > now then
        q.waiting = true
        vim.defer_fn(function()
          q.waiting = false
          pump(q)
        end, q.next_at - now)
        return
      end
      table.remove(q.items, 1)
      q.next_at = now + q.interval
      item.send()
    end
  end
end

--- Run `send` no sooner than the endpoint's minimum interval after the
--- previous request to that endpoint. Requests queue in call order. With
--- `wanted`, it is asked again just before sending, and `drop` runs instead
--- once it returns false.
local function throttle(url, send, wanted, drop)
  local q = queue_for(url)
  q.items[#q.items + 1] = { send = send, wanted = wanted, drop = drop }
  pump(q)
end

-- After a 429, hold the endpoint's queue for `M.BACKOFF_MS`.
local function back_off(url)
  local q = queue_for(url)
  q.next_at = math.max(q.next_at, vim.uv.now() + M.BACKOFF_MS)
end

--- Overridable for tests.
function M._system(cmd, on_exit)
  return vim.system(cmd, { text = true }, on_exit)
end

-- Give up on a connection that can't be made, or that stalls (under 1 KB/s
-- for a minute), so a dead network doesn't leave an update running forever.
local TIMEOUTS = { '--connect-timeout', '15', '--speed-limit', '1024', '--speed-time', '60' }

local function curl(url, extra)
  local cmd = { 'curl', '-sS', '-L', '-H', 'User-Agent: ' .. USER_AGENT, '-H', 'Accept: ' .. ACCEPT }
  vim.list_extend(cmd, TIMEOUTS)
  vim.list_extend(cmd, extra)
  cmd[#cmd + 1] = url
  return cmd
end

local function rate_limited(url)
  back_off(url)
  local msg = 'scryvim: Scryfall rate limit hit (HTTP 429); request aborted: ' .. url
  vim.notify(msg, vim.log.levels.WARN)
  return msg
end

--- GET a JSON endpoint. `cb(err, obj)` runs on the main loop.
---
--- Scryfall error objects become `err`, except a 404 from `/cards/search`,
--- which means "no matches" and yields an empty list (keeping any
--- `warnings` about ignored query terms).
---
--- With `opts.wanted`, the request is dropped unsent (`cb(M.DROPPED)`) if
--- it returns false by the time the request's turn comes.
---@param url string
---@param cb fun(err: string|nil, obj: table|nil)
---@param opts? { wanted?: fun(): boolean }
function M.get_json(url, cb, opts)
  local function send()
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
  end
  throttle(url, send, opts and opts.wanted, function()
    vim.schedule(function()
      cb(M.DROPPED)
    end)
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

--- For tests: forget queued requests and rate limit state.
function M._reset()
  queues = {}
end

function M.urlencode(s)
  return (s:gsub('[^%w%-_%.~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

return M
