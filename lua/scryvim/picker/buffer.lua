--- Built-in results popup: a normal-mode buffer with one card per line and
--- a preview window. Move with any motion, search with `/`, mark cards with
--- <Tab>, add them with <CR>.
local colors = require('scryvim.colors')

local M = {}

--- `pick()` returns a handle that takes later pages with `append()`.
M.streams = true

local ns = vim.api.nvim_create_namespace('scryvim.results')

vim.api.nvim_set_hl(0, 'ScryvimPickMark', { default = true, link = 'Special' })

--- Window configs for the list and preview: side by side when there is room,
--- else the preview below the list. Sizes include the borders.
---@return table list, table preview
function M.layout()
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.max(20, math.floor(cols * 0.9))
  local height = math.max(8, math.floor(rows * 0.8))
  local top = math.floor((rows - height) / 2)
  local left = math.floor((cols - width) / 2)
  local list = { relative = 'editor', style = 'minimal', border = 'rounded', row = top, col = left }
  local preview = { relative = 'editor', style = 'minimal', border = 'rounded', focusable = false }
  if width >= 120 then
    local pw = math.floor(width * 0.4)
    list.width, list.height = width - pw - 2, height - 2
    preview.row, preview.col = top, left + width - pw
    preview.width, preview.height = pw - 2, height - 2
  else
    local ph = math.floor(height * 0.4)
    list.width, list.height = width - 2, height - ph - 2
    preview.row, preview.col = top + height - ph, left
    preview.width, preview.height = width - 2, ph - 2
  end
  return list, preview
end

local function scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  return buf
end

