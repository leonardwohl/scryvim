--- Scryfall search -> picker adapter -> insert/increment in the buffer.
local build = require('scryvim.build')
local config = require('scryvim.config')
local http = require('scryvim.http')
local parse = require('scryvim.parse')
local render = require('scryvim.render')

local M = {}

local AUTO_ORDER = {
  { name = 'snacks', probe = 'snacks' },
  { name = 'telescope', probe = 'telescope' },
  { name = 'fzf_lua', probe = 'fzf-lua' },
}

--- Overridable for tests.
function M._available(module)
  return (pcall(require, module))
end

--- Resolve the configured adapter. A table with `pick()` is used as-is.
---@param name string|table
---@return table adapter, string name
function M.adapter(name)
  if type(name) == 'table' then
    return name, 'custom'
  end
  if name == 'auto' then
    for _, a in ipairs(AUTO_ORDER) do
      if M._available(a.probe) then
        return require('scryvim.picker.' .. a.name), a.name
      end
    end
    name = 'select'
  end
  return require('scryvim.picker.' .. name), name
end

M.PAGE_SIZE = 175

--- Finished searches, so repeating one skips Scryfall. Searches are capped
--- at `CACHE_SIZE` and expire after `CACHE_TTL_MS`; Scryfall itself tells
--- clients to cache search results for hours.
M.CACHE_SIZE = 20
M.CACHE_TTL_MS = 30 * 60 * 1000
local cache, cache_order = {}, {}

function M._clear_cache()
  cache, cache_order = {}, {}
end

local function cache_get(key)
  local hit = cache[key]
  if hit and vim.uv.now() - hit.at <= M.CACHE_TTL_MS then
    return hit
  end
end

