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

  it('recognises sections, comments and blanks', function()
    for _, s in ipairs({ 'Deck', 'Sideboard', 'COMMANDER', 'Companion:', 'maybeboard' }) do
      assert.are.equal('section', parse.parse(s).kind, s)
    end
    assert.are.equal('comment', parse.parse('// burn').kind)
    assert.are.equal('comment', parse.parse('  # notes').kind)
    assert.are.equal('blank', parse.parse('   ').kind)
    assert.are.equal('blank', parse.parse('').kind)
  end)

  it('allows an empty name while typing', function()
    assert.is_nil(parse.card('4 '))
    local p = parse.card('4 ', true)
    assert.are.equal('', p.name)
    assert.are.same({ 2, 2 }, p.name_range)
  end)
end)
