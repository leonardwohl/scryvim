--- Saved counts in the deck file: `// count <label>: <query>` comment lines
--- show how many deck cards match their query, refreshed as the deck
--- changes. The label is optional and only for the reader.
local count = require('scryvim.count')
local data = require('scryvim.data')

local M = {}

M.ns = vim.api.nvim_create_namespace('scryvim.tally')

--- Quiet time after an edit before asking Scryfall, so half-typed card
--- names and queries are not sent.
M.DEBOUNCE_MS = 1000

-- Buffer -> { timer, generation, unsubscribe }.
local attached = {} ---@type table<integer, table>

--- The query of a count line, or nil.
---@param line string
---@return string|nil
function M.query(line)
  local rest = line:match('^%s*//%s*(.*)$') or line:match('^%s*#%s*(.*)$')
  local q = rest and (rest:match('^[Cc]ount:(.*)$') or rest:match('^[Cc]ount%s[^:]*:(.*)$'))
  q = q and vim.trim(q)
  return q ~= '' and q or nil
end

local function mark(buf, row, text, hl)
  vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
    virt_text = { { text, hl } },
    virt_text_pos = 'eol',
    hl_mode = 'combine',
  })
end

--- Recount every count line in `buf` now.
---@param buf integer
function M.refresh(buf)
  local state = attached[buf]
  if not state or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  state.generation = state.generation + 1
  local generation = state.generation
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local rows = {}
  for i, line in ipairs(lines) do
    local q = M.query(line)
    if q then
      rows[#rows + 1] = { row = i - 1, query = q }
    end
  end
  if #rows == 0 then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    return
  end
  local entries = count.entries(lines, data.get)
  local results, pending = {}, #rows
  for i, r in ipairs(rows) do
    count.run(r.query, entries, function(err, result)
      results[i] = { err = err, result = result }
      pending = pending - 1
      -- Draw once all are back, so marks never point at moved lines.
      if pending > 0 or attached[buf] ~= state or state.generation ~= generation then
        return
      end
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
      for j, row in ipairs(rows) do
        local res = results[j]
        if res.err then
          mark(buf, row.row, res.err, 'DiagnosticError')
        else
          mark(
            buf,
            row.row,
            ('%d %s'):format(res.result.total, res.result.total == 1 and 'card' or 'cards'),
            'LspInlayHint'
          )
        end
      end
    end)
  end
end

local function schedule(buf, delay)
  local state = attached[buf]
  if not state then
    return
  end
  state.timer:stop()
  state.timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      M.refresh(buf)
    end)
  )
end

---@param buf integer
function M.attach(buf)
  if attached[buf] then
    return
  end
  local state = { timer = assert(vim.uv.new_timer()), generation = 0 }
  attached[buf] = state
  -- Store loads turn typed names into full card names.
  state.unsubscribe = data.on_ready(function()
    schedule(buf, 0)
  end)
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if attached[buf] ~= state then
        return true
      end
      schedule(buf, M.DEBOUNCE_MS)
    end,
    on_reload = function()
      schedule(buf, 0)
    end,
    on_detach = function()
      if attached[buf] == state then
        M.detach(buf)
      end
    end,
  })
  schedule(buf, 0)
end

---@param buf integer
function M.detach(buf)
  local state = attached[buf]
  if state then
    state.unsubscribe()
    state.timer:stop()
    state.timer:close()
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
