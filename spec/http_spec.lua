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
  end)

  after_each(function()
    http._system = orig
  end)

  it('sends the required headers', function()
    respond('{"object":"list","data":[]}\n200')
    get('https://api.scryfall.com/bulk-data/oracle-cards')
    local cmd = table.concat(calls[1].cmd, ' ')
    assert.truthy(cmd:find('User-Agent: scryvim/', 1, true))
    assert.truthy(cmd:find('Accept: application/json', 1, true))
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

  it('spaces /cards/search requests at least 500 ms apart', function()
    respond('{"object":"list","data":[]}\n200')
    get('https://api.scryfall.com/cards/search?q=a')
    get('https://api.scryfall.com/cards/search?q=b')
    assert.is_true(calls[2].t - calls[1].t >= 490)
  end)
end)
