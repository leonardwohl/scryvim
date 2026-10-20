local count = require('scryvim.count')
local http = require('scryvim.http')

local CARDS = {
  ['lightning bolt'] = { name = 'Lightning Bolt' },
  ['mountain'] = { name = 'Mountain' },
  ['delver of secrets'] = { name = 'Delver of Secrets // Insectile Aberration' },
}

local function lookup(name)
  return CARDS[name:lower()]
end

describe('count.entries', function()
  it('sums quantities per card and resolves names through the store', function()
    local entries = count.entries({
      'Deck',
      '20 Mountain',
      '4 Lightning Bolt (M10) 146',
      '2x lightning bolt',
      'Delver of Secrets',
      '// comment',
      '',
      'Mystery Card',
    }, lookup)
    assert.are.same({
      { name = 'Mountain', count = 20 },
      { name = 'Lightning Bolt', count = 6 },
      { name = 'Delver of Secrets // Insectile Aberration', count = 1 },
      { name = 'Mystery Card', count = 1 },
    }, entries)
  end)

  it('skips Sideboard, Maybeboard and SB: lines unless asked for all', function()
    local lines = {
      '4 Lightning Bolt',
      'SB: 2 Mountain',
      'Sideboard',
      '3 Mountain',
      'Commander',
      '1 Delver of Secrets',
    }
    assert.are.same({
      { name = 'Lightning Bolt', count = 4 },
      { name = 'Delver of Secrets // Insectile Aberration', count = 1 },
    }, count.entries(lines, lookup))
    assert.are.same({
      { name = 'Lightning Bolt', count = 4 },
      { name = 'Mountain', count = 5 },
      { name = 'Delver of Secrets // Insectile Aberration', count = 1 },
    }, count.entries(lines, lookup, true))
  end)
end)

describe('count.batches', function()
  it('keeps every query within the limit', function()
    local names = {}
    for i = 1, 120 do
      names[i] = ('Card Number %03d'):format(i)
    end
    local batches = assert(count.batches('otag:removal', names))
    assert.is_true(#batches > 1)
    local seen = 0
    for _, b in ipairs(batches) do
      assert.is_true(#count.build_query('otag:removal', b) <= count.MAX_QUERY)
      seen = seen + #b
    end
    assert.are.equal(120, seen)
  end)

  it('escapes quotes in names', function()
    assert.are.equal(
      '(c:r) (!"\\"Ach! Hans, Run!\\"" or !"Mountain")',
      count.build_query('c:r', { '"Ach! Hans, Run!"', 'Mountain' })
    )
  end)

  it('rejects a query that cannot fit with any name', function()
    local _, err = count.batches(('x'):rep(1000), { 'Mountain' })
    assert.truthy(err:find('too long', 1, true))
  end)
end)

describe('count.run', function()
  local orig = http.get_json
  local requests

  -- Scryfall stand-in: the matching card names, by full name.
  local function serve(matching)
    http.get_json = function(url, cb)
      local query = vim.uri_decode(url:match('q=(.*)$'))
      requests[#requests + 1] = query
      local data = {}
      for name in query:gmatch('!"(.-)"') do
        if matching[name] then
          data[#data + 1] = { name = matching[name] == true and name or matching[name] }
        end
      end
      vim.schedule(function()
        cb(nil, { object = 'list', data = data })
      end)
    end
  end

  local function run(query, entries)
    local done, err, result = false, nil, nil
    count.run(query, entries, function(e, r)
      done, err, result = true, e, r
    end)
    assert(vim.wait(3000, function()
      return done
    end))
    return err, result
  end

  before_each(function()
    requests = {}
    count._reset()
  end)

  after_each(function()
    http.get_json = orig
  end)

  it('totals matches by quantity', function()
    serve({ Mountain = true, ['Lightning Bolt'] = true })
    local err, result = run('produces:r', {
      { name = 'Mountain', count = 20 },
      { name = 'Lightning Bolt', count = 4 },
      { name = 'Island', count = 10 },
    })
    assert.is_nil(err)
    assert.are.equal(24, result.total)
    assert.are.same({ { name = 'Mountain', count = 20 }, { name = 'Lightning Bolt', count = 4 } }, result.matches)
    assert.are.equal(1, #requests)
    assert.truthy(requests[1]:find('(produces:r) (', 1, true))
  end)

  it('ignores cards that only share a face name', function()
    serve({ ['Lightning Bolt'] = 'Emeritus of Conflict // Lightning Bolt' })
    local _, result = run('t:creature', { { name = 'Lightning Bolt', count = 4 } })
    assert.are.equal(0, result.total)
  end)

  it('matches a front-face name the store did not resolve', function()
    http.get_json = function(_, cb)
      vim.schedule(function()
        cb(nil, {
          data = {
            { name = 'Delver of Secrets // Insectile Aberration', card_faces = { { name = 'Delver of Secrets' } } },
          },
        })
      end)
    end
    local _, result = run('t:human', { { name = 'Delver of Secrets', count = 4 } })
    assert.are.equal(4, result.total)
  end)

  it('only asks about cards it has not seen for that query', function()
    serve({ Mountain = true })
    run('produces:r', { { name = 'Mountain', count = 20 } })
    local _, result = run('produces:r', { { name = 'Mountain', count = 21 }, { name = 'Island', count = 1 } })
    assert.are.equal(21, result.total)
    assert.are.equal(2, #requests)
    assert.falsy(requests[2]:find('Mountain', 1, true))
    run('produces:r', { { name = 'Mountain', count = 21 }, { name = 'Island', count = 1 } })
    assert.are.equal(2, #requests)
  end)

  it('treats terms Scryfall ignored as an error', function()
    http.get_json = function(_, cb)
      vim.schedule(function()
        cb(nil, {
          object = 'list',
          data = { { name = 'Mountain' } },
          warnings = { 'Invalid expression “prodces:r” was ignored. Unknown keyword “prodces”.' },
        })
      end)
    end
    local err, result = run('prodces:r', { { name = 'Mountain', count = 20 } })
    assert.is_nil(result)
    assert.are.equal('Invalid expression “prodces:r”. Unknown keyword “prodces”.', err)
  end)

  it('surfaces errors without caching', function()
    http.get_json = function(_, cb)
      vim.schedule(function()
        cb('Scryfall error (bad_request): bad query')
      end)
    end
    local err = run('(', { { name = 'Mountain', count = 1 } })
    assert.truthy(err:find('bad query', 1, true))
    serve({ Mountain = true })
    local _, result = run('(', { { name = 'Mountain', count = 1 } })
    assert.are.equal(1, result.total)
  end)
end)
