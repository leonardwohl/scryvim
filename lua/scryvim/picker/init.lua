--- Scryfall search -> picker adapter -> insert/increment in the buffer.
local build = require('scryvim.build')
local config = require('scryvim.config')
local http = require('scryvim.http')
local parse = require('scryvim.parse')
local render = require('scryvim.render')

local M = {}

M.SEARCH_URL = 'https://api.scryfall.com/cards/search?q='

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

--- Page through `/cards/search`, up to `max_pages`. Once page 1 reports the
--- total, the remaining pages are requested together; `http` still spaces
--- them out per Scryfall's rate limit, but their transfers overlap.
---@param query string
---@param max_pages integer
---@param cb fun(err: string|nil, cards: table[])
function M.fetch(query, max_pages, cb)
  local pages = {}
  local function finish(err)
    local cards = {}
    for _, page in ipairs(pages) do
      for _, card in ipairs(page) do
        cards[#cards + 1] = build.strip(card)
      end
    end
    cb(err, cards)
  end
  http.get_json(M.SEARCH_URL .. http.urlencode(query), function(err, first)
    if err then
      return finish(err)
    end
    pages[1] = first.data or {}
    local next_page = first.has_more and first.next_page
    local total = math.min(max_pages, math.ceil((first.total_cards or 0) / M.PAGE_SIZE))
    if not next_page or total < 2 or not next_page:find('[?&]page=2') then
      return finish(nil)
    end
    local pending, failed = total - 1, nil
    for n = 2, total do
      local url = next_page:gsub('([?&]page=)2', '%1' .. n, 1)
      http.get_json(url, function(perr, obj)
        failed = failed or perr
        pages[n] = obj and obj.data or {}
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
  M.fetch(query, cfg.search.max_pages, function(err, cards)
    if err then
      vim.notify('scryvim: search failed: ' .. err, vim.log.levels.WARN)
      return
    end
    if #cards == 0 then
      vim.notify('scryvim: no cards match ' .. query, vim.log.levels.INFO)
      return
    end
    local adapter = M.adapter(cfg.picker)
    adapter.pick(cards, {
      prompt = 'Scryfall: ' .. query,
      format_item = M.format_item,
      preview = render.markdown,
      on_choose = function(chosen)
        if vim.api.nvim_buf_is_valid(bufnr) and #chosen > 0 then
          M.insert(bufnr, row, chosen)
        end
      end,
    })
  end)
end

return M