--- Open the popup over `items`. Returns a handle whose `append(cards,
--- loading)` adds later pages of results; `opts.loading` marks the title
--- while more are on the way.
function M.pick(items, opts)
  local origin = vim.api.nvim_get_current_win()
  items = vim.list_extend({}, items)
  local lines = {}
  for i, card in ipairs(items) do
    lines[i] = opts.format_item(card)
  end
  local list_buf = scratch(lines)
  vim.bo[list_buf].filetype = 'scryvim_results'
  if opts.color then
    colors.highlight_buf(list_buf)
  end
  local preview_buf = scratch({})

  local marked = {} -- row -> extmark id
  local count = 0

  local function footer()
    local hint = ' <Tab> mark · <CR> add · q close '
    return count > 0 and (' %d marked ·%s'):format(count, hint) or hint
  end

  local function title(loading)
    return (' %s (%d%s) '):format(opts.prompt, #items, loading and '…' or '')
  end

  local list_cfg, preview_cfg = M.layout()
  list_cfg.title = title(opts.loading)
  list_cfg.title_pos = 'center'
  list_cfg.footer = footer()
  list_cfg.footer_pos = 'center'
  local preview_win = vim.api.nvim_open_win(preview_buf, false, preview_cfg)
  local list_win = vim.api.nvim_open_win(list_buf, true, list_cfg)
  -- The list is browsed in normal mode, even when search started from insert.
  vim.cmd.stopinsert()
  vim.wo[list_win].cursorline = true
  vim.wo[list_win].signcolumn = 'yes:1'
  vim.wo[preview_win].wrap = true
  vim.wo[preview_win].linebreak = true
  vim.wo[preview_win].conceallevel = 2

  local shown
  local function show_preview()
    local row = vim.api.nvim_win_get_cursor(list_win)[1]
    if row == shown or not vim.api.nvim_buf_is_valid(preview_buf) then
      return
    end
    shown = row
    local text = opts.preview(items[row])
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
    vim.bo[preview_buf].modifiable = false
    -- Treesitter directly rather than filetype=markdown, which would run
    -- markdown ftplugins and autocmds on every redraw.
    pcall(vim.treesitter.start, preview_buf, 'markdown')
    if opts.color then
      colors.highlight_buf(preview_buf)
    end
    vim.api.nvim_win_set_cursor(preview_win, { 1, 0 })
  end

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    pcall(vim.api.nvim_del_augroup_by_name, 'scryvim.results.' .. list_buf)
    for _, win in ipairs({ list_win, preview_win }) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
  end

  local function toggle(row)
    if marked[row] then
      vim.api.nvim_buf_del_extmark(list_buf, ns, marked[row])
      marked[row], count = nil, count - 1
    else
      marked[row] = vim.api.nvim_buf_set_extmark(list_buf, ns, row - 1, 0, {
        sign_text = '●',
        sign_hl_group = 'ScryvimPickMark',
      })
      count = count + 1
    end
  end

  local function update_footer()
    vim.api.nvim_win_set_config(list_win, { footer = footer(), footer_pos = 'center' })
  end

  local function choose(rows)
    local cards = {}
    for _, row in ipairs(rows) do
      cards[#cards + 1] = items[row]
    end
    close()
    opts.on_choose(cards)
  end

  local function marked_rows()
    local rows = vim.tbl_keys(marked)
    table.sort(rows)
    return rows
  end

  local function visual_range()
    local a, b = vim.fn.line('v'), vim.fn.line('.')
    vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })
    return math.min(a, b), math.max(a, b)
  end

  local function map(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, fn, { buffer = list_buf, nowait = true, desc = desc })
  end

  local function mark_and_move(step)
    return function()
      local row = vim.api.nvim_win_get_cursor(list_win)[1]
      toggle(row)
      update_footer()
      local next_row = math.max(1, math.min(#items, row + step))
      vim.api.nvim_win_set_cursor(list_win, { next_row, 0 })
    end
  end

  map('n', '<Tab>', mark_and_move(1), 'Mark card and move down')
  map('n', '<S-Tab>', mark_and_move(-1), 'Mark card and move up')
  map('x', '<Tab>', function()
    local first, last = visual_range()
    for row = first, last do
      toggle(row)
    end
    update_footer()
  end, 'Mark cards')
  map('n', '<CR>', function()
    local rows = marked_rows()
    choose(#rows > 0 and rows or { vim.api.nvim_win_get_cursor(list_win)[1] })
  end, 'Add marked cards, or the card under the cursor')
  map('x', '<CR>', function()
    local first, last = visual_range()
    local rows = {}
    for row = first, last do
      rows[#rows + 1] = row
    end
    choose(rows)
  end, 'Add selected cards')
  map('n', 'q', close, 'Close')
  map('n', '<Esc>', close, 'Close')

  local group = vim.api.nvim_create_augroup('scryvim.results.' .. list_buf, { clear = true })
  vim.api.nvim_create_autocmd('CursorMoved', { group = group, buffer = list_buf, callback = show_preview })
  -- Leaving the popup (another window, :q) closes it, like other pickers.
  vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    group = group,
    buffer = list_buf,
    callback = function()
      vim.schedule(close)
    end,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      local lc, pc = M.layout()
      lc.style, pc.style = nil, nil
      vim.api.nvim_win_set_config(list_win, lc)
      vim.api.nvim_win_set_config(preview_win, pc)
    end,
  })

  show_preview()

  local handle = { list_win = list_win, preview_win = preview_win, list_buf = list_buf, preview_buf = preview_buf }

  --- Add cards below the current ones. Does nothing once the popup is closed.
  ---@param cards table[]
  ---@param loading? boolean more pages are still coming
  function handle.append(cards, loading)
    if closed or not vim.api.nvim_buf_is_valid(list_buf) then
      return
    end
    local first = #items
    local new = {}
    for i, card in ipairs(cards) do
      items[first + i] = card
      new[i] = opts.format_item(card)
    end
    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, first, -1, false, new)
    vim.bo[list_buf].modifiable = false
    if opts.color then
      for i, line in ipairs(new) do
        for _, sym in ipairs(colors.symbols(line)) do
          local mark = { end_col = sym[2], hl_group = colors.group(sym[3]) }
          vim.api.nvim_buf_set_extmark(list_buf, colors.ns, first + i - 1, sym[1], mark)
        end
      end
    end
    vim.api.nvim_win_set_config(list_win, { title = title(loading), title_pos = 'center' })
  end

  return handle
end

return M
