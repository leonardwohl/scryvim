local colors = require('scryvim.colors')
local icons = require('scryvim.icons')

describe('icons', function()
  local W, U, B, R, G = icons.DEFAULTS.W, icons.DEFAULTS.U, icons.DEFAULTS.B, icons.DEFAULTS.R, icons.DEFAULTS.G

  after_each(function()
    vim.g.scryvim = nil
  end)

  it('is off by default', function()
    assert.is_nil(icons.map())
    assert.are.equal('{1}{R}', icons.replace('{1}{R}'))
    assert.are.same({ { '{R}', 'red' } }, colors.mana_chunks('{R}'))
  end)

  it('replaces mana symbols with icons, spaced from the text after them', function()
    vim.g.scryvim = { icons = true }
    assert.are.equal('1 ' .. R .. ' // ' .. U, icons.replace('{1}{R} // {U}'))
    assert.are.equal(W .. '/' .. U .. ' ' .. B .. '/Φ 2/' .. G, icons.replace('{W/U} {B/P} {2/G}'))
    -- A hybrid symbol is spaced from the next one, but not inside.
    assert.are.equal(W .. '/' .. U .. ' ' .. R, icons.replace('{W/U}{R}'))
    -- Symbols with a part that has no icon stay as text.
    assert.are.equal('{HR}{Y}{foo}', icons.replace('{HR}{Y}{foo}'))
    -- Tap and untap are arrows turning right and left.
    local T, Q, E = icons.DEFAULTS.T, icons.DEFAULTS.Q, icons.DEFAULTS.E
    assert.are.equal(T .. ' : Add ' .. G .. ' . ' .. Q, icons.replace('{T}: Add {G}. {Q}'))
    -- Energy is a lightning bolt.
    assert.are.equal('Get ' .. E .. ' ' .. E, icons.replace('Get {E}{E}'))
  end)

  it('shows numbers and X as plain text', function()
    vim.g.scryvim = { icons = true }
    assert.are.equal('15 X ' .. R .. ' 0', icons.replace('{15}{X}{R}{0}'))
    vim.g.scryvim = { icons = { ['1'] = 'c', X = false } }
    assert.are.equal('c ' .. R .. ' {X}2', icons.replace('{1}{R}{X}{2}'))
  end)

  it('takes overrides, and false keeps a symbol as text', function()
    vim.g.scryvim = { icons = { R = 'r', P = false } }
    assert.are.equal('r ' .. G .. ' {G/P}', icons.replace('{R}{G}{G/P}'))
  end)

  it('keeps each half of a hybrid symbol in its own color', function()
    vim.g.scryvim = { icons = true }
    assert.are.same(
      { { W .. '/', 'white' }, { U, 'blue' }, { ' ' }, { G .. '/Φ', 'green' } },
      colors.mana_chunks('{W/U} {G/P}')
    )
  end)

  it('conceals mana symbols in buffers', function()
    vim.g.scryvim = { icons = true }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '4 Lightning Bolt  {R}', '{W/U}{R}', '{1}{R}' })
    colors.highlight_buf(buf, false)
    local marks = vim.tbl_map(function(m)
      return { m[2], m[3], m[4].end_col, m[4].conceal }
    end, vim.api.nvim_buf_get_extmarks(buf, icons.ns, 0, -1, { details = true }))
    assert.are.same({
      { 0, 18, 21, R },
      { 1, 0, 2, W },
      { 1, 3, 4, U },
      { 1, 4, 5, ' ' },
      { 1, 5, 8, R },
      { 2, 0, 1, '' },
      { 2, 2, 3, ' ' },
      { 2, 3, 6, R },
    }, marks)
    -- No colors with `color` false.
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buf, colors.ns, 0, -1, {}))
    -- With colors, each icon is drawn in its mana color.
    colors.highlight_buf(buf)
    local groups = vim.tbl_map(function(m)
      return { m[2], m[3], m[4].hl_group }
    end, vim.api.nvim_buf_get_extmarks(buf, icons.ns, 0, -1, { details = true }))
    assert.are.same({
      { 0, 18, 'ScryvimManaRed' },
      { 1, 0, 'ScryvimManaWhite' },
      { 1, 3, 'ScryvimManaBlue' },
    }, vim.list_slice(groups, 1, 3))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
