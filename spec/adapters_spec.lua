-- Drives the real snacks.nvim, telescope.nvim and fzf-lua pickers.
-- Needs SCRYVIM_TEST_PLUGINS pointing at a directory containing snacks.nvim,
-- telescope.nvim, plenary.nvim and fzf-lua checkouts, and `fzf` on $PATH.
local plugins = os.getenv('SCRYVIM_TEST_PLUGINS')

local ITEMS = {
  { name = 'Lightning Bolt', mana_cost = '{R}', type_line = 'Instant' },
  { name = 'Counterspell', mana_cost = '{U}{U}', type_line = 'Instant' },
}

local function opts(result)
  return {
    prompt = 'Scryfall: test',
    format_item = function(card)
      return card.name
    end,
    preview = function(card)
      return 'PREVIEW ' .. card.name
    end,
    on_choose = function(cards)
      result.chosen = cards
    end,
  }
end

local function names(cards)
  return vim.tbl_map(function(c)
    return c.name
  end, cards or {})
end

local function wait(fn, msg)
  assert(vim.wait(10000, fn, 20), msg)
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

local function find_buf(pred)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if pred(buf) then
      return buf
    end
  end
end

local suite = plugins and describe or pending

suite('picker adapters (real plugins)', function()
  setup(function()
    -- Telescope hides its previewer below 120 columns.
    vim.o.columns, vim.o.lines = 200, 50
    for _, p in ipairs({ 'plenary.nvim', 'telescope.nvim', 'snacks.nvim', 'fzf-lua' }) do
      vim.opt.rtp:prepend(plugins .. '/' .. p)
    end
    require('snacks').setup({ picker = { enabled = true } })
  end)

  -- Leave a single plain window behind for the next spec file.
  after_each(function()
    vim.cmd('stopinsert')
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= '' then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    pcall(vim.cmd, 'silent! only!')
    vim.cmd('enew!')
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if buf ~= vim.api.nvim_get_current_buf() then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)

  it('auto resolves to snacks when it is installed', function()
    local _, name = require('scryvim.picker').adapter('auto')
    assert.are.equal('snacks', name)
  end)

  it('snacks: previews markdown and returns a multi-selection', function()
    local result = {}
    require('scryvim.picker.snacks').pick(ITEMS, opts(result))
    local picker
    wait(function()
      picker = Snacks.picker.get()[1]
      return picker ~= nil and #picker:items() == 2
    end, 'snacks picker did not open')
    local preview
    wait(function()
      preview = find_buf(function(b)
        return buffer_text(b):find('PREVIEW Lightning Bolt', 1, true) ~= nil
      end)
      return preview ~= nil
    end, 'snacks preview not shown')
    assert.truthy(vim.bo[preview].filetype:find('^markdown'))
    picker.list:select(picker:items()[1])
    picker.list:select(picker:items()[2])
    picker:action('confirm')
    wait(function()
      return result.chosen ~= nil
    end, 'snacks confirm did not call on_choose')
    assert.are.same({ 'Lightning Bolt', 'Counterspell' }, names(result.chosen))
  end)

  it('telescope: previews markdown and returns a multi-selection', function()
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')
    local result = {}
    require('scryvim.picker.telescope').pick(ITEMS, opts(result))
    local picker
    wait(function()
      local buf = vim.api.nvim_get_current_buf()
      picker = vim.bo[buf].filetype == 'TelescopePrompt' and action_state.get_current_picker(buf) or nil
      return picker ~= nil and type(picker.manager) == 'table' and picker.manager:num_results() == 2
    end, 'telescope picker did not open')
    local preview
    wait(function()
      preview = find_buf(function(b)
        return vim.bo[b].filetype == 'markdown' and buffer_text(b):find('PREVIEW', 1, true) ~= nil
      end)
      return preview ~= nil
    end, 'telescope preview not shown')
    local prompt = picker.prompt_bufnr
    actions.toggle_selection(prompt)
    actions.move_selection_next(prompt)
    actions.toggle_selection(prompt)
    actions.select_default(prompt)
    wait(function()
      return result.chosen ~= nil
    end, 'telescope select did not call on_choose')
    -- Telescope does not promise an order for multi-selections.
    local got = names(result.chosen)
    table.sort(got)
    assert.are.same({ 'Counterspell', 'Lightning Bolt' }, got)
  end)

  it('fzf-lua: previews and returns a multi-selection', function()
    local result = {}
    require('scryvim.picker.fzf_lua').pick(ITEMS, opts(result))
    local term
    wait(function()
      term = find_buf(function(b)
        return vim.bo[b].buftype == 'terminal'
      end)
      if not term then
        return false
      end
      local text = buffer_text(term)
      return text:find('Counterspell', 1, true) ~= nil and text:find('PREVIEW Lightning Bolt', 1, true) ~= nil
    end, 'fzf-lua picker or preview not shown')
    -- Tab toggles and moves down in --multi mode; Enter accepts.
    vim.api.nvim_chan_send(vim.bo[term].channel, '\t\t\r')
    wait(function()
      return result.chosen ~= nil
    end, 'fzf-lua accept did not call on_choose')
    assert.are.same({ 'Lightning Bolt', 'Counterspell' }, names(result.chosen))
  end)
end)
