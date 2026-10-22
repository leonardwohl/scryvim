--- Colored mana costs at the end of card lines.
---
--- Takes the place of the server's inlay hints when `colors` is on: inlay
--- hints are drawn in a single highlight group, so they cannot color each
--- mana symbol.
local attach = require('scryvim.attach')
local colors = require('scryvim.colors')
local data = require('scryvim.data')
local parse = require('scryvim.parse')
local render = require('scryvim.render')

local M = {}

M.ns = vim.api.nvim_create_namespace('scryvim.mana')

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
        virt_text = colors.virt_text(cost, 'LspInlayHint', true),
        virt_text_pos = 'eol',
        hl_mode = 'combine',
      })
    end
  end
end

local decor = attach.new(M.ns, {
  edit_delay = 0,
  render = function(buf)
    M.render(buf)
  end,
})

M.attach = decor.attach
M.detach = decor.detach
M.is_attached = decor.is_attached

return M
