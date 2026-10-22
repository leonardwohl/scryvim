local sort = require('scryvim.sort')

local CARDS = {
  ['lightning bolt'] = { name = 'Lightning Bolt', cmc = 1, type_line = 'Instant' },
  ['counterspell'] = { name = 'Counterspell', cmc = 2, type_line = 'Instant' },
  ['brainstorm'] = { name = 'Brainstorm', cmc = 1, type_line = 'Instant' },
  ['wrath of god'] = { name = 'Wrath of God', cmc = 4, type_line = 'Sorcery' },
  ['island'] = { name = 'Island', cmc = 0, type_line = 'Basic Land — Island' },
  ['forest'] = { name = 'Forest', cmc = 0, type_line = 'Basic Land — Forest' },
  ['badlands'] = { name = 'Badlands', cmc = 0, type_line = 'Land — Swamp Mountain' },
  ["emeria's call"] = {
    name = "Emeria's Call // Emeria, Shattered Skyclave",
    cmc = 7,
    type_line = 'Sorcery // Land',
    card_faces = { { name = "Emeria's Call", type_line = 'Sorcery' }, { name = 'Emeria', type_line = 'Land' } },
  },
}

local function lookup(name)
  return CARDS[name:lower()]
end

describe('sort', function()
  it('orders spells by cmc then name, then lands, then unknown cards', function()
    local out = sort.lines({
      '4 Island',
      'Mystery Card',
      '2 Wrath of God',
      '4x Lightning Bolt (M10) 146',
      'Another Mystery',
      '1 Counterspell',
      '3 Forest',
      '4 Brainstorm',
    }, lookup)
    assert.are.same({
      '4 Brainstorm',
      '4x Lightning Bolt (M10) 146',
      '1 Counterspell',
      '2 Wrath of God',
      '3 Forest',
      '4 Island',
      'Mystery Card',
      'Another Mystery',
    }, out)
  end)

  it('sorts each block independently around dividers', function()
    local out = sort.lines({
      'Deck',
      '1 Counterspell',
      '1 Lightning Bolt',
      '',
      '// sideboard-ish',
      '1 Wrath of God',
      '1 Brainstorm',
      'Sideboard',
      'SB: 1 Island',
      'SB: 1 Counterspell',
    }, lookup)
    assert.are.same({
      'Deck',
      '1 Lightning Bolt',
      '1 Counterspell',
      '',
      '// sideboard-ish',
      '1 Brainstorm',
      '1 Wrath of God',
      'Sideboard',
      'SB: 1 Counterspell',
      'SB: 1 Island',
    }, out)
  end)

  it('sorts a card with a land on any face into the land group', function()
    local out = sort.lines({ "1 Emeria's Call", '1 Badlands', '1 Wrath of God' }, lookup)
    assert.are.same({ '1 Wrath of God', '1 Badlands', "1 Emeria's Call" }, out)
  end)

  it('finds the block under a row', function()
    local lines = { 'Deck', 'a', 'b', '', 'c' }
    assert.are.same({ 2, 3 }, { sort.block_at(lines, 3) })
    assert.are.same({ 5, 5 }, { sort.block_at(lines, 5) })
    assert.is_nil(sort.block_at(lines, 1))
  end)

  it('picks main-deck cards below a count line', function()
    local lines = {
      '1 Counterspell',
      '// count: t:instant',
      '1 Brainstorm',
      'SB: 1 Island',
      'lightning bolt',
      'Sideboard',
      '1 Wrath of God',
    }
    assert.are.same(
      { { row = 3, name = 'Brainstorm' }, { row = 5, name = 'Lightning Bolt' } },
      sort.candidates(lines, 2, lookup)
    )
  end)

  it('picks only its own section for a count line in the sideboard', function()
    local lines = {
      '1 Brainstorm',
      'Sideboard',
      '// count: t:instant',
      '1 Counterspell',
      'Maybeboard',
      '1 Lightning Bolt',
    }
    assert.are.same({ { row = 4, name = 'Counterspell' } }, sort.candidates(lines, 3, lookup))
  end)

  it('gathers rows into a sorted block under the count line', function()
    local lines = {
      '1 Island',
      '// count: t:instant',
      '1 Forest',
      '',
      '// creatures',
      '1 Counterspell',
      '1 Wrath of God',
      '1 Lightning Bolt',
    }
    assert.are.same({
      '1 Lightning Bolt',
      '1 Counterspell',
      '',
      '1 Forest',
      '',
      '// creatures',
      '1 Wrath of God',
    }, sort.gather(lines, 2, { 6, 8 }, lookup))
  end)

  it('adds no separator when a divider already follows the block', function()
    local lines = { '// count: t:instant', '1 Counterspell', '', '1 Brainstorm' }
    assert.are.same({ '1 Brainstorm', '1 Counterspell', '' }, sort.gather(lines, 1, { 2, 4 }, lookup))
  end)
end)

describe('sort on a count line', function()
  local helpers = require('helpers')
  local http = require('scryvim.http')
  local orig = http.get_json
  local buf

  before_each(function()
    helpers.block_network()
    helpers.load_fixture()
    require('scryvim.count')._reset()
    -- Scryfall stand-in: instants match `t:instant`.
    http.get_json = function(url, cb)
      local query = vim.uri_decode(url:match('q=(.*)$'))
      local out = {}
      for name in query:gmatch('!"(.-)"') do
        local card = require('scryvim.data').get(name)
        if card and card.type_line:find('Instant') then
          out[#out + 1] = { name = card.name }
        end
      end
      vim.schedule(function()
        cb(nil, { object = 'list', data = out })
      end)
    end
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    http.get_json = orig
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  local function run(lines, row)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    require('scryvim').sort()
    vim.wait(1000, function()
      return vim.api.nvim_buf_get_changedtick(buf) ~= tick
    end, 10)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  it('moves matching cards below the line into a block under it', function()
    local out = run({
      '1 Brainstorm',
      '// removal (t:instant)',
      '4 Llanowar Elves',
      '2 Counterspell',
      '4 Lightning Bolt',
      '20 Forest',
      'Sideboard',
      '2 Fire // Ice',
    }, 2)
    assert.are.same({
      '1 Brainstorm',
      '// removal (t:instant)',
      '4 Lightning Bolt',
      '2 Counterspell',
      '',
      '4 Llanowar Elves',
      '20 Forest',
      'Sideboard',
      '2 Fire // Ice',
    }, out)
  end)
end)
