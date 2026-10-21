local helpers = require('helpers')
local statusline = require('scryvim.statusline')

local DECK = {
  '4 Counterspell',
  '2 Fire // Ice',
  '1 Wrath of God',
  '20 Island',
  'Sideboard',
  '3 Duress',
}

describe('statusline', function()
  local buf

  setup(function()
    helpers.block_network()
    helpers.load_fixture()
    require('scryvim.colors').setup_highlights()
  end)

  before_each(function()
    statusline._reset()
    buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = 'deck'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, DECK)
  end)

  after_each(function()
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.g.scryvim = vim.tbl_extend('force', vim.g.scryvim, { colors = true })
  end)

  it('shows the deck size and mana symbols without the sideboard', function()
    assert.are.equal('27 cards  {W} 2  {U} 10  {R} 2', statusline.text(buf))
  end)

  it('takes options for what to show', function()
    assert.are.equal('27 cards  20 lands', statusline.text(buf, { lands = true, mana = false }))
    assert.are.equal('{W} 2  {U} 10  {R} 2', statusline.text(buf, { cards = false }))
  end)

  it('follows edits', function()
    vim.api.nvim_buf_set_lines(buf, 0, 3, false, { '1 Lightning Bolt' })
    assert.are.equal('21 cards  {R} 1', statusline.text(buf))
  end)

  it('is empty outside decks and for empty decks', function()
    vim.bo[buf].filetype = 'text'
    assert.are.equal('', statusline.text(buf))
    vim.bo[buf].filetype = 'deck'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '// notes' })
    assert.are.equal('', statusline.text(buf))
  end)

  it('colors mana symbols for the window being drawn', function()
    local win = vim.api.nvim_open_win(buf, false, { split = 'below' })
    local function eval()
      return vim.api.nvim_eval_statusline("%{%v:lua.require'scryvim'.statusline()%}", { winid = win })
    end
    finally(function()
      vim.api.nvim_win_close(win, true)
    end)
    assert.are.equal('27 cards  {W} 2  {U} 10  {R} 2', eval().str)
    local function groups()
      local res =
        vim.api.nvim_eval_statusline("%{%v:lua.require'scryvim'.statusline()%}", { winid = win, highlights = true })
      return vim.tbl_map(function(h)
        return h.group
      end, res.highlights)
    end
    assert.is_true(vim.tbl_contains(groups(), 'ScryvimManaBlue'))
    vim.g.scryvim = vim.tbl_extend('force', vim.g.scryvim, { colors = false })
    assert.is_false(vim.tbl_contains(groups(), 'ScryvimManaBlue'))
  end)
end)

-- Needs a lualine.nvim checkout in SCRYVIM_TEST_PLUGINS.
local plugins = os.getenv('SCRYVIM_TEST_PLUGINS')
local suite = plugins and describe or pending

suite('lualine component (real plugin)', function()
  local buf, win

  setup(function()
    helpers.block_network()
    helpers.load_fixture()
    vim.opt.rtp:prepend(plugins .. '/lualine.nvim')
    require('scryvim.colors').setup_highlights()
    require('lualine').setup({
      options = { theme = 'auto', icons_enabled = false, section_separators = '', component_separators = '' },
      sections = {
        lualine_a = {},
        lualine_b = {},
        lualine_c = {},
        lualine_x = { 'scryvim' },
        lualine_y = {},
        lualine_z = {},
      },
      inactive_sections = { lualine_c = { { 'scryvim', lands = true, mana = false } }, lualine_x = {} },
    })
  end)

  before_each(function()
    statusline._reset()
    buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = 'deck'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, DECK)
    win = vim.api.nvim_open_win(buf, true, { split = 'below' })
  end)

  after_each(function()
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- What lualine draws for `winid`, as the current window or not.
  local function eval(winid, focused)
    local stl = vim.api.nvim_win_call(winid, function()
      return require('lualine').statusline(focused)
    end)
    return vim.api.nvim_eval_statusline(stl or '', { winid = winid, highlights = true })
  end

  it('shows the deck stats with colored mana symbols', function()
    local res = eval(win, true)
    assert.are.equal('27 cards  {W} 2  {U} 10  {R} 2', vim.trim(res.str))
    local blue = vim.iter(res.highlights):find(function(h)
      return h.group:match('^lualine_x_scryvim_blue')
    end)
    assert.is_not_nil(blue)
    local want = vim.api.nvim_get_hl(0, { name = 'ScryvimManaBlue', link = false }).fg
    assert.are.equal(want, vim.api.nvim_get_hl(0, { name = blue.group, link = false }).fg)
  end)

  it('takes the statusline options and is empty outside decks', function()
    local other = vim.api.nvim_create_buf(true, false)
    local owin = vim.api.nvim_open_win(other, true, { split = 'below' })
    finally(function()
      vim.api.nvim_win_close(owin, true)
      vim.api.nvim_buf_delete(other, { force = true })
    end)
    assert.are.equal('', vim.trim(eval(owin, true).str))
    assert.are.equal('27 cards  20 lands', vim.trim(eval(win, false).str))
  end)
end)
