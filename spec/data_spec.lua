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
end)
