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

--- The Scryfall URL for the card on `line`, without the count or `SB:`
--- prefix: the printing's page for a set code and collector number
--- (`(M10) 146`), an exact name search in the set for a set code alone
--- (`[M10]`), otherwise an exact name search (`!"<name>"`). Nil when the
--- line has no card.
---@param line string
---@return string|nil
function M.url(line)
  local parsed = parse.parse(line)
  if parsed.kind ~= 'card' then
    return nil
  end
  if parsed.set and parsed.number then
    return ('https://scryfall.com/card/%s/%s'):format(encode(parsed.set), encode(parsed.number))
  end
  local query = '!"' .. parsed.name .. '"'
  if parsed.set then
    query = query .. ' set:' .. parsed.set
  end
  return 'https://scryfall.com/search?q=' .. encode(query)
end

--- Copy `url` to the system clipboard of the terminal, which over SSH is
--- the local one (OSC 52).
---@param url string
function M._copy(url)
  require('vim.ui.clipboard.osc52').copy('+')({ url })
end

--- True in an SSH session, where the browser opener would run on the
--- remote host.
local function over_ssh()
  return (vim.env.SSH_TTY or vim.env.SSH_CONNECTION or '') ~= ''
end

--- Open the card on line `row` (1-based) of `bufnr` in the browser, or
--- copy its URL with `open = 'copy'` (and over SSH with `open = 'auto'`).
---@param bufnr integer
---@param row integer
function M.open(bufnr, row)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  local url = M.url(line)
  if not url then
    vim.notify('scryvim: no card on this line', vim.log.levels.WARN)
    return
  end
  local method = require('scryvim.config').get().open
  if method == 'copy' or (method == 'auto' and over_ssh()) then
    M._copy(url)
    vim.notify('scryvim: copied ' .. url, vim.log.levels.INFO)
    return
  end
  -- Like the built-in `gx`: give the opener a second to fail, since
  -- vim.ui.open() only reports a missing opener, not one that exits
  -- non-zero. Show the URL either way so it can be copied.
  local cmd, err = vim.ui.open(url)
  local rv = cmd and cmd:wait(1000) or nil
  if rv and rv.code ~= 0 then
    local stderr = vim.trim(rv.stderr or '')
    err = ('%s %s (%d)%s'):format(
      cmd.cmd and cmd.cmd[1] or 'opener',
      rv.code == 124 and 'timed out' or 'failed',
      rv.code,
      stderr ~= '' and (': ' .. stderr) or ''
    )
  end
  if err then
    vim.notify(('scryvim: could not open %s: %s'):format(url, err), vim.log.levels.ERROR)
  else
    vim.notify('scryvim: opened ' .. url, vim.log.levels.INFO)
  end
end

return M
