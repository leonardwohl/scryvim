local count = require('scryvim.count')
local helpers = require('helpers')
local http = require('scryvim.http')
local pane = require('scryvim.pane')
local tags = require('scryvim.tags')
local tally = require('scryvim.tally')

local DECK = {
  '# red (produces:r)',
  '// count mana symbols',
  '4 Lightning Bolt',
  '2 Counterspell',
  '20 Mountain',
  '',
  'Sideboard',
  '3 Duress',
  '// count cards',
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
    local dir = helpers.load_fixture()
    require('scryvim.build').tags(helpers.root .. '/spec/fixtures/oracle-tags.json', dir .. '/tags.txt')
  end)

  before_each(function()
    count._reset()
    tags._reset()
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
      'On curve (turn 1): 100% on the play, 100% on the draw',
      '',
      '100% to draw 1 source',
      '',
      '100% to have the colors with 1 source',
      '',
      'Sources: {R} 20 of 20 lands',
      '',
      '---',
      '',
      'Oracle tags: burn, removal',
    }, content(3))
  end)

  it('says when a card has no oracle tags', function()
    local out = content(5)
    assert.are.same({ '---', '', '*No oracle tags*' }, vim.list_slice(out, #out - 2))
  end)

  it('shows the tags once the tag list arrives', function()
    local cache_dir = vim.g.scryvim.cache_dir
    local download = http.download
    vim.g.scryvim = { cache_dir = vim.fn.tempname(), auto_download = true }
    local finish
    http.download = function(_, path, cb)
      vim.fn.mkdir(vim.fs.dirname(path), 'p')
      vim.uv.fs_copyfile(helpers.root .. '/spec/fixtures/oracle-tags.json', path)
      finish = cb
    end
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    pane.open()
    local ok, err = pcall(function()
      assert.are.equal('*Loading oracle tags…*', pane_lines()[#pane_lines()])
      finish(nil)
      vim.wait(10000, function()
        return pane_lines()[#pane_lines()] == 'Oracle tags: counterspell'
      end, 10)
      assert.are.equal('Oracle tags: counterspell', pane_lines()[#pane_lines()])
    end)
    http.download = download
    vim.g.scryvim = { cache_dir = cache_dir, auto_download = false }
    assert(ok, err)
  end)

  it('leaves the tags out with pane.tags off', function()
    vim.g.scryvim = vim.tbl_extend('force', vim.g.scryvim, { pane = { tags = false } })
    local text = table.concat(content(3), '\n')
    vim.g.scryvim = vim.tbl_extend('force', vim.g.scryvim, { pane = { tags = true } })
    assert.is_nil(text:find('tags', 1, true))
  end)

  it('counts only the sources of the colors a card needs', function()
    local out = content(4)
    assert.are.same({
      'On curve (turn 2): 0% on the play, 0% on the draw',
      '',
      '100% to draw 2 sources',
      '',
      '0% to have the colors with 2 sources',
      '',
      'Sources: {U} 0 of 20 lands',
    }, vim.list_slice(out, #out - 10, #out - 4))
  end)

  it('gives each face with a cost its own odds', function()
    local lines = { '1 Fire // Ice', '30 Mountain', '29 Island' }
    local out
    pane.content(lines, 1, function(text)
      out = text
    end)
    local heads = vim.tbl_filter(function(l)
      return l:match(' on curve ')
    end, out)
    assert.are.same(
      { 'Fire on curve (turn 2)', 'Ice on curve (turn 2)' },
      vim.tbl_map(function(l)
        return l:match('^[^:]*')
      end, heads)
    )
  end)

  it('shows no odds for lands', function()
    local out = content(5)
    assert.is_nil(table.concat(out, '\n'):find('[Oo]n curve'))
  end)

  it('lists the cards a count line counts, without the sideboard', function()
    assert.are.same({ '**24 red**  produces:r', '', '20 Mountain', '4 Lightning Bolt  {R}' }, content(1))
  end)

  it('shows each mana type as a share of the symbols on a mana symbols line', function()
    assert.are.same({
      '**Mana symbols**  {U} 4  {R} 4',
      '',
      '{U}   50%  ' .. ('█'):rep(10),
      '{R}   50%  ' .. ('█'):rep(10),
    }, content(2))
  end)

  it('lists every deck card on a cards line', function()
    assert.are.same({
      '**26 cards**  20 lands  6 nonlands',
      '',
      '20 Mountain',
      '4 Lightning Bolt  {R}',
      '2 Counterspell  {U}{U}',
    }, content(9))
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

  describe('auto_open', function()
    local columns

    before_each(function()
      columns = vim.o.columns
    end)

    after_each(function()
      vim.o.columns = columns
    end)

    local function resize(n)
      vim.o.columns = n
      pane.fit()
    end

    it('opens only when the editor is at least min_columns wide', function()
      vim.o.columns = 99
      pane.auto_open()
      assert.is_false(pane.is_open())
      vim.o.columns = 100
      pane.auto_open()
      assert.is_true(pane.is_open())
    end)

    it('opens beside a deck once the editor widens', function()
      vim.o.columns = 80
      pane.auto_open()
      resize(90)
      assert.is_false(pane.is_open())
      resize(160)
      assert.is_true(pane.is_open())
    end)

    it('closes when the editor narrows and comes back when it widens', function()
      vim.o.columns = 160
      pane.auto_open()
      resize(140)
      assert.is_true(pane.is_open())
      resize(80)
      assert.is_false(pane.is_open())
      assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
      resize(160)
      assert.is_true(pane.is_open())
    end)

    it('stays closed after a resize once closed by hand', function()
      vim.o.columns = 160
      pane.auto_open()
      pane.close()
      resize(80)
      resize(160)
      assert.is_false(pane.is_open())
    end)

    it('keeps a pane opened by hand on a narrow editor until it narrows again', function()
      vim.o.columns = 80
      pane.open()
      resize(70)
      assert.is_true(pane.is_open())
      resize(160)
      resize(80)
      assert.is_false(pane.is_open())
    end)
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
        '1/1',
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
