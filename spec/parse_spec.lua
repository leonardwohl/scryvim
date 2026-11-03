local parse = require('scryvim.parse')

describe('parse', function()
  it('parses counts in every style', function()
    local cases = {
      { '4 Lightning Bolt', 4, 'Lightning Bolt' },
      { '4x Lightning Bolt', 4, 'Lightning Bolt' },
      { 'Lightning Bolt', 1, 'Lightning Bolt' },
      { '4 Lightning Bolt (M10) 146', 4, 'Lightning Bolt' },
      { '4 Lightning Bolt [M10]', 4, 'Lightning Bolt' },
      { '  12   Island  ', 12, 'Island' },
    }
    for _, c in ipairs(cases) do
      local p = parse.parse(c[1])
      assert.are.equal('card', p.kind, c[1])
      assert.are.equal(c[2], p.count, c[1])
      assert.are.equal(c[3], p.name, c[1])
    end
  end)

  it('round-trips prefix .. name .. suffix', function()
    for _, line in ipairs({ '4x Lightning Bolt (M10) 146', 'SB: 2 Duress', '  Bolt  ', '1 Fire // Ice [MH2]' }) do
      local p = parse.parse(line)
      assert.are.equal(line, p.prefix .. p.name .. p.suffix)
    end
  end)

  it('reports 0-based end-exclusive byte ranges', function()
    local p = parse.parse('4x Lightning Bolt (M10) 146')
    assert.are.same({ 0, 1 }, p.count_range)
    assert.are.same({ 3, 17 }, p.name_range)
    assert.are.equal('Lightning Bolt', ('4x Lightning Bolt (M10) 146'):sub(p.name_range[1] + 1, p.name_range[2]))
    assert.is_nil(parse.parse('Bolt').count_range)
  end)

  it('keeps SB: in the prefix', function()
    local p = parse.parse('SB: 2 Duress')
    assert.are.equal('card', p.kind)
    assert.are.equal(2, p.count)
    assert.are.equal('Duress', p.name)
    assert.are.equal('SB: 2 ', p.prefix)
  end)

  it('takes Sideboard: as a line prefix like SB:', function()
    local p = parse.parse('Sideboard: 2 Duress')
    assert.are.equal('card', p.kind)
    assert.are.equal(2, p.count)
    assert.are.equal('Duress', p.name)
    assert.are.equal('Sideboard: 2 ', p.prefix)
    assert.are.equal('Duress', parse.parse('  SIDEBOARD:Duress').name)
    assert.are.equal('section', parse.parse('Sideboard:').kind)
  end)

  it('recognises sections, comments and blanks', function()
    for _, s in ipairs({ 'Deck', 'Sideboard', 'COMMANDER', 'Companion:', 'maybeboard' }) do
      assert.are.equal('section', parse.parse(s).kind, s)
    end
    assert.are.equal('comment', parse.parse('// burn').kind)
    assert.are.equal('comment', parse.parse('  # notes').kind)
    assert.are.equal('blank', parse.parse('   ').kind)
    assert.are.equal('blank', parse.parse('').kind)
  end)

  it('tells SB: card lines apart', function()
    assert.is_true(parse.is_sb(parse.parse('SB: 2 Duress')))
    assert.is_true(parse.is_sb(parse.parse('  sb:1 Duress')))
    assert.is_true(parse.is_sb(parse.parse('Sideboard: 2 Duress')))
    assert.is_false(parse.is_sb(parse.parse('Sideboard:')))
    assert.is_false(parse.is_sb(parse.parse('2 Duress')))
    assert.is_false(parse.is_sb(parse.parse('Sideboard')))
    assert.is_false(parse.is_sb(parse.parse('// SB: 2 Duress')))
  end)

  it('allows an empty name while typing', function()
    assert.is_nil(parse.card('4 '))
    local p = parse.card('4 ', true)
    assert.are.equal('', p.name)
    assert.are.same({ 2, 2 }, p.name_range)
  end)
end)

describe('parse count lines', function()
  local function query(line)
    local p = parse.parse(line)
    return p.kind == 'comment' and p.count == 'query' and { p.query, p.label } or nil
  end
  local function is_count(line, what)
    local p = parse.parse(line)
    return p.kind == 'comment' and p.count == what
  end

  it('reads count comment lines', function()
    assert.are.same({ 'otag:removal' }, query('// count: otag:removal'))
    assert.are.same({ 'produces:r', 'red sources' }, query('  // Count red sources:  produces:r '))
    assert.are.same({ 't:creature', 'creatures' }, query('# count creatures: t:creature'))
    assert.are.same({ 't:land' }, query('// count  : t:land'))
    assert.is_nil(query('// counterspells: t:instant'))
    assert.is_nil(query('// count:'))
    assert.is_nil(query('4 Count of Monte Cristo: the card'))
    assert.are.equal('card', parse.parse('4 Count of Monte Cristo: the card').kind)
  end)

  it('reads header-style count lines', function()
    assert.are.same({ 'o:changeling', 'changelings' }, query('# changelings (o:changeling)'))
    assert.are.same({ 'produces:r', 'Red sources' }, query('  // Red sources ( produces:r )  '))
    assert.are.same({ 't:creature' }, query('# (t:creature)'))
    assert.are.same(
      { 'otag:removal (t:instant or t:sorcery)', 'Removal' },
      query('# Removal (otag:removal (t:instant or t:sorcery))')
    )
    assert.are.same(
      { '(t:instant or t:sorcery) cmc<=2', 'Cheap spells' },
      query('# Cheap spells ((t:instant or t:sorcery) cmc<=2)')
    )
    assert.are.same({ 'o:draw', 'Card draw (cantrips too)' }, query('# Card draw (cantrips too) (o:draw)'))
    assert.are.same({ '!"Lightning Bolt"', 'Bolts' }, query('# Bolts (!"Lightning Bolt")'))
    assert.is_nil(query('# cut these (too slow)'))
    assert.is_nil(query('# Ramp (t:land) for now'))
    assert.is_nil(query('# Removal (otag:removal'))
    assert.is_nil(query('# Removal ()'))
  end)

  it('reads mana symbol lines', function()
    assert.is_true(is_count('// count mana symbols', 'mana'))
    assert.is_true(is_count('  # Count  Mana Symbols  ', 'mana'))
    assert.is_false(is_count('// count mana symbols: t:land', 'mana'))
    assert.is_false(is_count('// mana symbols', 'mana'))
    assert.is_nil(query('// count mana symbols'))
  end)

  it('reads card count lines', function()
    assert.is_true(is_count('// count cards', 'cards'))
    assert.is_true(is_count('  # Count  Cards  ', 'cards'))
    assert.is_false(is_count('// count cards: t:land', 'cards'))
    assert.are.same({ 't:land', 'cards' }, query('// count cards: t:land'))
    assert.is_false(is_count('// cards', 'cards'))
    assert.is_false(is_count('// count cards', 'mana'))
    assert.is_nil(query('// count cards'))
  end)

  it('keeps count lines as comments', function()
    assert.are.same({ kind = 'comment', count = 'mana' }, parse.parse('// count mana symbols'))
    assert.are.same(
      { kind = 'comment', count = 'query', query = 'produces:r', label = 'red sources' },
      parse.parse('// count red sources: produces:r')
    )
    assert.are.same({ kind = 'comment' }, parse.parse('// burn'))
  end)
end)
