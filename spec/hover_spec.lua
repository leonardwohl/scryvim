local hover = require('scryvim.hover')

describe('hover', function()
  local function float(ft, lines)
    local src = vim.api.nvim_create_buf(true, false)
    vim.bo[src].filetype = ft
    vim.api.nvim_set_current_buf(src)
    return vim.lsp.util.open_floating_preview(lines, 'markdown', {})
  end

  it('finds floats opened from deck buffers only', function()
    local fbuf, fwin = float('deck', { '**Bolt**' })
    assert.are.equal(fwin, hover.deck_float(fbuf))
    vim.api.nvim_win_close(fwin, true)
    fbuf, fwin = float('lua', { '**Bolt**' })
    assert.is_nil(hover.deck_float(fbuf))
    vim.api.nvim_win_close(fwin, true)
  end)

  it('narrows wide floats and grows them to fit the wrapped text', function()
    vim.o.columns = 200
    local _, fwin = float('deck', { '**Bolt**', ('word '):rep(30) })
    assert.is_true(vim.api.nvim_win_get_width(fwin) > 40)
    hover.fit(fwin, 40)
    assert.are.equal(40, vim.api.nvim_win_get_width(fwin))
    assert.are.equal(vim.api.nvim_win_text_height(fwin, {}).all, vim.api.nvim_win_get_height(fwin))
    assert.is_true(vim.api.nvim_win_get_height(fwin) >= 5)
    vim.api.nvim_win_close(fwin, true)
  end)

  it('leaves narrow floats and a 0 limit alone', function()
    vim.o.columns = 200
    local _, fwin = float('deck', { '**Bolt**', ('word '):rep(30) })
    local width = vim.api.nvim_win_get_width(fwin)
    hover.fit(fwin, 0)
    hover.fit(fwin, 500)
    assert.are.equal(width, vim.api.nvim_win_get_width(fwin))
    vim.api.nvim_win_close(fwin, true)
  end)
end)
