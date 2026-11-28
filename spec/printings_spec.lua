local helpers = require('helpers')
local http = require('scryvim.http')
local parse = require('scryvim.parse')
local printings = require('scryvim.printings')

-- A Scryfall card object for a printing.
local function card(name, set, number, extra)
  local id = ('%s-%s'):format(set, number)
  return vim.tbl_extend('force', {
    object = 'card',
    name = name,
    set = set,
    collector_number = number,
    set_name = set:upper() .. ' set',
    released_at = '2009-07-17',
    rarity = 'common',
    mana_cost = '{R}',
    type_line = 'Instant',
    scryfall_uri = ('https://scryfall.com/card/%s/%s/x?utm_source=api'):format(set, number),
    image_uris = { normal = ('https://cards.scryfall.io/normal/front/a/b/%s.jpg?123'):format(id) },
  }, extra or {})
end

describe('parse set codes', function()
  it('keeps the set code and collector number', function()
    local function set_of(line)
      local p = parse.card(line)
      return { p.name, p.set, p.number }
    end
    assert.are.same({ 'Lightning Bolt', 'm10', '146' }, set_of('4 Lightning Bolt (M10) 146'))
    assert.are.same({ 'Lightning Bolt', 'm10', nil }, set_of('4x Lightning Bolt (M10)'))
    assert.are.same({ 'Lightning Bolt', 'm10', nil }, set_of('SB: 1 Lightning Bolt [M10]'))
    assert.are.same({ 'Lightning Bolt', 'plst', 'CLB-187' }, set_of('1 Lightning Bolt (PLST) CLB-187 *F*'))
    assert.are.same({ 'Lightning Bolt', 'm10', nil }, set_of('1 Lightning Bolt (M10) *F*'))
    assert.are.same({ 'Lightning Bolt', nil, nil }, set_of('4 Lightning Bolt'))
    assert.are.same({ 'Lightning Bolt', nil, nil }, set_of('4 Lightning Bolt ()'))
  end)
end)

