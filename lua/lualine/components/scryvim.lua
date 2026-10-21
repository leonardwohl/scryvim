--- lualine component for scryvim's deck stats: `sections = { lualine_x =
--- { 'scryvim' } }`. Takes the `cards`, `lands` and `mana` options of
--- `require('scryvim.statusline').chunks()`, and `colored` (default true,
--- with scryvim's `colors` on) for mana symbols in their colors.
local colors = require('scryvim.colors')
local config = require('scryvim.config')
local statusline = require('scryvim.statusline')

local M = require('lualine.component'):extend()

-- The mana color's foreground, read on every refresh so colorscheme
-- changes carry over; lualine fills in the section's background.
local function fg(color)
  return function()
    local hl = vim.api.nvim_get_hl(0, { name = colors.group(color), link = false })
    return { fg = hl.fg and ('#%06x'):format(hl.fg) or nil }
  end
end

function M:init(options)
  M.super.init(self, options)
  self.hls = {}
  if self.options.colored ~= false then
    for _, color in ipairs(colors.COLORS) do
      self.hls[color] = self:create_hl(fg(color), color)
    end
  end
end

function M:update_status()
  local color = config.get().colors
  local out = {}
  for _, c in ipairs(statusline.chunks(vim.api.nvim_get_current_buf(), self.options)) do
    local text = c[1]:gsub('%%', '%%%%')
    local hl = color and c[2] and self.hls[c[2]]
    out[#out + 1] = hl and (self:format_hl(hl) .. text .. self:get_default_hl()) or text
  end
  return table.concat(out)
end

return M
