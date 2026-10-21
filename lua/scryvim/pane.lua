--- Preview pane: a split on the right of the tab that follows the cursor in
--- deck windows. A card line shows the card, spaced out more than hover since
--- the pane has the room. A count line lists
--- the deck cards it counts, and a mana symbols line the cards with symbols.
--- Below a nonland card are its odds of being cast on curve.
local colors = require('scryvim.colors')
local config = require('scryvim.config')
local count = require('scryvim.count')
local curve = require('scryvim.curve')
local data = require('scryvim.data')
local parse = require('scryvim.parse')
local render = require('scryvim.render')
local symbols = require('scryvim.symbols')
local tally = require('scryvim.tally')

local M = {}

--- Delay after a cursor move, so holding `j` draws once at the end.
M.MOVE_MS = 30

-- Tabpage -> { win, buf, timer, generation, tick }.
local panes = {} ---@type table<integer, table>
local group
local unsubscribe

local function by_count(a, b)
  if a.count ~= b.count then
    return a.count > b.count
  end
  return a.name < b.name
end

--- `4 Lightning Bolt  {R}` for each entry, most copies first.
local function card_list(entries)
  table.sort(entries, by_count)
  local out = {}
  for _, e in ipairs(entries) do
    local card = data.get(e.name)
    local cost = card and render.mana_cost(card)
    out[#out + 1] = ('%d %s'):format(e.count, e.name) .. (cost and ('  ' .. cost) or '')
  end
  return out
end

-- Never rounds to 0% or 100% unless exact.
local function percent(p)
  local n = math.floor(p * 100 + 0.5)
  if n == 100 and p < 1 then
    return '>99%'
  elseif n == 0 and p > 0 then
    return '<1%'
  end
  return n .. '%'
end

-- Odds for the deck last shown, by mana cost, so moving between cards
-- doesn't redo them.
local odds_cache = { deck = nil, by_cost = {} }

local function odds_for(deck, cost)
  local key = vim.inspect(deck)
  if odds_cache.deck ~= key then
    odds_cache = { deck = key, by_cost = {} }
  end
  local hit = odds_cache.by_cost[cost]
  if hit == nil then
    hit = curve.odds(deck, cost) or false
    odds_cache.by_cost[cost] = hit
  end
  return hit or nil
end

local function plural(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

--- The on-curve section for `card` in the deck `entries`: per nonland face
--- with a mana cost, the chance to cast it on the turn of its mana value.
local function curve_lines(card, entries)
  local faces = {}
  for _, face in ipairs(card.card_faces or {}) do
    if face.mana_cost and face.mana_cost ~= '' and not curve.is_land(face) then
      faces[#faces + 1] = face
    end
  end
  if not card.card_faces and not curve.is_land(card) then
    faces[1] = card
  end
  local deck = curve.deck(entries, data.get)
  local out = {}
  for _, face in ipairs(faces) do
    local odds = deck.size > 0 and odds_for(deck, face.mana_cost or '')
    if odds then
      local head = #faces > 1 and ('On curve: %s, turn %d'):format(face.name, odds.turn)
        or ('On curve: turn %d'):format(odds.turn)
      vim.list_extend(out, { '', '---', '', '**' .. head .. '**', '' })
      local pool = odds.pool
      if pool.lands + pool.others == 0 then
        out[#out + 1] = '*No mana sources in the deck*'
      else
        out[#out + 1] = ('%s on the play, %s on the draw'):format(percent(odds.play), percent(odds.draw))
        local of = plural(pool.lands, 'land')
        if pool.others > 0 then
          of = of .. ' and ' .. plural(pool.others, 'other source')
        end
        if odds.colors then
          local seen, sources = {}, {}
          for _, pip in ipairs(odds.pips) do
            if not seen[pip] then
              seen[pip] = true
              sources[#sources + 1] = curve.symbols(pip) .. ' ' .. curve.sources(pool, pip)
            end
          end
          vim.list_extend(out, {
            '',
            ('%s to have the colors with %s'):format(percent(odds.colors), plural(odds.turn, 'source')),
            '',
            ('Sources: %s of %s'):format(table.concat(sources, '  '), of),
          })
        end
      end
    end
  end
  return out
end

--- The pane text for line `row` (1-based) of `lines`, passed to `cb` as a
--- list of lines; nil leaves the pane as it is. `cb` may run later, when a
--- count needs Scryfall.
---@param lines string[]
---@param row integer
---@param cb fun(text: string[]|nil)
function M.content(lines, row, cb)
  local line = lines[row] or ''
  local query, label = tally.query(line)
  local mana = not query and tally.is_mana(line)
  if not query and not mana then
    local parsed = parse.parse(line)
    if parsed.kind ~= 'card' then
      return cb(nil)
    end
    if not data.ready() then
      return cb({ '*scryvim: card data is not loaded yet*' })
    end
    local card = data.get(parsed.name)
    if not card then
      return cb({ '*Unknown card: ' .. parsed.name .. '*' })
    end
    local out = vim.split(render.markdown(card, { spacious = true }), '\n', { plain = true })
    return cb(vim.list_extend(out, curve_lines(card, count.entries(lines, data.get))))
  end

  local entries = count.entries(lines, data.get)
  if mana then
    if not data.ready() then
      return cb({ '*scryvim: card data is not loaded yet*' })
    end
    local with = vim.tbl_filter(function(e)
      local card = data.get(e.name)
      return card and next(symbols.card(card)) ~= nil
    end, entries)
    local out = { '**Mana symbols**  ' .. symbols.format(symbols.entries(entries, data.get)), '' }
    return cb(vim.list_extend(out, card_list(with)))
  end
  count.run(query, entries, function(err, result)
    if err then
      return cb({ '**' .. query .. '**', '', '*' .. err .. '*' })
    end
    local total = result.total
    local out = {
      ('**%d %s**  %s'):format(total, label or (total == 1 and 'card' or 'cards'), query),
      '',
    }
    cb(vim.list_extend(out, card_list(vim.deepcopy(result.matches))))
  end)
end

local function valid(pane)
  return pane ~= nil and vim.api.nvim_win_is_valid(pane.win) and vim.api.nvim_buf_is_valid(pane.buf)
end

local function show(pane, text)
  vim.bo[pane.buf].modifiable = true
  vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, text)
  vim.bo[pane.buf].modifiable = false
  if config.get().colors then
    colors.highlight_buf(pane.buf)
  end
  vim.api.nvim_win_set_cursor(pane.win, { 1, 0 })
end

--- Redraw the pane in the current tab from the cursor line, when the
--- current window shows a deck.
function M.refresh()
  local pane = panes[vim.api.nvim_get_current_tabpage()]
  local buf = vim.api.nvim_get_current_buf()
  if not valid(pane) or vim.bo[buf].filetype ~= 'deck' then
    return
  end
  pane.generation = pane.generation + 1
  local generation = pane.generation
  pane.tick = vim.b[buf].changedtick
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  M.content(lines, vim.api.nvim_win_get_cursor(0)[1], function(text)
    if text and valid(pane) and pane.generation == generation then
      show(pane, text)
    end
  end)
end

-- After an edit, wait like count lines do, so half-typed card names and
-- queries are not sent to Scryfall.
local function schedule()
  local pane = panes[vim.api.nvim_get_current_tabpage()]
  local buf = vim.api.nvim_get_current_buf()
  if not valid(pane) or vim.bo[buf].filetype ~= 'deck' then
    return
  end
  local edited = pane.tick ~= vim.b[buf].changedtick
  pane.timer:stop()
  pane.timer:start(edited and tally.DEBOUNCE_MS or M.MOVE_MS, 0, vim.schedule_wrap(M.refresh))
end

local function forget(tab)
  local pane = panes[tab]
  if not pane then
    return
  end
  panes[tab] = nil
  pane.timer:stop()
  pane.timer:close()
  if next(panes) == nil then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    unsubscribe()
    group, unsubscribe = nil, nil
  end
end

local function setup_autocmds()
  group = vim.api.nvim_create_augroup('scryvim.pane', { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter', 'TextChanged', 'TextChangedI' }, {
    group = group,
    callback = schedule,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      local win = tonumber(args.match)
      for tab, pane in pairs(panes) do
        if pane.win == win then
          forget(tab)
        end
      end
    end,
  })
  -- `:q` in the last deck window closes the pane too, rather than leaving
  -- it as the only window.
  vim.api.nvim_create_autocmd('QuitPre', {
    group = group,
    callback = function()
      local pane = panes[vim.api.nvim_get_current_tabpage()]
      if not valid(pane) or vim.api.nvim_get_current_win() == pane.win then
        return
      end
      local others = vim.tbl_filter(function(w)
        return w ~= pane.win and vim.api.nvim_win_get_config(w).relative == ''
      end, vim.api.nvim_tabpage_list_wins(0))
      if #others == 1 then
        vim.api.nvim_win_close(pane.win, true)
      end
    end,
  })
  unsubscribe = data.on_ready(vim.schedule_wrap(function()
    local tab = vim.api.nvim_get_current_tabpage()
    if panes[tab] then
      M.refresh()
    end
  end))
end

--- Whether the current tab has a preview pane.
function M.is_open()
  return valid(panes[vim.api.nvim_get_current_tabpage()])
end

--- Open the pane on the right of the current tab, keeping the cursor where
--- it is.
function M.open()
  if M.is_open() then
    return
  end
  local tab = vim.api.nvim_get_current_tabpage()
  forget(tab)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, false, {
    split = 'right',
    win = -1,
    width = config.get().pane.width,
  })
  for opt, value in pairs({
    winfixwidth = true,
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    spell = false,
    list = false,
    wrap = true,
    linebreak = true,
    conceallevel = 2,
  }) do
    vim.wo[win][opt] = value
  end
  -- Treesitter directly rather than filetype=markdown, which would run
  -- markdown ftplugins and autocmds on every redraw.
  pcall(vim.treesitter.start, buf, 'markdown')
  if not group then
    setup_autocmds()
  end
  panes[tab] = { win = win, buf = buf, timer = assert(vim.uv.new_timer()), generation = 0 }
  M.refresh()
end

--- Close the pane in the current tab.
function M.close()
  local tab = vim.api.nvim_get_current_tabpage()
  local pane = panes[tab]
  if pane and vim.api.nvim_win_is_valid(pane.win) then
    vim.api.nvim_win_close(pane.win, true)
  end
  forget(tab)
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

return M
