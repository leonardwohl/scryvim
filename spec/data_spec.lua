local build = require('scryvim.build')
local helpers = require('helpers')

describe('build', function()
  it('strips to the kept fields', function()
    local out = build.strip({
      name = 'X',
      cmc = 1,
      prices = { usd = '1' },
      legalities = {},
      card_faces = { { name = 'A', colors = { 'U' }, mana_cost = '{U}' } },
    })
    assert.are.same({ name = 'X', cmc = 1, card_faces = { { name = 'A', mana_cost = '{U}' } } }, out)
  end)

  it('builds cards.json from the fixture, dropping tokens and emblems', function()
    local dir = helpers.load_fixture()
    local f = assert(io.open(dir .. '/cards.json'))
    local cards = vim.json.decode(f:read('*a'))
    f:close()
    assert.are.equal(21, #cards)
    for _, c in ipairs(cards) do
      assert.is_not.equal('Goblin', c.name)
      assert.is_nil(c.prices)
      assert.is_nil(c.legalities)
    end
  end)
end)

describe('data', function()
  local data = require('scryvim.data')

  before_each(function()
    helpers.load_fixture()
  end)

  it('looks up by name, case-insensitively', function()
    assert.is_true(data.ready())
    assert.are.equal('Lightning Bolt', data.get('lightning BOLT').name)
    assert.is_nil(data.get('Not A Card'))
  end)

  it('indexes multi-face cards by their front face', function()
    assert.are.equal('Delver of Secrets // Insectile Aberration', data.get('Delver of Secrets').name)
    assert.are.equal('Fire // Ice', data.get('fire').name)
    assert.are.equal('Fire // Ice', data.get('Fire // Ice').name)
  end)

  it('completes prefix matches before substring matches', function()
    local names = vim.tbl_map(function(c)
      return c.name
    end, data.complete('isl'))
    assert.are.same({ 'Island' }, names)

    names = vim.tbl_map(function(c)
      return c.name
    end, data.complete('bol'))
    assert.are.same({ 'Lightning Bolt' }, names)

    names = vim.tbl_map(function(c)
      return c.name
    end, data.complete('fire'))
    assert.are.same({ 'Fire // Ice', 'Fireball' }, names)

    names = vim.tbl_map(function(c)
      return c.name
    end, data.complete('d'))
    -- Prefix hits (alphabetical) precede substring hits.
    assert.are.same({ 'Dark Ritual', 'Delver of Secrets // Insectile Aberration', 'Dryad Arbor', 'Duress' }, {
      names[1],
      names[2],
      names[3],
      names[4],
    })
    assert.is_true(#names > 4)
  end)

  it('respects the limit', function()
    assert.are.equal(3, #data.complete('', 3))
  end)

  it('notifies subscribers on reload', function()
    local calls = 0
    local unsubscribe = data.on_ready(function()
      calls = calls + 1
    end)
    data.index({ { name = 'Only Card' } })
    unsubscribe()
    data.index({ { name = 'Only Card' } })
    assert.are.equal(1, calls)
  end)

  it('updates from jsonl_download_uri and writes metadata', function()
    local http = require('scryvim.http')
    local get_json, download = http.get_json, http.download
    local downloaded
    http.get_json = function(_, cb)
      cb(nil, { jsonl_download_uri = 'https://data.example/oracle.jsonl.gz', updated_at = 'new' })
    end
    http.download = function(url, path, cb)
      downloaded = url
      vim.uv.fs_copyfile(helpers.fixture, path)
      cb(nil)
    end
    data.index({})
    local stages = {}
    data.on_progress(function(stage)
      stages[#stages + 1] = stage or 'idle'
    end)
    local done, err = false, nil
    data.update({ force = true }, function(e)
      done, err = true, e
    end)
    assert(vim.wait(10000, function()
      return done
    end))
    http.get_json, http.download = get_json, download
    assert.is_nil(err)
    assert.are.equal('https://data.example/oracle.jsonl.gz', downloaded)
    assert.are.equal('Lightning Bolt', data.get('Lightning Bolt').name)
    assert.are.equal('new', data.read_meta().updated_at)
    assert.are.equal(data.CACHE_FORMAT, data.read_meta().format)
    assert.is_nil(vim.uv.fs_stat(data.paths().bulk))
    assert.are.same({ 'checking', 'downloading', 'building', 'loading', 'idle' }, stages)
  end)

  it('rebuilds a cache written in an older format', function()
    local dir = helpers.load_fixture()
    local meta = assert(io.open(dir .. '/meta.json', 'w'))
    meta:write(vim.json.encode({ updated_at = 'fixture', checked_at = os.time() }))
    meta:close()
    data._reset()
    local http = require('scryvim.http')
    local get_json = http.get_json
    local checked = false
    http.get_json = function(_, cb)
      checked = true
      cb('offline')
    end
    data.ensure()
    local ok = vim.wait(5000, function()
      return checked
    end)
    http.get_json = get_json
    assert.is_true(ok)
    -- The old cache stays usable meanwhile.
    assert.are.equal('Lightning Bolt', data.get('Lightning Bolt').name)
  end)

  it('loads without blocking, keeping the old store until done', function()
    local path = vim.fn.tempname()
    local lines = { '[' }
    for i = 1, 20000 do
      lines[#lines + 1] = vim.json.encode({ name = 'Card ' .. i, cmc = i % 7, oracle_text = ('text '):rep(20) }) .. ','
    end
    lines[#lines + 1] = vim.json.encode({ name = 'Lightning Bolt', cmc = 1 })
    lines[#lines + 1] = ']'
    vim.fn.writefile(lines, path)
    data.index({ { name = 'Old Card' } })
    local done, err = false, nil
    data.LOAD_SLICE_MS = 1
    data.load_file_async(path, function(e)
      done, err = true, e
    end)
    assert.are.equal('Old Card', data.get('old card').name)
    -- A libuv timer only fires while the loop is free between slices.
    local ticks = 0
    local timer = assert(vim.uv.new_timer())
    timer:start(1, 1, function()
      ticks = ticks + 1
    end)
    assert(vim.wait(5000, function()
      return done
    end, 1))
    timer:close()
    data.LOAD_SLICE_MS = 8
    assert.is_nil(err)
    assert.is_true(ticks > 3, 'load should have yielded to the event loop')
    assert.are.equal('Lightning Bolt', data.get('lightning bolt').name)
    assert.are.equal(20001, data.info().count)
    assert.is_nil(data.get('Old Card'))
  end)

  it('still loads a single-line cards.json from older versions', function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ vim.json.encode({ { name = 'Legacy Card', cmc = 1 } }) }, path)
    local done = false
    data.load_file_async(path, function()
      done = true
    end)
    assert(vim.wait(2000, function()
      return done
    end))
    assert.are.equal('Legacy Card', data.get('legacy card').name)
  end)

  it("prefers a card's own name over another card's front face", function()
    data.index({
      { name = 'Bolt // Other', card_faces = { { name = 'Bolt' }, { name = 'Other' } } },
      { name = 'Bolt' },
    })
    assert.are.equal('Bolt', data.get('bolt').name)
    assert.are.same(
      { 'Bolt', 'Bolt // Other' },
      vim.tbl_map(function(c)
        return c.name
      end, data.complete('bolt'))
    )
  end)
end)
