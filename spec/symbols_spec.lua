local symbols = require('scryvim.symbols')

describe('symbols.cost', function()
  it('counts colored, colorless and snow symbols but not generic mana', function()
    assert.are.same({ W = 2, C = 1, S = 1 }, symbols.cost('{2}{W}{W}{C}{S}{X}'))
  end)

  it('splits hybrid symbols between their halves', function()
    assert.are.same({ R = 0.5, G = 0.5 }, symbols.cost('{R/G}'))
    assert.are.same({ R = 0.5 }, symbols.cost('{2/R}'))
    assert.are.same({ W = 0.5, C = 0.5 }, symbols.cost('{C/W}'))
  end)

  it('counts phyrexian and half symbols as half', function()
    assert.are.same({ R = 0.5 }, symbols.cost('{R/P}'))
    assert.are.same({ G = 0.25, W = 0.25 }, symbols.cost('{G/W/P}'))
    assert.are.same({ W = 0.5 }, symbols.cost('{HW}'))
  end)

  it('multiplies by quantity and adds to earlier totals', function()
    local out = symbols.cost('{U}{U}', nil, 4)
    symbols.cost('{U/R}', out, 3)
    assert.are.same({ U = 9.5, R = 1.5 }, out)
  end)

  it('ignores empty and missing costs', function()
    assert.are.same({}, symbols.cost(''))
    assert.are.same({}, symbols.cost(nil))
  end)
end)

describe('symbols.card', function()
  it('counts every face with a mana cost', function()
    -- Split card: the top-level cost repeats the faces and isn't counted twice.
    local fire_ice = {
      mana_cost = '{1}{R} // {1}{U}',
      card_faces = { { mana_cost = '{1}{R}' }, { mana_cost = '{1}{U}' } },
    }
    assert.are.same({ R = 1, U = 1 }, symbols.card(fire_ice))
    -- Adventure: both costs.
    local bonecrusher = {
      mana_cost = '{2}{R} // {R}',
      card_faces = { { mana_cost = '{2}{R}' }, { mana_cost = '{R}' } },
    }
    assert.are.same({ R = 4 }, symbols.card(bonecrusher, nil, 2))
    -- Transform: the back face has no cost.
    local delver = { card_faces = { { mana_cost = '{U}' }, { mana_cost = '' } } }
    assert.are.same({ U = 1 }, symbols.card(delver))
  end)

  it('uses the top-level cost of single-faced cards', function()
    assert.are.same({ B = 1, U = 1 }, symbols.card({ mana_cost = '{U}{B}' }))
    assert.are.same({}, symbols.card({ mana_cost = '' }))
  end)
end)

describe('symbols.format', function()
  it('lists types in WUBRG order, then colorless and snow, leaving out zeros', function()
    assert.are.equal('{W} 3  {R} 12.5  {C} 1  {S} 2', symbols.format({ S = 2, R = 12.5, C = 1, W = 3, G = 0 }))
    assert.are.equal('no mana symbols', symbols.format({}))
  end)
end)
