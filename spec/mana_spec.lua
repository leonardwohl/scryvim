local helpers = require('helpers')

describe('mana', function()
  local mana, buf

  local function marks()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, mana.ns, 0, -1, { details = true })) do
      local parts = {}
      for _, chunk in ipairs(m[4].virt_text) do
        local hl = chunk[2]
        parts[#parts + 1] = { chunk[1], type(hl) == 'table' and hl[#hl] or hl }
      end
      out[m[2]] = parts
    end
    return out
  end

  local function settle()
    vim.wait(50, function()
      return false
    end)
  end

  setup(function()
    helpers.block_network()
    helpers.load_fixture()
    mana = require('scryvim.mana')
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Deck', '4 Lightning Bolt', '3 Island', '1 Fire // Ice' })
  end)

  teardown(function()
    mana.detach(buf)
  end)

  it('draws colored mana costs at the end of card lines', function()
    mana.attach(buf)
    settle()
    assert.are.same({
      [1] = { { '{R}', 'ScryvimManaRed' } },
      [3] = {
        { '{1}', 'ScryvimManaColorless' },
        { '{R}', 'ScryvimManaRed' },
        { ' // ', 'LspInlayHint' },
        { '{1}', 'ScryvimManaColorless' },
        { '{U}', 'ScryvimManaBlue' },
      },
    }, marks())
  end)

  it('redraws after edits', function()
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '4 Counterspell' })
    settle()
    assert.are.same({ { '{U}', 'ScryvimManaBlue' }, { '{U}', 'ScryvimManaBlue' } }, marks()[1])
  end)

  it('clears its marks on detach', function()
    mana.detach(buf)
    assert.are.same({}, marks())
    assert.is_false(mana.is_attached(buf))
  end)
end)
