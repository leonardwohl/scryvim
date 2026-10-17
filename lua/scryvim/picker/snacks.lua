--- snacks.nvim picker adapter: multi-select with markdown preview.
local M = {}

function M.pick(items, opts)
  local entries = {}
  for i, card in ipairs(items) do
    entries[i] = {
      idx = i,
      text = opts.format_item(card),
      card = card,
      preview = { text = opts.preview(card), ft = 'markdown' },
    }
  end
  require('snacks').picker.pick({
    title = opts.prompt,
    items = entries,
    format = 'text',
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
