--- snacks.nvim picker adapter: multi-select with markdown preview.
local colors = require('scryvim.colors')

local M = {}

function M.pick(items, opts)
  local entries = {}
  for i, card in ipairs(items) do
    local preview = opts.preview(card)
    entries[i] = {
      idx = i,
      text = opts.format_item(card),
      card = card,
      preview = { text = preview, ft = 'markdown', extmarks = opts.color and colors.extmarks(preview) or nil },
    }
  end
  require('snacks').picker.pick({
    title = opts.prompt,
    items = entries,
    format = opts.color and function(item)
      return colors.segments(item.text)
    end or 'text',
    preview = 'preview',
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
