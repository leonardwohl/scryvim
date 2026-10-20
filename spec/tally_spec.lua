local count = require('scryvim.count')
local helpers = require('helpers')
local http = require('scryvim.http')
local tally = require('scryvim.tally')

describe('tally.query', function()
  it('reads count comment lines', function()
    assert.are.same({ 'otag:removal' }, { tally.query('// count: otag:removal') })
    assert.are.same({ 'produces:r', 'red sources' }, { tally.query('  // Count red sources:  produces:r ') })
    assert.are.same({ 't:creature', 'creatures' }, { tally.query('# count creatures: t:creature') })
    assert.are.same({ 't:land' }, { tally.query('// count  : t:land') })
    assert.is_nil(tally.query('// counterspells: t:instant'))
    assert.is_nil(tally.query('// count:'))
    assert.is_nil(tally.query('4 Count of Monte Cristo: the card'))
  end)

  it('reads mana symbol lines', function()
    assert.is_true(tally.is_mana('// count mana symbols'))
    assert.is_true(tally.is_mana('  # Count  Mana Symbols  '))
    assert.is_false(tally.is_mana('// count mana symbols: t:land'))
    assert.is_false(tally.is_mana('// mana symbols'))
    assert.is_nil(tally.query('// count mana symbols'))
  end)
end)

describe('tally', function()
  local orig = http.get_json
  local buf, requests

  -- Scryfall stand-in: names in `matching` match every query; a query
  -- starting with `(bad` fails.
  local function serve(matching)
    http.get_json = function(url, cb)
      local query = vim.uri_decode(url:match('q=(.*)$'))
      requests[#requests + 1] = query
      if query:find('^%(bad') then
        return vim.schedule(function()
          cb('Scryfall error (bad_request): bad query')
        end)
      end
      local out = {}
      for name in query:gmatch('!"(.-)"') do
        if matching[name] then
          out[#out + 1] = { name = name }
        end
      end
      -- Like Scryfall, ignore an unknown keyword and warn about it.
      local warnings = query:find('^%(prodces') and { 'Unknown keyword “prodces”.' } or nil
      vim.schedule(function()
        cb(nil, { object = 'list', data = out, warnings = warnings })
      end)
    end
  end

  local function marks()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, tally.ns, 0, -1, { details = true })) do
      out[m[2]] = { m[4].virt_text[1][1], m[4].virt_text[1][2] }
    end
    return out
  end

  local function settle(want)
    vim.wait(1000, function()
      return vim.deep_equal(marks(), want)
    end, 10)
    assert.are.same(want, marks())
  end

  before_each(function()
    requests = {}
    count._reset()
    tally.DEBOUNCE_MS = 10
    serve({ Mountain = true, ['Lightning Bolt'] = true })
    buf = vim.api.nvim_create_buf(true, false)
  end)

  after_each(function()
    tally.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    http.get_json = orig
  end)

  it('shows totals by quantity on count lines', function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      '// count red sources: produces:r',
      '// just a comment',
      '20 Mountain',
      '4 Lightning Bolt',
      '10 Island',
      'Sideboard',
      '3 Mountain',
    })
    tally.attach(buf)
    settle({ [0] = { '24 red sources', 'LspInlayHint' } })
  end)

  it('updates as the deck changes, asking only about new cards', function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '// count: produces:r', '20 Mountain' })
    tally.attach(buf)
    settle({ [0] = { '20 cards', 'LspInlayHint' } })
    local before = #requests
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '22 Mountain', '1 Island' })
    settle({ [0] = { '22 cards', 'LspInlayHint' } })
    assert.are.equal(before + 1, #requests)
    assert.falsy(requests[#requests]:find('Mountain', 1, true))
  end)

  it('shows query errors on their line', function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '// count: bad(', '// count: produces:r', '1 Mountain' })
    tally.attach(buf)
    settle({
      [0] = { 'Scryfall error (bad_request): bad query', 'DiagnosticError' },
      [1] = { '1 card', 'LspInlayHint' },
    })
  end)

  it('shows an unknown keyword as an error instead of counting everything', function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '// count red sources: prodces:r', '20 Mountain' })
    tally.attach(buf)
    settle({ [0] = { 'Unknown keyword “prodces”.', 'DiagnosticError' } })
  end)

  it('sends nothing without count lines and clears marks when they go', function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '20 Mountain' })
    tally.attach(buf)
    vim.wait(50, function()
      return false
    end)
    assert.are.equal(0, #requests)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '// count: produces:r' })
    settle({ [0] = { '20 cards', 'LspInlayHint' } })
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
    settle({})
  end)
end)

describe('tally mana symbols', function()
  local orig = http.get_json
  local buf

  local function marks()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, tally.ns, 0, -1, { details = true })) do
      out[m[2]] = table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, m[4].virt_text))
    end
    return out
  end

  local function settle(want)
    vim.wait(1000, function()
      return vim.deep_equal(marks(), want)
    end, 10)
    assert.are.same(want, marks())
  end

  setup(function()
    helpers.block_network()
    helpers.load_fixture()
  end)

  before_each(function()
    count._reset()
    tally.DEBOUNCE_MS = 10
    http.get_json = function(_, cb)
      vim.schedule(function()
        cb(nil, { object = 'list', data = {} })
      end)
    end
    buf = vim.api.nvim_create_buf(true, false)
  end)

  after_each(function()
    tally.detach(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    http.get_json = orig
  end)

  it('shows the deck mana symbols by quantity, without the sideboard', function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      '// count mana symbols',
      '4 Counterspell',
      '2 Fire // Ice',
      '1 Wrath of God',
      '3 Delver of Secrets',
      '20 Island',
      'Sideboard',
      '3 Duress',
    })
    tally.attach(buf)
    settle({ [0] = '{W} 2  {U} 13  {R} 2' })
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '1 Lightning Bolt' })
    settle({ [0] = '{W} 2  {U} 5  {R} 3' })
  end)

  it('shows next to count lines', function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '// count: t:land', '# count mana symbols', '20 Island' })
    tally.attach(buf)
    settle({ [0] = '0 cards', [1] = 'no mana symbols' })
  end)
end)
