--- snacks.nvim picker adapter: multi-select with markdown preview.
local colors = require('scryvim.colors')

local M = {}

local ns = vim.api.nvim_create_namespace('scryvim.snacks_preview')

-- Draws the card text with treesitter's markdown highlighting. Not snacks'
-- own markdown preview (`preview = { ft = 'markdown' }`): every item shown
-- that way leaves work behind on the preview buffer, and wiping it when the
-- picker closes then takes about 10 ms per card previewed, so scrolling
-- through a long result list made closing hang for seconds.
local function preview(ctx)
  local item = ctx.item
  ctx.preview:reset()
  ctx.preview:set_lines(vim.split(item.preview_text, '\n', { plain = true }))
  pcall(vim.treesitter.start, ctx.buf, 'markdown')
  for _, mark in ipairs(item.extmarks or {}) do
    local extmark = { end_col = mark.end_col, hl_group = mark.hl_group }
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, mark.row - 1, mark.col, extmark)
  end
end

function M.pick(items, opts)
  local entries = {}
  for i, card in ipairs(items) do
    local text = opts.preview(card)
    entries[i] = {
      idx = i,
      text = opts.format_item(card),
      card = card,
      preview_text = text,
      extmarks = opts.color and colors.extmarks(text) or nil,
    }
  end
  require('snacks').picker.pick({
    title = opts.prompt,
    items = entries,
    format = opts.color and function(item)
      return colors.segments(item.text)
    end or 'text',
    preview = preview,
    confirm = function(picker, item)
      local selected = picker:selected({ fallback = true })
      picker:close()
      local cards = {}
      for _, it in ipairs(#selected > 0 and selected or { item }) do
        cards[#cards + 1] = it.card
      end
      opts.on_choose(cards)
    end,
  })
end

return M
