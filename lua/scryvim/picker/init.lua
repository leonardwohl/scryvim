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

--- Resolve the configured adapter. A table with `pick()` is used as-is.
---@param name string|table
---@return table adapter, string name
function M.adapter(name)
  if type(name) == 'table' then
    return name, 'custom'
  end
  if name == 'auto' then
    for _, a in ipairs(AUTO_ORDER) do
      if pcall(require, a.probe) then
        return require('scryvim.picker.' .. a.name), a.name
      end
    end
    name = 'select'
  end
  return require('scryvim.picker.' .. name), name
end

--- Page through `/cards/search`, up to `max_pages`.
---@param query string
---@param max_pages integer
---@param cb fun(err: string|nil, cards: table[])
function M.fetch(query, max_pages, cb)
  local cards = {}
  local function page(url, n)
    http.get_json(url, function(err, obj)
      if err then
        return cb(err, cards)
      end
      for _, card in ipairs(obj.data or {}) do
        cards[#cards + 1] = build.strip(card)
      end
      if obj.has_more and obj.next_page and n < max_pages then
        page(obj.next_page, n + 1)
      else
        cb(nil, cards)
      end
    end)
  end
  page(M.SEARCH_URL .. http.urlencode(query), 1)
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
--- `1 <name>` lines below `row` (1-based).
---@param bufnr integer
---@param row integer
---@param cards table[]
function M.insert(bufnr, row, cards)
  for _, card in ipairs(cards) do
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local done = false
    for i, line in ipairs(lines) do
      local parsed = parse.parse(line)
      if parsed.kind == 'card' and same_card(parsed.name, card) then
        local new
        if parsed.count_range then
          local s, e = parsed.count_range[1], parsed.count_range[2]
          new = line:sub(1, s) .. (parsed.count + 1) .. line:sub(e + 1)
        else
          local s = parsed.name_range[1]
          new = line:sub(1, s) .. '2 ' .. line:sub(s + 1)
        end
        vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new })
        done = true
        break
      end
    end
    if not done then
      row = math.min(row, #lines)
      vim.api.nvim_buf_set_lines(bufnr, row, row, false, { '1 ' .. card.name })
      row = row + 1
    end
  end
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
