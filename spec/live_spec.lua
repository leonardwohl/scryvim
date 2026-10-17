-- Talks to the real Scryfall API. Opt in with SCRYVIM_LIVE=1.
-- Makes a handful of rate-limited requests and downloads the Oracle Cards
-- bulk file once.
local live = os.getenv('SCRYVIM_LIVE') == '1'
local suite = live and describe or pending

local function await(start, timeout)
  local done, a, b = false, nil, nil
  start(function(x, y)
    done, a, b = true, x, y
  end)
  assert(
    vim.wait(timeout or 30000, function()
      return done
    end, 50),
    'timed out'
  )
  return a, b
end

suite('Scryfall (live)', function()
  local http = require('scryvim.http')
  local picker = require('scryvim.picker')

  it('serves bulk-data metadata for Oracle Cards', function()
    local err, bulk = await(function(cb)
      http.get_json(require('scryvim.data').BULK_URL, cb)
    end)
    assert.is_nil(err)
    assert.are.equal('oracle_cards', bulk.type, vim.inspect(bulk))
    assert.truthy((bulk.jsonl_download_uri or bulk.download_uri or ''):match('^https://'), vim.inspect(bulk))
    assert.are.equal('string', type(bulk.updated_at))
  end)

  it('searches and pages results through build.strip', function()
    local err, cards = await(function(cb)
      picker.fetch('!"Lightning Bolt"', 1, cb)
    end)
    assert.is_nil(err)
    -- Exact-name search also matches cards with a "Lightning Bolt" face.
    local bolt = vim.iter(cards):find(function(c)
      return c.name == 'Lightning Bolt'
    end)
    assert.truthy(bolt, vim.inspect(cards))
    assert.are.same(
      { 'cmc', 'color_identity', 'mana_cost', 'name', 'oracle_text', 'scryfall_uri', 'type_line' },
      vim.fn.sort(vim.tbl_keys(bolt))
    )
    assert.are.equal('{R}', bolt.mana_cost)

    err, cards = await(function(cb)
      picker.fetch('t:goblin', 2, cb)
    end)
    assert.is_nil(err)
    -- Over 175 goblins exist, so this needs page 2 and stops there.
    assert.are.equal(350, #cards)
  end)

  it('returns an empty list when a search matches nothing', function()
    local err, cards = await(function(cb)
      picker.fetch('name:zzqqxxnotacard', 1, cb)
    end)
    assert.is_nil(err)
    assert.are.same({}, cards)
  end)

  it('surfaces Scryfall errors outside /cards/search', function()
    local err = await(function(cb)
      http.get_json('https://api.scryfall.com/cards/named?exact=zzqqxxnotacard', cb)
    end)
    assert.are.equal('string', type(err))
    assert.truthy(err:find('not_found', 1, true), err)
  end)

  it('downloads and builds the full card store', function()
    local dir = vim.fn.tempname()
    vim.g.scryvim = { cache_dir = dir, auto_download = false }
    local data = require('scryvim.data')
    data._reset()
    local start = vim.uv.hrtime()
    local err = await(function(cb)
      data.update({ force = true }, cb)
    end, 600000)
    assert.is_nil(err)
    print(('\nfull update: %.1fs, %d cards'):format((vim.uv.hrtime() - start) / 1e9, data.info().count))

    assert.is_true(data.info().count > 25000)
    assert.are.equal('{R}', data.get('Lightning Bolt').mana_cost)
    assert.are.equal('Delver of Secrets // Insectile Aberration', data.get('Delver of Secrets').name)
    assert.are.equal('Lightning Bolt', data.complete('lightning bo')[1].name)
    assert.is_nil(data.get('Goblin'), 'tokens should be filtered')
    assert.is_nil(vim.uv.fs_stat(dir .. '/oracle-cards.jsonl.gz'), 'bulk download should be removed')

    data._reset()
    start = vim.uv.hrtime()
    assert(data.load_file(dir .. '/cards.json'))
    print(('cold load: %.0f ms'):format((vim.uv.hrtime() - start) / 1e6))
  end)
end)
