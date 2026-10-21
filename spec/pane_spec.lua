local count = require('scryvim.count')
local helpers = require('helpers')
local http = require('scryvim.http')
local pane = require('scryvim.pane')
local tally = require('scryvim.tally')

local DECK = {
  '// count red: produces:r',
  '// count mana symbols',
  '4 Lightning Bolt',
  '2 Counterspell',
  '20 Mountain',
  '',
  'Sideboard',
  '3 Duress',
}

describe('pane', function()
  local orig = http.get_json
  local buf

  local function pane_lines()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(win)
      if b ~= buf then
        return vim.api.nvim_buf_get_lines(b, 0, -1, false)
      end
    end
  end

  local function settle(want)
    vim.wait(1000, function()
      return vim.deep_equal(pane_lines(), want)
    end, 10)
    assert.are.same(want, pane_lines())
  end

  local function content(row)
    local out, done = nil, false
    pane.content(DECK, row, function(text)
      out, done = text, true
    end)
    vim.wait(1000, function()
      return done
    end, 10)
    return out
  end

  setup(function()
    helpers.block_network()
    helpers.load_fixture()
  end)

  before_each(function()
    count._reset()
    pane.MOVE_MS = 0
    tally.DEBOUNCE_MS = 10
    -- Scryfall stand-in: Mountain and Lightning Bolt match every query.
    http.get_json = function(url, cb)
      local query = vim.uri_decode(url:match('q=(.*)$'))
      local out = {}
      for name in query:gmatch('!"(.-)"') do
        if name == 'Mountain' or name == 'Lightning Bolt' then
          out[#out + 1] = { name = name }
        end
      end
      vim.schedule(function()
        cb(nil, { object = 'list', data = out })
      end)
    end
    vim.cmd('silent! only')
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, DECK)
    vim.bo[buf].filetype = 'deck'
  end)

  after_each(function()
    pane.close()
    vim.api.nvim_buf_delete(buf, { force = true })
    http.get_json = orig
  end)

  it('shows the card on a card line, with more room than hover, and its odds on curve', function()
    assert.are.same({
      '**Lightning Bolt**  {R}',
      '*Instant*',
      '',
      '---',
      '',
      'Lightning Bolt deals 3 damage to any target.',
      '',
      '---',
      '',
      '**On curve: turn 1**',
      '',
      '100% on the play, 100% on the draw',
      '',
      '100% to have the colors with 1 source',
      '',
      'Sources: {R} 20 of 20 lands',
    }, content(3))
  end)

  it('counts only the sources of the colors a card needs', function()
    local out = content(4)
    assert.are.same({
      '**On curve: turn 2**',
      '',
      '0% on the play, 0% on the draw',
      '',
      '0% to have the colors with 2 sources',
      '',
      'Sources: {U} 0 of 20 lands',
    }, vim.list_slice(out, #out - 6))
  end)

  it('gives each face with a cost its own odds', function()
    local lines = { '1 Fire // Ice', '30 Mountain', '29 Island' }
    local out
    pane.content(lines, 1, function(text)
      out = text
    end)
    local heads = vim.tbl_filter(function(l)
      return l:match('^%*%*On curve')
    end, out)
    assert.are.same({ '**On curve: Fire, turn 2**', '**On curve: Ice, turn 2**' }, heads)
  end)

  it('shows no odds for lands', function()
    local out = content(5)
    assert.is_nil(table.concat(out, '\n'):find('On curve'))
  end)

  it('lists the cards a count line counts, without the sideboard', function()
    assert.are.same({ '**24 red**  produces:r', '', '20 Mountain', '4 Lightning Bolt  {R}' }, content(1))
  end)

  it('lists the cards with mana symbols on a mana symbols line', function()
    assert.are.same({
      '**Mana symbols**  {U} 4  {R} 4',
      '',
      '4 Lightning Bolt  {R}',
      '2 Counterspell  {U}{U}',
    }, content(2))
  end)

  it('leaves the pane alone on other lines', function()
    assert.is_nil(content(6))
    assert.is_nil(content(7))
  end)

  it('opens on the right, follows the cursor and toggles closed', function()
    local deck_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    pane.toggle()
    assert.is_true(pane.is_open())
    assert.are.equal(deck_win, vim.api.nvim_get_current_win())
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.are.equal('**Lightning Bolt**  {R}', pane_lines()[1])

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    settle({ '**24 red**  produces:r', '', '20 Mountain', '4 Lightning Bolt  {R}' })

    pane.toggle()
    assert.is_false(pane.is_open())
    assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it('forgets a pane closed with :close', function()
    pane.open()
    vim.cmd.wincmd('l')
    vim.cmd.close()
    assert.is_false(pane.is_open())
    pane.open()
    assert.is_true(pane.is_open())
  end)
end)

describe('render.markdown spacious', function()
  local render = require('scryvim.render')

  it('puts abilities in their own paragraphs and rules between faces', function()
    local md = render.markdown({
      card_faces = {
        {
          name = 'Front',
          mana_cost = '{U}',
          type_line = 'Creature',
          oracle_text = 'One.\nTwo.',
          power = '1',
          toughness = '1',
        },
        { name = 'Back', type_line = 'Creature', oracle_text = 'Flying' },
      },
    }, { spacious = true })
    assert.are.equal(
      table.concat({
        '**Front**  {U}',
        '*Creature*',
        '',
        '---',
        '',
        'One.',
        '',
        'Two.',
        '',
        'P/T: 1/1',
        '',
        '---',
        '',
        '**Back**',
        '*Creature*',
        '',
        '---',
        '',
        'Flying',
      }, '\n'),
      md
    )
  end)
end)
