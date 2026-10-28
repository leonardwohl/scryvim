-- The built-in results popup (picker = 'buffer').
local results = require('scryvim.picker.buffer')

local ITEMS = {
  { name = 'Lightning Bolt', mana_cost = '{R}', type_line = 'Instant' },
  { name = 'Counterspell', mana_cost = '{U}{U}', type_line = 'Instant' },
  { name = 'Llanowar Elves', mana_cost = '{G}', type_line = 'Creature — Elf Druid' },
}

local function names(cards)
  return vim.tbl_map(function(c)
    return c.name
  end, cards or {})
end

local function open(result)
  return results.pick(ITEMS, {
    prompt = 'Scryfall: test',
    color = true,
    format_item = function(card)
      return card.name .. ' ' .. card.mana_cost
    end,
    preview = function(card)
      return '**' .. card.name .. '**  ' .. card.mana_cost
    end,
    on_choose = function(cards)
      result.chosen = cards
    end,
  })
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'mx', false)
  -- Headless Neovim only fires CursorMoved on redraw.
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_get_current_buf() })
end

local function preview_text(ui)
  return table.concat(vim.api.nvim_buf_get_lines(ui.preview_buf, 0, -1, false), '\n')
end

local function floats()
  local n = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      n = n + 1
    end
  end
  return n
end

describe('results popup', function()
  local origin

  before_each(function()
    vim.o.columns, vim.o.lines = 200, 50
    -- Earlier specs can leave insert mode pending (telescope's prompt).
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
    vim.cmd('silent! only! | enew!')
    origin = vim.api.nvim_get_current_win()
  end)

  after_each(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= '' then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end)

  it('lists every card in a focused normal-mode buffer with a preview', function()
    local ui = open({})
    assert.are.equal(ui.list_win, vim.api.nvim_get_current_win())
    assert.are.equal('n', vim.api.nvim_get_mode().mode)
    assert.are.same(
      { 'Lightning Bolt {R}', 'Counterspell {U}{U}', 'Llanowar Elves {G}' },
      vim.api.nvim_buf_get_lines(ui.list_buf, 0, -1, false)
    )
    assert.is_false(vim.bo[ui.list_buf].modifiable)
    assert.are.equal('**Lightning Bolt**  {R}', preview_text(ui))
    local marks = vim.api.nvim_buf_get_extmarks(ui.list_buf, -1, 0, -1, { details = true })
    assert.is_true(#marks >= 3, 'mana symbols are colored')
  end)

  it('follows the cursor with j and / search', function()
    local ui = open({})
    feed('j')
    assert.are.equal('**Counterspell**  {U}{U}', preview_text(ui))
    feed('/Elves<CR>')
    assert.are.equal(3, vim.api.nvim_win_get_cursor(ui.list_win)[1])
    assert.are.equal('**Llanowar Elves**  {G}', preview_text(ui))
  end)

  it('adds the card under the cursor on <CR> and returns to the deck', function()
    local result = {}
    open(result)
    feed('j<CR>')
    assert.are.same({ 'Counterspell' }, names(result.chosen))
    assert.are.equal(0, floats())
    assert.are.equal(origin, vim.api.nvim_get_current_win())
  end)

  it('adds marked cards in list order', function()
    local result = {}
    open(result)
    feed('G<Tab>gg<Tab><CR>')
    assert.are.same({ 'Lightning Bolt', 'Llanowar Elves' }, names(result.chosen))
  end)

  it('unmarks on a second <Tab> and counts marks in the footer', function()
    local result = {}
    local ui = open(result)
    feed('<Tab><Tab>')
    local footer = vim.api.nvim_win_get_config(ui.list_win).footer
    assert.truthy(vim.inspect(footer):find('2 marked', 1, true))
    feed('k<Tab>')
    footer = vim.api.nvim_win_get_config(ui.list_win).footer
    assert.truthy(vim.inspect(footer):find('1 marked', 1, true))
    feed('<CR>')
    assert.are.same({ 'Lightning Bolt' }, names(result.chosen))
  end)

  it('marks and adds visual selections', function()
    local result = {}
    open(result)
    feed('jVj<CR>')
    assert.are.same({ 'Counterspell', 'Llanowar Elves' }, names(result.chosen))

    result = {}
    open(result)
    feed('Vj<Tab>G<CR>')
    assert.are.same({ 'Lightning Bolt', 'Counterspell' }, names(result.chosen))
  end)

  it('closes without choosing on q, and when the popup is left', function()
    local result = {}
    open(result)
    feed('q')
    assert.is_nil(result.chosen)
    assert.are.equal(0, floats())

    open(result)
    vim.api.nvim_set_current_win(origin)
    vim.wait(100, function()
      return floats() == 0
    end)
    assert.are.equal(0, floats())
    assert.is_nil(result.chosen)
  end)

  it('appends later pages, keeping marks and the cursor', function()
    local result = {}
    local ui = results.pick({ ITEMS[1] }, {
      prompt = 'Scryfall: test',
      color = true,
      loading = true,
      format_item = function(card)
        return card.name .. ' ' .. card.mana_cost
      end,
      preview = function(card)
        return card.name
      end,
      on_choose = function(cards)
        result.chosen = cards
      end,
    })
    assert.truthy(vim.inspect(vim.api.nvim_win_get_config(ui.list_win).title):find('(1…)', 1, true))
    feed('<Tab>')
    ui.append({ ITEMS[2], ITEMS[3] }, false)
    assert.are.equal(3, vim.api.nvim_buf_line_count(ui.list_buf))
    assert.truthy(vim.inspect(vim.api.nvim_win_get_config(ui.list_win).title):find('(3)', 1, true))
    local hl = vim.api.nvim_buf_get_extmarks(ui.list_buf, require('scryvim.colors').ns, { 2, 0 }, { 2, -1 }, {})
    assert.are.equal(1, #hl)
    feed('G<Tab><CR>')
    assert.are.same({ 'Lightning Bolt', 'Llanowar Elves' }, names(result.chosen))
    -- Pages that arrive after the popup closed are dropped.
    ui.append({ ITEMS[1] }, false)
  end)

  it('highlights the deck count of cards already in the deck', function()
    local function in_deck(card)
      return card.name == 'Counterspell' and 2 or 0
    end
    local ui = results.pick({ ITEMS[1] }, {
      prompt = 'Scryfall: test',
      in_deck = in_deck,
      format_item = function(card)
        local n = in_deck(card)
        return ('%3s %s'):format(n > 0 and n .. 'x' or '', card.name)
      end,
      preview = function(card)
        return card.name
      end,
      on_choose = function() end,
    })
    ui.append({ ITEMS[2], ITEMS[3] }, false)
    local ns = vim.api.nvim_get_namespaces()['scryvim.results']
    local marks = vim.api.nvim_buf_get_extmarks(ui.list_buf, ns, 0, -1, { details = true })
    assert.are.equal(1, #marks)
    assert.are.equal(1, marks[1][2])
    assert.are.equal(1, marks[1][3])
    assert.are.equal(3, marks[1][4].end_col)
    assert.are.equal('ScryvimInDeck', marks[1][4].hl_group)
  end)

  it('stacks the preview below the list on narrow screens', function()
    vim.o.columns = 100
    local list, preview = results.layout()
    assert.are.equal(list.col, preview.col)
    assert.is_true(preview.row > list.row + list.height)
    vim.o.columns = 200
    list, preview = results.layout()
    assert.are.equal(list.row, preview.row)
    assert.is_true(preview.col > list.col + list.width)
  end)
end)
