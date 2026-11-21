--- Open the card on a decklist line on Scryfall.
local parse = require('scryvim.parse')

local M = {}

-- Percent-encode everything but RFC 3986 unreserved characters, so `&`,
-- `+` and `#` in names stay inside the query.
local function encode(s)
  return (s:gsub('[^%w%-._~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

--- The Scryfall search URL for the card on `line`: an exact name search
--- (`!"<name>"`) with the count, `SB:` prefix and set code left out. Nil
--- when the line has no card.
---@param line string
---@return string|nil
function M.url(line)
  local parsed = parse.parse(line)
  if parsed.kind ~= 'card' then
    return nil
  end
  return 'https://scryfall.com/search?q=' .. encode('!"' .. parsed.name .. '"')
end

--- Open the card on line `row` (1-based) of `bufnr` in the browser.
---@param bufnr integer
---@param row integer
function M.open(bufnr, row)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  local url = M.url(line)
  if not url then
    vim.notify('scryvim: no card on this line', vim.log.levels.WARN)
    return
  end
  local _, err = vim.ui.open(url)
  if err then
    vim.notify('scryvim: ' .. err, vim.log.levels.ERROR)
  end
end

return M
