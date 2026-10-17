--- vim.ui.select adapter: single-select, no preview.
local M = {}

function M.pick(items, opts)
  vim.ui.select(items, { prompt = opts.prompt, format_item = opts.format_item }, function(item)
    if item then
      opts.on_choose({ item })
    end
  end)
end

return M
