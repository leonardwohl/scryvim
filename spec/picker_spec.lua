local helpers = require('helpers')
local picker = require('scryvim.picker')

local function card(name)
  return { name = name, mana_cost = '{R}', type_line = 'Instant' }
end

local function buffer(lines, row)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { row or 1, 0 })
  return buf
end

describe('picker', function()
  before_each(function()
    helpers.block_network()
    picker._clear_cache()
  end)

  it('increments existing lines, keeping their style', function()
    local buf = buffer({ 'Bolt', '4 Shock', '4x Duress', 'SB: Island' })
    picker.insert(buf, 1, { card('Bolt'), card('Shock'), card('Duress'), card('Island') })
    assert.are.same({ '2 Bolt', '5 Shock', '5x Duress', 'SB: 2 Island' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it('inserts new cards on consecutive lines below the cursor', function()
    local buf = buffer({ 'Deck', '1 Opt', '', 'Sideboard' }, 2)
    picker.insert(buf, 2, { card('Bolt'), card('Shock') })
    assert.are.same(
      { 'Deck', '1 Opt', '1 Bolt', '1 Shock', '', 'Sideboard' },
      vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    )
  end)

  it('applies many picks as one change and one undo step', function()
    local buf = buffer({ 'Deck', '4 Opt', '', 'Sideboard', '1 Duress' }, 2)
    -- Setting 'undolevels' closes the undo block of the setup lines.
    vim.bo[buf].undolevels = vim.bo[buf].undolevels
    local changes = 0
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function()
        changes = changes + 1
      end,
    })
    local cards = { card('Opt'), card('Duress') }
    for i = 1, 20 do
      cards[#cards + 1] = card('Card ' .. i)
    end
    picker.insert(buf, 2, cards)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal(1, changes)
    assert.are.equal('5 Opt', lines[2])
    assert.are.equal('1 Card 1', lines[3])
    assert.are.equal('1 Card 20', lines[22])
    assert.are.same({ '', 'Sideboard', '2 Duress' }, vim.list_slice(lines, 23))
    vim.cmd('undo')
    assert.are.same({ 'Deck', '4 Opt', '', 'Sideboard', '1 Duress' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it('matches multi-face cards by front face', function()
    local buf = buffer({ '1 Delver of Secrets' })
    picker.insert(buf, 1, {
      { name = 'Delver of Secrets // Insectile Aberration', card_faces = { { name = 'Delver of Secrets' } } },
    })
    assert.are.same({ '2 Delver of Secrets' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it('runs search -> adapter -> insert', function()
    local http = require('scryvim.http')
    local urls = {}
    local orig = http.get_json
    http.get_json = function(url, cb)
      urls[#urls + 1] = url
      if #urls == 1 then
        cb(nil, {
          data = { { name = 'Bolt', prices = {} } },
          total_cards = 1000,
          has_more = true,
          next_page = 'https://api.scryfall.com/cards/search?page=2&q=x',
        })
      else
        cb(nil, { data = { { name = 'Shock' } }, has_more = true, next_page = 'never' })
      end
    end
    local seen
    vim.g.scryvim = {
      search = { max_pages = 3 },
      picker = {
        pick = function(items, opts)
          seen = items
          assert.are.equal('string', type(opts.format_item(items[1])))
          assert.are.equal('string', type(opts.preview(items[1])))
          opts.on_choose({ items[2] })
        end,
      },
    }
    local buf = buffer({ '1 Opt' })
    local notify = vim.notify
    vim.notify = function() end
    picker.search('t:instant c:r')
    vim.notify = notify
    http.get_json = orig
    vim.g.scryvim = nil

    assert.are.same({
      'https://api.scryfall.com/cards/search?q=t%3Ainstant%20c%3Ar',
      'https://api.scryfall.com/cards/search?page=2&q=x',
      'https://api.scryfall.com/cards/search?page=3&q=x',
    }, urls)
    assert.are.same({ { name = 'Bolt' }, { name = 'Shock' }, { name = 'Shock' } }, seen)
    assert.are.same({ '1 Opt', '1 Shock' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it('opens a streaming adapter on the first page and appends the rest', function()
    local orig = picker.fetch
    local finish
    picker.fetch = function(_, _, cb, on_page)
      on_page({ card('Bolt') }, { page = 1, last = false, total_cards = 3 })
      on_page({ card('Shock'), card('Opt') }, { page = 2, last = true, total_cards = 3 })
      finish = cb
    end
    local events = {}
    vim.g.scryvim = {
      picker = {
        streams = true,
        pick = function(items, opts)
          events[#events + 1] = { 'pick', #items, opts.loading }
          return {
            append = function(cards, loading)
              events[#events + 1] = { 'append', #cards, loading }
            end,
          }
        end,
      },
    }
    local notify = vim.notify
    vim.notify = function() end
    picker.search('t:instant')
    finish(nil, { card('Bolt'), card('Shock'), card('Opt') })
    vim.notify = notify
    picker.fetch = orig
    vim.g.scryvim = nil
    assert.are.same({ { 'pick', 1, true }, { 'append', 2, false }, { 'append', 0, false } }, events)
  end)

  describe('fetch', function()
    local http = require('scryvim.http')
    local orig = http.get_json
    local urls, replies

    -- Page 1 answers at once; later pages wait until `reply(n)`.
    local function serve(total, fail)
      urls, replies = {}, {}
      http.get_json = function(url, cb)
        urls[#urls + 1] = url
        local n = tonumber(url:match('[?&]page=(%d+)')) or 1
        local obj = {
          data = { { name = 'Card ' .. n, prices = {} } },
          total_cards = total,
          has_more = total > picker.PAGE_SIZE,
          next_page = 'https://api.scryfall.com/cards/search?page=2&q=x',
        }
        if n == 1 then
          cb(nil, obj)
        else
          replies[n] = function()
            if fail == n then
              cb('boom')
            else
              cb(nil, obj)
            end
          end
        end
      end
    end

    local function reply(n)
      replies[n]()
    end

    after_each(function()
      http.get_json = orig
    end)

    it('hands over pages in order as they arrive', function()
      serve(1000)
      local seen, done = {}, nil
      picker.fetch('t:land', 3, function(err, cards)
        done = { err = err, cards = cards }
      end, function(cards, info)
        seen[#seen + 1] = { cards[1].name, info.page, info.last, info.total_cards }
      end)
      assert.are.same({ { 'Card 1', 1, false, 1000 } }, seen)
      reply(3)
      assert.are.equal(1, #seen)
      reply(2)
      assert.are.same({ 'Card 2', 2, false, 1000 }, seen[2])
      assert.are.same({ 'Card 3', 3, true, 1000 }, seen[3])
      assert.is_nil(done.err)
      assert.are.same({ { name = 'Card 1' }, { name = 'Card 2' }, { name = 'Card 3' } }, done.cards)
    end)

    it('marks a single page as the last', function()
      serve(10)
      local info
      picker.fetch('ashling', 3, function() end, function(_, i)
        info = i
      end)
      assert.are.same({ page = 1, last = true, total_cards = 10 }, info)
      assert.are.equal(1, #urls)
    end)

    it('serves a repeated search from the cache', function()
      serve(1000)
      picker.fetch('t:land', 3, function() end)
      reply(2)
      reply(3)
      assert.are.equal(3, #urls)
      local cards, pages = nil, {}
      picker.fetch('t:land', 3, function(err, c)
        assert.is_nil(err)
        cards = c
      end, function(c, info)
        pages[#pages + 1] = { #c, info }
      end)
      assert.are.equal(3, #urls)
      assert.are.equal(3, #cards)
      assert.are.same({ { 3, { page = 1, last = true, total_cards = 1000 } } }, pages)
      -- A different page limit is a different search.
      picker.fetch('t:land', 2, function() end)
      assert.are.equal(5, #urls)
    end)

    it('does not cache a search with a failed page', function()
      serve(1000, 2)
      local seen, err = {}, nil
      picker.fetch('t:land', 3, function(e)
        err = e
      end, function(cards, info)
        seen[#seen + 1] = { #cards, info.page }
      end)
      reply(2)
      reply(3)
      assert.are.equal('boom', err)
      assert.are.same({ { 1, 1 }, { 0, 2 }, { 1, 3 } }, seen)
      picker.fetch('t:land', 3, function() end)
      assert.are.equal(6, #urls)
    end)

    it('expires cached searches', function()
      serve(10)
      picker.fetch('a', 1, function() end)
      local ttl = picker.CACHE_TTL_MS
      picker.CACHE_TTL_MS = -1
      picker.fetch('a', 1, function() end)
      picker.CACHE_TTL_MS = ttl
      assert.are.equal(2, #urls)
    end)
  end)

  it('resolves auto in order snacks, telescope, fzf-lua, then vim.ui.select', function()
    local orig = picker._available
    local installed = {}
    picker._available = function(module)
      return installed[module] == true
    end
    local names = {}
    for _, add in ipairs({ 'none', 'fzf-lua', 'telescope', 'snacks' }) do
      installed[add] = true
      local _, name = picker.adapter('auto')
      names[#names + 1] = name
    end
    picker._available = orig
    assert.are.same({ 'select', 'fzf_lua', 'telescope', 'snacks' }, names)
  end)
end)
