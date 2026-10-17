--- Colored mana costs at the end of card lines.
---
--- Takes the place of the server's inlay hints when `colors` is on: inlay
--- hints are drawn in a single highlight group, so they cannot color each
--- mana symbol.
local colors = require('scryvim.colors')
local data = require('scryvim.data')
local parse = require('scryvim.parse')
local render = require('scryvim.render')

local M = {}

M.ns = vim.api.nvim_create_namespace('scryvim.mana')

-- Buffer -> { unsubscribe = fn }. Also identifies the attach, so a stale
-- buffer callback can tell it was replaced.
local attached = {} ---@type table<integer, table>
local pending = {} ---@type table<integer, true>

local function chunks(cost)
  local out = {}
  for _, chunk in ipairs(colors.mana_chunks(cost)) do
    local hl = chunk[2] and { 'LspInlayHint', colors.group(chunk[2], true) } or 'LspInlayHint'
    out[#out + 1] = { chunk[1], hl }
  end
  return out
end

--- Redraw every mana cost in `buf`.
---@param buf integer
function M.render(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  if not data.ready() then
    return
  end
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local parsed = parse.parse(line)
    local card = parsed.kind == 'card' and data.get(parsed.name)
    local cost = card and render.mana_cost(card)
    if cost then
      vim.api.nvim_buf_set_extmark(buf, M.ns, i - 1, 0, {
        virt_text = chunks(cost),
        virt_text_pos = 'eol',
        hl_mode = 'combine',
      })
    end
  end
end

-- Coalesce bursts of edits into one redraw.
local function schedule(buf)
  if pending[buf] then
    return
  end
  pending[buf] = true
  vim.schedule(function()
    pending[buf] = nil
    if attached[buf] then
      M.render(buf)
    end
  end)
end

---@param buf integer
function M.attach(buf)
  if attached[buf] then
    return
  end
  local token = {}
  attached[buf] = token
  token.unsubscribe = data.on_ready(function()
    schedule(buf)
  end)
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if attached[buf] ~= token then
        return true
      end
      schedule(buf)
    end,
    on_reload = function()
      schedule(buf)
    end,
    on_detach = function()
      if attached[buf] == token then
        M.detach(buf)
      end
    end,
  })
  schedule(buf)
end

---@param buf integer
function M.detach(buf)
  local token = attached[buf]
  if token then
    token.unsubscribe()
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
