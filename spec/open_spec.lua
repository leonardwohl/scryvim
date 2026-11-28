local open = require('scryvim.open')

describe('open', function()
  local base = 'https://scryfall.com/search?q='

  it('searches the exact name without count, SB: or set code', function()
    local bolt = base .. '%21%22Lightning%20Bolt%22'
    for _, line in ipairs({
      'Lightning Bolt',
      '4 Lightning Bolt',
      '4x Lightning Bolt (M10) 146',
      '  SB: 2 Lightning Bolt [M10]  ',
    }) do
      assert.are.equal(bolt, open.url(line), line)
    end
  end)

  it('encodes split card names and punctuation', function()
    assert.are.equal(base .. '%21%22Fire%20%2F%2F%20Ice%22', open.url('1 Fire // Ice [MH2]'))
    assert.are.equal(base .. '%21%22Jace%2C%20the%20Mind%20Sculptor%22', open.url('Jace, the Mind Sculptor'))
    assert.are.equal(base .. '%21%22R%26D%27s%20Secret%20Lair%22', open.url("R&D's Secret Lair"))
  end)

  it('has no URL for non-card lines', function()
    for _, line in ipairs({ '', 'Sideboard', 'SB:', '// Removal (otag:removal)', '# note' }) do
      assert.is_nil(open.url(line), line)
    end
  end)

  it('opens the cursor line with vim.ui.open', function()
    local orig = vim.ui.open
    local opened
    vim.ui.open = function(url)
      opened = url
      return {}, nil
    end
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Deck', '4 Counterspell' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    require('scryvim').open()
    assert.are.equal(base .. '%21%22Counterspell%22', opened)

    opened = nil
    local notify = vim.notify
    local warned
    vim.notify = function(msg)
      warned = msg
    end
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    require('scryvim').open()
    vim.notify, vim.ui.open = notify, orig
    assert.is_nil(opened)
    assert.are.equal('scryvim: no card on this line', warned)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