describe('printings', function()
  local orig = http._system
  local requests

  -- Answer each URL from `answers` (an object, or a status number).
  local function serve(answers)
    http._system = function(cmd, on_exit)
      local url = cmd[#cmd]
      requests[#requests + 1] = url
      local a = answers[url]
      local body, status = '', 404
      if type(a) == 'table' then
        body, status = vim.json.encode(a), 200
      elseif a == 404 then
        body = vim.json.encode({ object = 'error', code = 'not_found', status = 404, details = 'no' })
      elseif type(a) == 'number' then
        body, status = '<html></html>', a
      end
      on_exit({ code = a == 'fail' and 7 or 0, stdout = body .. '\n' .. status, stderr = 'curl: (7) offline' })
    end
  end

  local function resolve(wanted)
    local problems
    printings.resolve(wanted, function(p)
      problems = p
    end)
    assert(vim.wait(5000, function()
      return problems ~= nil
    end))
    return problems
  end

  before_each(function()
    helpers.load_fixture()
    printings._reset()
    http._reset()
    requests = {}
  end)

  after_each(function()
    http._system = orig
    http._reset()
  end)

  it('builds keys and lookup URLs', function()
    assert.are.equal('m10/146', printings.key('M10', '146', 'Lightning Bolt'))
    assert.are.equal('m10//lightning bolt', printings.key('M10', nil, 'Lightning Bolt'))
    assert.are.equal('https://api.scryfall.com/cards/m10/146', printings.url('M10', '146', 'x'))
    assert.are.equal(
      'https://api.scryfall.com/cards/named?exact=Lightning%20Bolt&set=m10',
      printings.url('m10', nil, 'Lightning Bolt')
    )
  end)

  it('lists the printings a deck wants, once each', function()
    local wanted = printings.wanted({
      '4 Lightning Bolt (M10) 146',
      'SB: 1 Lightning Bolt (M10) 146',
      '2 Counterspell [TMP]',
      '20 Mountain',
      '// note (M10)',
    })
    assert.are.same({ 'm10/146', 'tmp//counterspell' }, {
      wanted[1].key,
      wanted[2].key,
    })
    assert.are.equal(2, #wanted)
  end)

  it('looks printings up once, saves them to disk, and reports missing ones', function()
    serve({
      ['https://api.scryfall.com/cards/m10/146'] = card('Lightning Bolt', 'm10', '146'),
      ['https://api.scryfall.com/cards/named?exact=Counterspell&set=tmp'] = card('Counterspell', 'tmp', '57'),
      ['https://api.scryfall.com/cards/m10/999'] = 404,
      ['https://api.scryfall.com/cards/zzz/1'] = 400,
    })
    local wanted = printings.wanted({
      '4 Lightning Bolt (M10) 146',
      '4 Counterspell [TMP]',
      '1 Lightning Bolt (M10) 999',
      '1 Island (ZZZ) 1',
    })
    local problems = resolve(wanted)
    assert.are.same({ { key = 'm10/999', missing = true }, { key = 'zzz/1', missing = true } }, problems)
    assert.are.same({
      name = 'Lightning Bolt',
      image = 'front/a/b/m10-146.jpg',
      scryfall_uri = 'https://scryfall.com/card/m10/146/x',
    }, printings.get('m10/146'))
    assert.are.equal('front/a/b/tmp-57.jpg', printings.get('tmp//counterspell').image)

    -- Known and missing printings aren't asked about again, even after a
    -- restart for the saved ones.
    requests = {}
    printings._reset()
    problems = resolve(wanted)
    assert.are.same({
      'https://api.scryfall.com/cards/m10/999',
      'https://api.scryfall.com/cards/zzz/1',
    }, vim.fn.sort(requests))
    requests = {}
    resolve(wanted)
    assert.are.same({}, requests)
    assert.are.equal(2, #problems)
  end)

  it('reports failed requests without remembering them', function()
    serve({ ['https://api.scryfall.com/cards/m10/146'] = 'fail' })
    local problems = resolve(printings.wanted({ '4 Lightning Bolt (M10) 146' }))
    assert.are.equal('m10/146', problems[1].key)
    assert.matches('curl failed', problems[1].err)
    assert.is_nil(printings.get('m10/146'))
  end)

  it('keeps the face image of a double-faced printing', function()
    serve({
      ['https://api.scryfall.com/cards/isd/51'] = card('Delver of Secrets // Insectile Aberration', 'isd', '51', {
        image_uris = vim.NIL,
        card_faces = {
          {
            name = 'Delver of Secrets',
            image_uris = { normal = 'https://cards.scryfall.io/normal/front/1/2/d.jpg?1' },
          },
          {
            name = 'Insectile Aberration',
            image_uris = { normal = 'https://cards.scryfall.io/normal/back/1/2/d.jpg?1' },
          },
        },
      }),
    })
    resolve(printings.wanted({ '4 Delver of Secrets (ISD) 51' }))
    local p = printings.get('isd/51')
    assert.are.equal('front/1/2/d.jpg', p.image)
    assert.is_true(printings.matches(p, 'delver of secrets'))
    assert.is_true(printings.matches(p, 'Delver of Secrets // Insectile Aberration'))
    assert.is_false(printings.matches(p, 'Lightning Bolt'))
  end)

  it('sets a line to a printing, keeping the rest of it', function()
    local bolt = card('Lightning Bolt', 'm10', '146')
    assert.are.equal('4 Lightning Bolt (M10) 146', printings.set_line('4 Lightning Bolt', bolt))
    assert.are.equal('4x Lightning Bolt (M10) 146', printings.set_line('4x Lightning Bolt (LEA) 161', bolt))
    assert.are.equal('SB: 2 Lightning Bolt (M10) 146', printings.set_line('SB: 2 Lightning Bolt [LEA]', bolt))
    assert.are.equal('1 Lightning Bolt (M10) 146 *F*', printings.set_line('1 Lightning Bolt (LEA) 161 *F*', bolt))
    assert.are.equal('1 Lightning Bolt (M10) 146 *F*', printings.set_line('1 Lightning Bolt (LEA) *F*', bolt))
  end)

  it('marks the line printing in the list', function()
    local bolt = card('Lightning Bolt', 'm10', '146')
    assert.matches('^%* %(M10%) 146 +M10 set +2009%-07%-17$', printings.format_item(bolt, 'm10/146'))
    assert.matches('^  %(M10%) 146', printings.format_item(bolt, 'lea/161'))
  end)

  it('picks a printing and rewrites the card line', function()
    local search = http.SEARCH_URL .. http.urlencode('!"Lightning Bolt" unique:prints order:released direction:desc')
    serve({
      [search] = {
        object = 'list',
        total_cards = 2,
        has_more = false,
        data = { card('Lightning Bolt', 'm10', '146'), card('Lightning Bolt', 'lea', '161') },
      },
    })
    local shown
    require('scryvim.picker')._clear_cache()
    require('scryvim.config').setup({
      picker = {
        pick = function(items, opts)
          shown = vim.tbl_map(opts.format_item, items)
          assert.matches('LEA set', opts.preview(items[2]))
          opts.on_choose({ items[2] })
        end,
      },
    })
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Deck', '4 lightning bolt (M10) 146 *F*' })
    printings.pick(buf, 2)
    assert(vim.wait(3000, function()
      return shown ~= nil
    end))
    assert.matches('^%* %(M10%) 146', shown[1])
    assert.are.same({ 'Deck', '4 lightning bolt (LEA) 161 *F*' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.api.nvim_buf_delete(buf, { force = true })
    require('scryvim.config').setup()
  end)

  describe('in the deck page', function()
    local scryvim = require('scryvim')
    local headless, notify = scryvim._headless, vim.notify
    local messages

    before_each(function()
      scryvim._headless = function()
        return false
      end
      messages = {}
      vim.notify = function(msg)
        messages[#messages + 1] = msg
      end
    end)

    after_each(function()
      scryvim._headless, vim.notify = headless, notify
    end)

    local function render_file(lines)
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      local f = assert(io.open(dir .. '/d.deck', 'wb'))
      f:write(table.concat(lines, '\n'))
      f:close()
      local ret = scryvim.render({ files = { dir .. '/d.deck' } })
      assert(vim.wait(5000, function()
        return #messages > 0
      end))
      f = io.open(dir .. '/d.md', 'rb')
      local out = f and f:read('*a')
      if f then
        f:close()
      end
      return out, ret
    end

    it('shows the looked up printing', function()
      serve({
        ['https://api.scryfall.com/cards/m10/146'] = card('Lightning Bolt', 'm10', '146'),
        ['https://api.scryfall.com/cards/m10/147'] = card('Shock', 'm10', '147'),
      })
      local out, ret = render_file({ '4 Lightning Bolt (M10) 146', '1 Fireball (M10) 147', '2 Counterspell' })
      -- Asked Scryfall first, so the answer came later.
      assert.is_nil(ret)
      assert.matches(
        '<a href="https://scryfall.com/card/m10/146/x"><img src="https://cards.scryfall.io/normal/front/a/b/m10-146.jpg"',
        out,
        1,
        true
      )
      -- Another card's printing: the default image, with a warning.
      assert.matches('normal/front/0/0/00000000-0000-0000-0000-000000000012.jpg', out, 1, true)
      assert.matches('%(M10%) 147 is Shock, not Fireball', messages[1])
      assert.matches('normal/front/0/0/00000000-0000-0000-0000-000000000002.jpg', out, 1, true)
    end)

    it("doesn't write a page whose printings couldn't be looked up", function()
      serve({ ['https://api.scryfall.com/cards/m10/146'] = 'fail' })
      local out = render_file({ '4 Lightning Bolt (M10) 146' })
      assert.is_nil(out)
      assert.matches('printing lookup failed', messages[1])
    end)
  end)
end)
