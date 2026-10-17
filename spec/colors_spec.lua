local colors = require('scryvim.colors')

describe('colors', function()
  it('finds mana symbols and their colors', function()
    assert.are.same({
      { 0, 3, 'colorless' },
      { 3, 6, 'colorless' },
      { 6, 9, 'white' },
      { 9, 14, 'multicolor' },
      { 14, 19, 'green' },
      { 19, 24, 'red' },
      { 24, 27, 'colorless' },
    }, colors.symbols('{X}{2}{W}{U/B}{G/P}{2/R}{C}'))
    assert.are.same({ { 0, 3, 'colorless' }, { 9, 12, 'green' } }, colors.symbols('{T}: Add {G}. {not a symbol}'))
  end)

  it('splits mana costs into colored chunks', function()
    assert.are.same({
      { '{1}', 'colorless' },
      { '{R}', 'red' },
      { ' // ' },
      { '{1}', 'colorless' },
      { '{U}', 'blue' },
    }, colors.mana_chunks('{1}{R} // {1}{U}'))
    assert.are.same({ { 'Bolt ' }, { '{R}', 'ScryvimManaRed' } }, colors.segments('Bolt {R}'))
  end)

  it('highlights symbols in a buffer', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '**Bolt**  {R}', '{T}: Add {G}.' })
    colors.highlight_buf(buf)
    colors.highlight_buf(buf) -- replaces, not duplicates
    local marks = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, colors.ns, 0, -1, { details = true })) do
      marks[#marks + 1] = { m[2], m[3], m[4].end_col, m[4].hl_group }
    end
    assert.are.same({
      { 0, 10, 13, 'ScryvimManaRed' },
      { 1, 0, 3, 'ScryvimManaColorless' },
      { 1, 9, 12, 'ScryvimManaGreen' },
    }, marks)
    assert.are.same(
      { { row = 2, col = 9, end_col = 12, hl_group = 'ScryvimManaGreen' } },
      colors.extmarks('Add\nTap: Add {G}.')
    )
  end)

  it('colors hover floats opened from deck buffers only', function()
    local function hover_marks(ft)
      local src = vim.api.nvim_create_buf(true, false)
      vim.bo[src].filetype = ft
      vim.api.nvim_set_current_buf(src)
      local fbuf, fwin = vim.lsp.util.open_floating_preview({ '**Bolt**  {R}' }, 'markdown', {})
      colors.highlight_float(fbuf)
      local n = #vim.api.nvim_buf_get_extmarks(fbuf, colors.ns, 0, -1, {})
      vim.api.nvim_win_close(fwin, true)
      return n
    end
    assert.are.equal(1, hover_marks('deck'))
    assert.are.equal(0, hover_marks('lua'))
  end)

  it('paints symbols with ANSI colors', function()
    vim.api.nvim_set_hl(0, 'ScryvimManaRed', { fg = '#102030' })
    assert.are.equal('Bolt \27[38;2;16;32;48m{R}\27[39m!', colors.ansi('Bolt {R}!'))
  end)

  it('defines overridable highlight groups', function()
    vim.api.nvim_set_hl(0, 'ScryvimManaRed', { fg = '#123456' })
    colors.setup_highlights()
    assert.are.equal(tonumber('123456', 16), vim.api.nvim_get_hl(0, { name = 'ScryvimManaRed' }).fg)
    assert.is_not_nil(vim.api.nvim_get_hl(0, { name = 'ScryvimManaBlue' }).fg)
  end)

  it('takes mana colors from the colorscheme', function()
    vim.api.nvim_set_hl(0, 'DiagnosticError', { fg = '#aa0000', ctermfg = 9 })
    vim.api.nvim_set_hl(0, 'Normal', { fg = '#eeeeee' })
    vim.g.terminal_color_5 = '#550055'
    -- The terminal slot still gives the cterm color.
    assert.are.same({ '#aa0000', 1 }, colors.theme_color('red'))
    assert.are.same({ '#550055', 5 }, colors.theme_color('black'))
    assert.are.equal('#eeeeee', colors.theme_color('white')[1])
    -- The terminal palette wins over the diagnostic groups.
    vim.g.terminal_color_1 = '#bb0000'
    assert.are.same({ '#bb0000', 1 }, colors.theme_color('red'))
    vim.g.terminal_color_1 = nil
    -- Nothing defined: the built-in palette.
    vim.g.terminal_color_5 = nil
    vim.o.background = 'dark'
    assert.are.same({ '#b48ead', 5 }, colors.theme_color('black'))
    vim.api.nvim_set_hl(0, 'ScryvimManaRed', {})
    colors.setup_highlights()
    assert.are.equal(tonumber('aa0000', 16), vim.api.nvim_get_hl(0, { name = 'ScryvimManaRed' }).fg)
  end)
end)