local function cache_put(key, cards, total)
  if not cache[key] then
    cache_order[#cache_order + 1] = key
    if #cache_order > M.CACHE_SIZE then
      cache[table.remove(cache_order, 1)] = nil
    end
  end
  cache[key] = { cards = cards, total = total, at = vim.uv.now() }
end

--- Page through `/cards/search`, up to `max_pages`. Once page 1 reports the
--- total, the remaining pages are requested together; `http` still spaces
--- them out per Scryfall's rate limit (500 ms apart), but their transfers
--- overlap.
---
--- Since that spacing puts page 3 a second after page 1, `on_page` lets the
--- caller show results as they come: it runs once per page, in page order,
--- with that page's cards. A failed later page counts as empty; a failed
--- page 1 only reaches `cb`. `cb` still gets
--- every card once all pages are in. A repeated search is served from the
--- cache, as one page with every card.
---@param query string
---@param max_pages integer
---@param cb fun(err: string|nil, cards: table[])
---@param on_page? fun(cards: table[], info: { page: integer, last: boolean, total_cards: integer })
function M.fetch(query, max_pages, cb, on_page)
  local key = max_pages .. '\0' .. query
  local hit = cache_get(key)
  if hit then
    if on_page then
      on_page(vim.list_extend({}, hit.cards), { page = 1, last = true, total_cards = hit.total })
    end
    return cb(nil, vim.list_extend({}, hit.cards))
  end

  local pages, total, npages, delivered = {}, 0, 1, 0
  local function deliver()
    while pages[delivered + 1] do
      delivered = delivered + 1
      if on_page then
        on_page(pages[delivered], { page = delivered, last = delivered == npages, total_cards = total })
      end
    end
  end
  local function finish(err)
    local cards = {}
    for _, page in ipairs(pages) do
      vim.list_extend(cards, page)
    end
    if not err then
      cache_put(key, cards, total)
    end
    cb(err, vim.list_extend({}, cards))
  end
  local function strip(obj)
    local out = {}
    for i, card in ipairs(obj and obj.data or {}) do
      out[i] = build.strip(card)
    end
    return out
  end

  http.get_json(http.SEARCH_URL .. http.urlencode(query), function(err, first)
    if err then
      return finish(err)
    end
    total = first.total_cards or 0
    local next_page = first.has_more and first.next_page
    local wanted = math.min(max_pages, math.ceil(total / M.PAGE_SIZE))
    if next_page and wanted >= 2 and next_page:find('[?&]page=2') then
      npages = wanted
    end
    pages[1] = strip(first)
    deliver()
    if npages == 1 then
      return finish(nil)
    end
    local pending, failed = npages - 1, nil
    for n = 2, npages do
      local url = next_page:gsub('([?&]page=)2', '%1' .. n, 1)
      http.get_json(url, function(perr, obj)
        failed = failed or perr
        pages[n] = strip(obj)
        deliver()
        pending = pending - 1
        if pending == 0 then
          finish(failed)
        end
      end)
    end
  end)
end

function M.format_item(card)
  return ('%-40s %-20s %s'):format(card.name, render.mana_cost(card) or '', card.type_line or '')
end

local function same_card(line_name, card)
  local n = line_name:lower()
  local face = card.card_faces and card.card_faces[1]
  return n == card.name:lower() or (face ~= nil and face.name ~= nil and n == face.name:lower())
end

--- Add `cards` to the buffer: increment an existing line's count, or insert
--- `1 <name>` lines below `row` (1-based). Applied as one buffer change, so
--- it is a single undo step and a single LSP update.
---@param bufnr integer
---@param row integer
---@param cards table[]
function M.insert(bufnr, row, cards)
  local old = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lines = vim.list_extend({}, old)
  local parsed = {}
  for i, line in ipairs(lines) do
    parsed[i] = parse.parse(line)
  end
  row = math.min(row, #lines)
  for _, card in ipairs(cards) do
    local found
    for i, p in ipairs(parsed) do
      if p.kind == 'card' and same_card(p.name, card) then
        found = i
        break
      end
    end
    if found then
      local line, p = lines[found], parsed[found]
      if p.count_range then
        local s, e = p.count_range[1], p.count_range[2]
        lines[found] = line:sub(1, s) .. (p.count + 1) .. line:sub(e + 1)
      else
        local s = p.name_range[1]
        lines[found] = line:sub(1, s) .. '2 ' .. line:sub(s + 1)
      end
      parsed[found] = parse.parse(lines[found])
    else
      local line = '1 ' .. card.name
      table.insert(lines, row + 1, line)
      table.insert(parsed, row + 1, parse.parse(line))
      row = row + 1
    end
  end

  -- Replace only the span that changed.
  local first = 1
  while first <= #old and first <= #lines and old[first] == lines[first] do
    first = first + 1
  end
  local old_last, new_last = #old, #lines
  while old_last >= first and new_last >= first and old[old_last] == lines[new_last] do
    old_last, new_last = old_last - 1, new_last - 1
  end
  if first > old_last and first > new_last then
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, first - 1, old_last, false, vim.list_slice(lines, first, new_last))
end

--- `:Scryvim search [query]`.
---@param query? string
function M.search(query)
  if not query or query == '' then
    vim.ui.input({ prompt = 'Scryfall search: ' }, function(input)
      if input and input ~= '' then
        M.search(input)
      end
    end)
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local cfg = config.get()
  vim.notify('scryvim: searching Scryfall for ' .. query .. '…', vim.log.levels.INFO)
  local adapter = M.adapter(cfg.picker)
  local pick_opts = {
    prompt = 'Scryfall: ' .. query,
    color = cfg.colors,
    format_item = M.format_item,
    preview = render.markdown,
    on_choose = function(chosen)
      if vim.api.nvim_buf_is_valid(bufnr) and #chosen > 0 then
        M.insert(bufnr, row, chosen)
      end
    end,
  }
  -- Adapters whose pick() returns an `append` handle open on the first page
  -- of results and take the rest as they arrive.
  local handle
  local on_page = adapter.streams
    and function(cards, info)
      if handle then
        handle.append(cards, not info.last)
      elseif #cards > 0 then
        handle = adapter.pick(cards, vim.tbl_extend('force', pick_opts, { loading = not info.last }))
      end
    end
  M.fetch(query, cfg.search.max_pages, function(err, cards)
    if err then
      vim.notify('scryvim: search failed: ' .. err, vim.log.levels.WARN)
    end
    if handle then
      handle.append({}, false)
      return
    end
    if err then
      return
    end
    if #cards == 0 then
      vim.notify('scryvim: no cards match ' .. query, vim.log.levels.INFO)
      return
    end
    adapter.pick(cards, pick_opts)
  end, on_page or nil)
end

return M
