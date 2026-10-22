--- Preview pane: a split on the right of the tab that follows the cursor in
--- deck windows. A card line shows the card, spaced out more than hover since
--- the pane has the room. A count line lists
--- the deck cards it counts, a mana symbols line each type's share, and
--- a cards line every deck card.
--- Below a nonland card are its odds of being cast on curve, and below
--- every card its oracle tags.
local colors = require('scryvim.colors')
local config = require('scryvim.config')
local count = require('scryvim.count')
local curve = require('scryvim.curve')
local data = require('scryvim.data')
local parse = require('scryvim.parse')
local render = require('scryvim.render')
local symbols = require('scryvim.symbols')
local tags = require('scryvim.tags')
local tally = require('scryvim.tally')

local M = {}

--- Delay after a cursor move, so holding `j` draws once at the end.
M.MOVE_MS = 30

--- Columns of the bar for a mana type with every symbol.
M.BAR_WIDTH = 20

-- Tabpage -> { win, buf, timer, generation, tick }.
local panes = {} ---@type table<integer, table>
-- Tabpage -> { wide, hidden, dismissed }, for `pane.auto_open`: whether the
-- editor was last wide enough for the pane, whether narrowing closed it, and
-- whether it was closed by hand.
local auto = {} ---@type table<integer, table>
-- Set while narrowing closes a pane, so it isn't taken as closed by hand.
local hiding = false
local group
local unsubscribe, unsubscribe_tags

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

--- Each mana type's share of all the symbols, with a bar: `{R}  66%  ███`.
local function mana_shares(totals)
  local sum = 0
  for _, t in ipairs(symbols.TYPES) do
    sum = sum + (totals[t] or 0)
  end
  if sum == 0 then
    return {}
  end
  local out = { '' }
  for _, t in ipairs(symbols.TYPES) do
    local v = totals[t] or 0
    if v > 0 then
      local share = v / sum
      out[#out + 1] = ('{%s}  %4s  %s'):format(
        t,
        percent(share),
        ('█'):rep(math.max(1, math.floor(share * M.BAR_WIDTH + 0.5)))
      )
    end
  end
  return out
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
      local head = ('On curve (turn %d)'):format(odds.turn)
      if #faces > 1 then
        head = face.name .. ' on curve (turn ' .. odds.turn .. ')'
      end
      vim.list_extend(out, { '', '---', '' })
      local pool = odds.pool
      if pool.lands + pool.others == 0 then
        out[#out + 1] = '*No mana sources in the deck*'
      else
        local of = render.plural(pool.lands, 'land')
        if pool.others > 0 then
          of = of .. ' and ' .. render.plural(pool.others, 'other source')
        end
        vim.list_extend(out, {
          ('%s: %s on the play, %s on the draw'):format(head, percent(odds.play), percent(odds.draw)),
          '',
          ('%s to draw %s'):format(percent(odds.enough), render.plural(odds.turn, 'source')),
        })
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
            ('%s to have the colors with %s'):format(percent(odds.colors), render.plural(odds.turn, 'source')),
            '',
            ('Sources: %s of %s'):format(table.concat(sources, '  '), of),
          })
        else
          vim.list_extend(out, { '', 'Sources: ' .. of })
        end
      end
    end
  end
  return out
end

--- The oracle tags section for `card`. The tag list downloads on first use
--- and the pane redraws when it arrives.
local function tag_lines(card)
  if not config.get().pane.tags or not card.oracle_id then
    return {}
  end
  local labels, err = tags.get(card.oracle_id)
  local line
  if err then
    line = '*Oracle tags: ' .. err .. '*'
  elseif not labels then
    line = '*Loading oracle tags…*'
  elseif #labels == 0 then
    line = '*No oracle tags*'
  else
    line = 'Oracle tags: ' .. table.concat(labels, ', ')
  end
  return { '', '---', '', line }
end

--- The pane text for line `row` (1-based) of `lines`, passed to `cb` as a
--- list of lines; nil leaves the pane as it is. `cb` may run later, when a
--- count needs Scryfall.
---@param lines string[]
---@param row integer
---@param cb fun(text: string[]|nil)
function M.content(lines, row, cb)
  local line = lines[row] or ''
  local parsed = parse.parse(line)
  local query, label = parsed.query, parsed.label
  local mana, cards = parsed.count == 'mana', parsed.count == 'cards'
  -- Card lines have a numeric `count` too: their quantity.
  if parsed.kind ~= 'comment' or not parsed.count then
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
    vim.list_extend(out, curve_lines(card, count.entries(lines, data.get)))
    return cb(vim.list_extend(out, tag_lines(card)))
  end

  local entries = count.entries(lines, data.get)
  if mana then
    if not data.ready() then
      return cb({ '*scryvim: card data is not loaded yet*' })
    end
    local totals = count.stats(entries, data.get).mana
    return cb(vim.list_extend({ '**Mana symbols**  ' .. symbols.format(totals) }, mana_shares(totals)))
  end
  if cards then
    local total, breakdown = tally.cards(entries)
    local out = { '**' .. total .. '**' .. (breakdown and '  ' .. breakdown or ''), '' }
    return cb(vim.list_extend(out, card_list(entries)))
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
  colors.highlight_buf(pane.buf, config.get().colors)
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
    unsubscribe_tags()
    group, unsubscribe, unsubscribe_tags = nil, nil, nil
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
          if auto[tab] and not hiding then
            auto[tab].dismissed = true
          end
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
  local function redraw()
    local tab = vim.api.nvim_get_current_tabpage()
    if panes[tab] then
      M.refresh()
    end
  end
  unsubscribe = data.on_ready(vim.schedule_wrap(redraw))
  unsubscribe_tags = tags.on_ready(vim.schedule_wrap(redraw))
end

--- Whether the current tab has a preview pane.
function M.is_open()
  return valid(panes[vim.api.nvim_get_current_tabpage()])
end

--- Whether the editor is wide enough to open the pane by itself.
function M.wide()
  return vim.o.columns >= config.get().pane.min_columns
end

local function open()
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

--- Open the pane on the right of the current tab, keeping the cursor where
--- it is.
function M.open()
  local tab = vim.api.nvim_get_current_tabpage()
  auto[tab] = { wide = M.wide() }
  open()
end

--- For `pane.auto_open`, when a deck window opens: open the pane if the
--- editor is wide enough. Otherwise |M.fit()| opens it once it widens.
function M.auto_open()
  if M.wide() then
    M.open()
  else
    auto[vim.api.nvim_get_current_tabpage()] = { wide = false }
  end
end

--- For `pane.auto_open`, after a resize or on entering a tab: when the
--- editor narrows past `pane.min_columns`, close the pane, and when it
--- widens again, reopen it, or open it beside a deck, unless it was closed
--- by hand.
function M.fit()
  for tab in pairs(auto) do
    if not vim.api.nvim_tabpage_is_valid(tab) then
      auto[tab] = nil
    end
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local state = auto[tab] or {}
  auto[tab] = state
  local wide = M.wide()
  if state.wide == wide then
    return
  end
  state.wide = wide
  if not wide then
    if M.is_open() then
      hiding = true
      pcall(vim.api.nvim_win_close, panes[tab].win, true)
      hiding = false
      forget(tab)
      state.hidden = true
    end
  elseif state.hidden or (not state.dismissed and vim.bo.filetype == 'deck') then
    state.hidden = false
    open()
  end
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
