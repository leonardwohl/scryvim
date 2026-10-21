--- LSP hover floats opened from deck buffers.
local M = {}

--- The window showing `buf` when it is an LSP float opened from a deck
--- buffer, or nil.
---@param buf integer
---@return integer|nil
function M.deck_float(buf)
  local win = vim.fn.bufwinid(buf)
  local source = win ~= -1 and vim.w[win].lsp_floating_bufnr
  if source and vim.api.nvim_buf_is_valid(source) and vim.bo[source].filetype == 'deck' then
    return win
  end
end

--- Narrow the float in `win` to `max_width` columns, growing it to fit the
--- wrapped text. Floats already that narrow, and `max_width` 0, are left
--- alone.
---@param win integer
---@param max_width integer
function M.fit(win, max_width)
  if max_width <= 0 or vim.api.nvim_win_get_width(win) <= max_width then
    return
  end
  vim.api.nvim_win_set_config(win, { width = max_width })
  local lines = vim.api.nvim_win_text_height(win, {}).all
  vim.api.nvim_win_set_config(win, { height = math.max(1, math.min(lines, vim.o.lines - 4)) })
end

return M
