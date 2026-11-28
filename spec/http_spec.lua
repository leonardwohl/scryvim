local http = require('scryvim.http')

describe('http', function()
  local orig = http._system
  local calls

  local function respond(stdout)
    http._system = function(cmd, on_exit)
      calls[#calls + 1] = { cmd = cmd, t = vim.uv.now() }
      on_exit({ code = 0, stdout = stdout, stderr = '' })
    end
  end

  local function get(url)
    local done, err, obj = false, nil, nil
    http.get_json(url, function(e, o)
      done, err, obj = true, e, o
    end)
    assert(vim.wait(3000, function()
      return done
    end))
    return err, obj
  end

  before_each(function()
    calls = {}
    http._reset()
  end)

  after_each(function()
    http._system = orig
    http._reset()
  end)

  it('sends the required headers', function()
    respond('{"object":"list","data":[]}\n200')
    get('https://api.scryfall.com/bulk-data/oracle-cards')
    local cmd = table.concat(calls[1].cmd, ' ')
    assert.truthy(cmd:find('User-Agent: scryvim/', 1, true))
    assert.truthy(cmd:find('Accept: application/json', 1, true))
  end)

  it('gives up on connections that fail or stall', function()
    respond('{"object":"list","data":[]}\n200')
    get('https://api.scryfall.com/bulk-data/oracle-cards')
    local cmd = table.concat(calls[1].cmd, ' ')
    assert.truthy(cmd:find('--connect-timeout', 1, true))
    assert.truthy(cmd:find('--speed-limit', 1, true))
  end)

  it('turns a /cards/search 404 into an empty list', function()
    respond('{"object":"error","code":"not_found","status":404,"details":"No cards found"}\n404')
    local err, obj = get('https://api.scryfall.com/cards/search?q=zzzz')
    assert.is_nil(err)
    assert.are.same({}, obj.data)
    -- Warnings about ignored terms survive.
    respond('{"object":"error","code":"not_found","status":404,"warnings":["Unknown keyword"]}\n404')
    _, obj = get('https://api.scryfall.com/cards/search?q=prodces:r')
    assert.are.same({ 'Unknown keyword' }, obj.warnings)
  end)

  it('surfaces other Scryfall errors', function()
    respond('{"object":"error","code":"bad_request","status":400,"details":"bad query"}\n400')
    local err = get('https://api.scryfall.com/cards/search?q=(')
    assert.truthy(err:find('bad query', 1, true))
  end)

  it('aborts on 429 without retrying', function()
    respond('{"object":"error","code":"rate_limited","status":429}\n429')
    local notified = false
    local orig_notify = vim.notify
    vim.notify = function()
      notified = true
    end
    local err = get('https://api.scryfall.com/cards/named?exact=x')
    vim.notify = orig_notify
    assert.truthy(err:find('429', 1, true))
    assert.is_true(notified)
    assert.are.equal(1, #calls)
  end)

  it('spaces /cards/search requests 600 ms apart, a margin under the 2/s limit', function()
    respond('{"object":"list","data":[]}\n200')
    get('https://api.scryfall.com/cards/search?q=a')
    get('https://api.scryfall.com/cards/search?q=b')
    assert.is_true(calls[2].t - calls[1].t >= 590)
  end)

  it('drops a queued request that is no longer wanted, without using its slot', function()
    respond('{"object":"list","data":[]}\n200')
    local errs = {}
    local function queue(q, wanted)
      http.get_json('https://api.scryfall.com/cards/search?q=' .. q, function(e)
        errs[q] = e or 'ok'
      end, { wanted = wanted })
    end
    queue('a')
    queue('b', function()
      return false
    end)
    queue('c')
    assert(vim.wait(3000, function()
      return errs.c ~= nil
    end))
    assert.are.equal(http.DROPPED, errs.b)
    assert.are.equal(2, #calls)
    -- c took b's slot.
    assert.is_true(calls[2].t - calls[1].t < 900)
  end)

  it('holds the queue after a 429', function()
    local orig_notify, orig_backoff = vim.notify, http.BACKOFF_MS
    vim.notify = function() end
    http.BACKOFF_MS = 1000
    respond('{"object":"error","code":"rate_limited","status":429}\n429')
    get('https://api.scryfall.com/cards/search?q=a')
    respond('{"object":"list","data":[]}\n200')
    get('https://api.scryfall.com/cards/search?q=b')
    vim.notify, http.BACKOFF_MS = orig_notify, orig_backoff
    assert.is_true(calls[2].t - calls[1].t >= 990)
  end)
end)
