local sort = require('scryvim.sort')

local CARDS = {
  ['lightning bolt'] = { name = 'Lightning Bolt', cmc = 1, type_line = 'Instant' },
  ['counterspell'] = { name = 'Counterspell', cmc = 2, type_line = 'Instant' },
  ['brainstorm'] = { name = 'Brainstorm', cmc = 1, type_line = 'Instant' },
  ['wrath of god'] = { name = 'Wrath of God', cmc = 4, type_line = 'Sorcery' },
  ['island'] = { name = 'Island', cmc = 0, type_line = 'Basic Land — Island' },
  ['forest'] = { name = 'Forest', cmc = 0, type_line = 'Basic Land — Forest' },
  ["emeria's call"] = {
    name = "Emeria's Call // Emeria, Shattered Skyclave",
    cmc = 7,
    type_line = 'Sorcery // Land',
    card_faces = { { name = "Emeria's Call", type_line = 'Sorcery' }, { name = 'Emeria', type_line = 'Land' } },
  },
}

local function lookup(name)
  return CARDS[name:lower()]
end

describe('sort', function()
  it('orders spells by cmc then name, then lands, then unknown cards', function()
    local out = sort.lines({
      '4 Island',
      'Mystery Card',
      '2 Wrath of God',
      '4x Lightning Bolt (M10) 146',
      'Another Mystery',
      '1 Counterspell',
      '3 Forest',
      '4 Brainstorm',
    }, lookup)
    assert.are.same({
      '4 Brainstorm',
      '4x Lightning Bolt (M10) 146',
      '1 Counterspell',
      '2 Wrath of God',
      '3 Forest',
      '4 Island',
      'Mystery Card',
      'Another Mystery',
    }, out)
  end)

  it('sorts each block independently around dividers', function()
    local out = sort.lines({
      'Deck',
      '1 Counterspell',
      '1 Lightning Bolt',
      '',
      '// sideboard-ish',
      '1 Wrath of God',
      '1 Brainstorm',
      'Sideboard',
      'SB: 1 Island',
      'SB: 1 Counterspell',
    }, lookup)
    assert.are.same({
      'Deck',
      '1 Lightning Bolt',
      '1 Counterspell',
      '',
      '// sideboard-ish',
      '1 Brainstorm',
      '1 Wrath of God',
      'Sideboard',
      'SB: 1 Counterspell',
      'SB: 1 Island',
    }, out)
  end)

  it('uses the front face to decide whether a card is a land', function()
    local out = sort.lines({ "1 Emeria's Call", '1 Island' }, lookup)
    assert.are.same({ "1 Emeria's Call", '1 Island' }, out)
  end)

  it('finds the block under a row', function()
    local lines = { 'Deck', 'a', 'b', '', 'c' }
    assert.are.same({ 2, 3 }, { sort.block_at(lines, 3) })
    assert.are.same({ 5, 5 }, { sort.block_at(lines, 5) })
    assert.is_nil(sort.block_at(lines, 1))
  end)
end)
