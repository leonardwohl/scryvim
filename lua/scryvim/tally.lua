--- Saved counts in the deck file: `// count <label>: <query>` comment lines
--- show how many deck cards match their query, refreshed as the deck
--- changes. The optional label names the total: `40 red sources`.
--- `// count mana symbols` lines show the deck's mana symbols by type, and
--- `// count cards` lines the deck's size.
local colors = require('scryvim.colors')
local config = require('scryvim.config')
local count = require('scryvim.count')
local data = require('scryvim.data')
local parse = require('scryvim.parse')
local render = require('scryvim.render')
local symbols = require('scryvim.symbols')

local M = {}

M.ns = vim.api.nvim_create_namespace('scryvim.tally')

--- Quiet time after an edit before asking Scryfall, so half-typed card
--- names and queries are not sent.
M.DEBOUNCE_MS = 1000

-- Buffer -> { timer, generation, unsubscribe }.
local attached = {} ---@type table<integer, table>

local function cards_text(stats)
  local breakdown = stats.lands
    and stats.cards > 0
    and render.plural(stats.lands, 'land') .. '  ' .. render.plural(stats.cards - stats.lands, 'nonland')
  return render.plural(stats.cards, 'card'), breakdown or nil
end

--- `60 cards` and `24 lands  36 nonlands` for the deck `entries`. The
--- breakdown is nil until the card data is loaded, since lands need it.
---@param entries { name: string, count: integer }[]
---@return string total, string|nil breakdown
function M.cards(entries)
  return cards_text(count.stats(entries, data.ready() and data.get or nil))
end

local function mark(buf, row, virt_text)
  vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
    virt_text = virt_text,
    virt_text_pos = 'eol',
    hl_mode = 'combine',
  })
end

--- Recount every count line in `buf` now.
---@param buf integer
function M.refresh(buf)
  local state = attached[buf]
  if not state or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  state.generation = state.generation + 1
  local generation = state.generation
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local rows, mana_rows, card_rows = {}, {}, {}
  for i, line in ipairs(lines) do
    local p = parse.parse(line)
    if p.count == 'query' then
      rows[#rows + 1] = { row = i - 1, query = p.query, label = p.label }
    elseif p.count == 'mana' then
      mana_rows[#mana_rows + 1] = i - 1
    elseif p.count == 'cards' then
      card_rows[#card_rows + 1] = i - 1
    end
  end
  if #rows == 0 and #mana_rows == 0 and #card_rows == 0 then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    return
  end
  local entries = count.entries(lines, data.get)
  local stats = count.stats(entries, data.ready() and data.get or nil)
  -- Mana symbols are counted locally, so they wait for the card data.
  local mana = stats.mana and colors.virt_text(symbols.format(stats.mana), 'LspInlayHint', config.get().colors)
  local total, breakdown = cards_text(stats)
  local cards = { { breakdown and total .. '  ' .. breakdown or total, 'LspInlayHint' } }
  local results = {}

  local function draw()
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    for j, row in ipairs(rows) do
      local res = results[j]
      if res.err then
        mark(buf, row.row, { { res.err, 'DiagnosticError' } })
      else
        local total = res.result.total
        mark(buf, row.row, {
          { ('%d %s'):format(total, row.label or (total == 1 and 'card' or 'cards')), 'LspInlayHint' },
        })
      end
    end
    if mana then
      for _, row in ipairs(mana_rows) do
        mark(buf, row, mana)
      end
    end
    for _, row in ipairs(card_rows) do
      mark(buf, row, cards)
    end
  end

  if #rows == 0 then
    return draw()
  end
  local pending = #rows
  for i, r in ipairs(rows) do
    count.run(r.query, entries, function(err, result)
      results[i] = { err = err, result = result }
      pending = pending - 1
      -- Draw once all are back, so marks never point at moved lines.
      if pending > 0 or attached[buf] ~= state or state.generation ~= generation then
        return
      end
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      draw()
    end)
  end
end

local function schedule(buf, delay)
  local state = attached[buf]
  if not state then
    return
  end
  state.timer:stop()
  state.timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      M.refresh(buf)
    end)
  )
end

---@param buf integer
function M.attach(buf)
  if attached[buf] then
    return
  end
  local state = { timer = assert(vim.uv.new_timer()), generation = 0 }
  attached[buf] = state
  -- Store loads turn typed names into full card names.
  state.unsubscribe = data.on_ready(function()
    schedule(buf, 0)
  end)
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if attached[buf] ~= state then
        return true
      end
      schedule(buf, M.DEBOUNCE_MS)
    end,
    on_reload = function()
      schedule(buf, 0)
    end,
    on_detach = function()
      if attached[buf] == state then
        M.detach(buf)
      end
    end,
  })
  schedule(buf, 0)
end

---@param buf integer
function M.detach(buf)
  local state = attached[buf]
  if state then
    state.unsubscribe()
    state.timer:stop()
    state.timer:close()
    attached[buf] = nil
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

function M.is_attached(buf)
  return attached[buf] ~= nil
end

return M
