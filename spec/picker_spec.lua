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
          has_more = true,
          next_page = 'https://api.scryfall.com/cards/search?page=2',
        })
      else
        cb(nil, { data = { { name = 'Shock' } }, has_more = true, next_page = 'never' })
      end
    end
    local seen
    vim.g.scryvim = {
      search = { max_pages = 2 },
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
    picker.search('t:instant c:r')
    http.get_json = orig
    vim.g.scryvim = nil

    assert.are.same(
      { 'https://api.scryfall.com/cards/search?q=t%3Ainstant%20c%3Ar', 'https://api.scryfall.com/cards/search?page=2' },
      urls
    )
    assert.are.same({ { name = 'Bolt' }, { name = 'Shock' } }, seen)
    assert.are.same({ '1 Opt', '1 Shock' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
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
