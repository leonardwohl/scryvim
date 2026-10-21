local curve = require('scryvim.curve')

local function binom(n, k)
  local v = 1
  for i = 1, k do
    v = v * (n - i + 1) / i
  end
  return v
end

-- 60 cards: 10 red lands, 10 blue lands, 4 blue-red duals, 36 spells.
local R, U, UR = 8, 2, 10
local DECK = { size = 60, lands = { [R] = 10, [U] = 10, [UR] = 4 }, others = {} }
local POOL = curve.pool(DECK, 1)

describe('curve.requirements', function()
  it('counts mana value and the symbols that need a colored source', function()
    assert.are.same({ mv = 4, pips = { 1, 1 } }, curve.requirements('{2}{W}{W}'))
    assert.are.same({ mv = 1, pips = { R } }, curve.requirements('{X}{R}'))
    assert.are.same({ mv = 2, pips = { UR, UR } }, curve.requirements('{U/R}{U/R}'))
    assert.are.same({ mv = 3, pips = { 32 } }, curve.requirements('{2}{C}'))
  end)

  it('needs no colored source for Phyrexian or {2/X} symbols', function()
    assert.are.same({ mv = 2, pips = {} }, curve.requirements('{1}{R/P}'))
    assert.are.same({ mv = 6, pips = {} }, curve.requirements('{2/W}{2/W}{2/W}'))
  end)
end)

describe('curve.produces', function()
  it('reads produced mana from lands only', function()
    assert.are.equal(UR, curve.produces({ type_line = 'Land', produced_mana = { 'U', 'R' } }))
    assert.are.equal(0, curve.produces({ type_line = 'Land' }))
  end)

  it('counts a land face of a modal double-faced card', function()
    local card = { type_line = 'Sorcery // Land', produced_mana = { 'W' } }
    assert.are.equal(1, curve.produces(card))
  end)

  it('counts a land that fetches lands as every color', function()
    local card = {
      type_line = 'Land',
      oracle_text = '{T}, Sacrifice Evolving Wilds: Search your library for a basic land card, put it onto the battlefield tapped, then shuffle.',
    }
    assert.are.equal(31, curve.produces(card))
  end)

  it('counts mana creatures and rocks but not rituals', function()
    assert.are.equal(16, curve.produces({ type_line = 'Creature — Elf Druid', produced_mana = { 'G' } }))
    assert.are.equal(6, curve.produces({ type_line = 'Artifact', produced_mana = { 'U', 'B' } }))
    assert.is_nil(curve.produces({ type_line = 'Instant', produced_mana = { 'B' } }))
    assert.is_nil(curve.produces({ type_line = 'Creature — Bear' }))
  end)

  it('adds snow to snow lands', function()
    assert.are.equal(16 + 64, curve.produces({ type_line = 'Basic Snow Land — Forest', produced_mana = { 'G' } }))
  end)
end)

describe('curve.chance', function()
  it('matches the hypergeometric chance of one source in the opening hand', function()
    local play = curve.chance(POOL, curve.requirements('{R}'), 7)
    assert.is_near(1 - binom(46, 7) / binom(60, 7), play, 1e-12)
  end)

  it('gives the plain land chance for colorless costs', function()
    local castable, lands = curve.chance(POOL, curve.requirements('{1}'), 7)
    assert.is_near(1 - binom(36, 7) / binom(60, 7), lands, 1e-12)
    assert.are.equal(lands, castable)
  end)

  it('lets a dual land pay only one symbol', function()
    -- One dual and nothing else cannot pay {U}{R}.
    local deck = { size = 8, by_mask = { [UR] = 1, [0] = 1 } }
    assert.are.equal(0, (curve.chance(deck, curve.requirements('{U}{R}'), 8)))
    deck = { size = 8, by_mask = { [UR] = 2 } }
    assert.are.equal(1, (curve.chance(deck, curve.requirements('{U}{R}'), 8)))
  end)

  it('lets either color pay a hybrid symbol', function()
    local deck = { size = 2, by_mask = { [R] = 1, [U] = 1 } }
    assert.are.equal(1, (curve.chance(deck, curve.requirements('{U/R}{U/R}'), 2)))
    assert.are.equal(0, (curve.chance(deck, curve.requirements('{R}{R}'), 2)))
  end)

  -- From a 100,000-hand simulation of DECK.
  it('agrees with simulated draws', function()
    assert.is_near(0.792, (curve.chance(POOL, curve.requirements('{U}{R}'), 8)), 0.01)
    assert.is_near(0.629, (curve.chance(POOL, curve.requirements('{1}{U}{U}'), 9)), 0.01)
    assert.is_near(0.564, (curve.chance(POOL, curve.requirements('{2}{R}{R}'), 10)), 0.01)
  end)
end)

describe('curve.odds', function()
  it('draws one more card on the draw', function()
    local odds = curve.odds(DECK, '{1}{U}{U}')
    assert.are.equal(3, odds.turn)
    assert.are.equal((curve.chance(POOL, curve.requirements('{1}{U}{U}'), 9)), odds.play)
    assert.are.equal((curve.chance(POOL, curve.requirements('{1}{U}{U}'), 10)), odds.draw)
    local castable, lands = curve.chance(POOL, curve.requirements('{1}{U}{U}'), 9)
    assert.is_near(castable / lands, odds.colors, 1e-12)
  end)

  it('skips costs with mana value 0', function()
    assert.is_nil(curve.odds(DECK, '{0}'))
    assert.is_nil(curve.odds(DECK, '{X}'))
  end)

  it('counts nonland sources only for cards that cost more', function()
    local deck = { size = 60, lands = { [R] = 20 }, others = { { mask = 16, mv = 1, count = 4 } } }
    local one, two = curve.odds(deck, '{G}'), curve.odds(deck, '{1}{G}')
    assert.are.equal(0, one.play)
    assert.are.same({ size = 60, lands = 20, others = 4, by_mask = { [R] = 20, [16] = 4 } }, two.pool)
    assert.is_true(two.play > 0)
  end)

  it('builds the deck from card data', function()
    local cards = {
      Mountain = { type_line = 'Basic Land — Mountain', produced_mana = { 'R' } },
      Elves = { type_line = 'Creature — Elf Druid', cmc = 1, produced_mana = { 'G' } },
      Bolt = { type_line = 'Instant', cmc = 1 },
    }
    local deck = curve.deck({
      { name = 'Mountain', count = 20 },
      { name = 'Elves', count = 4 },
      { name = 'Bolt', count = 4 },
    }, function(name)
      return cards[name]
    end)
    assert.are.same({ size = 28, lands = { [R] = 20 }, others = { { mask = 16, mv = 1, count = 4 } } }, deck)
  end)

  it('counts sources of each symbol', function()
    assert.are.equal(14, curve.sources(POOL, R))
    assert.are.equal(24, curve.sources(POOL, UR))
    assert.are.equal('{U}{R}', curve.symbols(UR))
  end)
end)
