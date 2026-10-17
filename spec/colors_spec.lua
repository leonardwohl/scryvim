local colors = require('scryvim.colors')

describe('colors', function()
  it('classifies color identity', function()
    assert.are.equal('red', colors.identity({ color_identity = { 'R' } }))
    assert.are.equal('multicolor', colors.identity({ color_identity = { 'U', 'R' } }))
    assert.are.equal('colorless', colors.identity({ color_identity = {} }))
    -- Caches built before color identity was recorded.
    assert.is_nil(colors.identity({ name = 'Old' }))
  end)

  it('detects lands by their front face', function()
    assert.is_true(colors.is_land({ type_line = 'Basic Land — Island' }))
    assert.is_true(colors.is_land({ type_line = 'Land Creature — Forest Dryad' }))
    assert.is_false(colors.is_land({ type_line = 'Sorcery // Land' }))
    assert.is_false(colors.is_land({ type_line = 'Instant' }))
    assert.is_false(colors.is_land({}))
  end)

  it('builds semantic token indices', function()
    local blue = vim.fn.index(colors.TOKEN_TYPES, 'blue')
    assert.are.same({ blue, 1 }, { colors.token({ color_identity = { 'U' }, type_line = 'Basic Land — Island' }) })
    assert.are.same({ blue, 0 }, { colors.token({ color_identity = { 'U' }, type_line = 'Instant' }) })
    assert.is_nil(colors.token({ type_line = 'Instant' }))
  end)

  it('splits mana costs into colored symbols', function()
    assert.are.same({
      { '{X}', 'colorless' },
      { '{2}', 'colorless' },
      { '{W}', 'white' },
      { '{U/B}', 'multicolor' },
      { '{G/P}', 'green' },
      { '{2/R}', 'red' },
      { '{C}', 'colorless' },
    }, colors.mana_chunks('{X}{2}{W}{U/B}{G/P}{2/R}{C}'))
    assert.are.same({
      { '{1}', 'colorless' },
      { '{R}', 'red' },
      { ' // ' },
      { '{1}', 'colorless' },
      { '{U}', 'blue' },
    }, colors.mana_chunks('{1}{R} // {1}{U}'))
  end)

  it('defines overridable highlight groups', function()
    vim.api.nvim_set_hl(0, 'ScryvimRed', { fg = '#123456' })
    colors.setup_highlights()
    assert.are.equal(tonumber('123456', 16), vim.api.nvim_get_hl(0, { name = 'ScryvimRed' }).fg)
    assert.is_not_nil(vim.api.nvim_get_hl(0, { name = 'ScryvimBlue' }).fg)
    assert.are.equal('ScryvimBlue', vim.api.nvim_get_hl(0, { name = 'ScryvimManaBlue' }).link)
    assert.are.equal('ScryvimGreen', vim.api.nvim_get_hl(0, { name = '@lsp.type.green.deck' }).link)
  end)
end)
