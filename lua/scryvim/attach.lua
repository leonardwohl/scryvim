--- Buffer decorations that redraw as the buffer changes and the card data
--- loads: the lifecycle shared by the count line totals and the colored
--- mana costs.
---
--- One timer per buffer: card data loads, buffer reloads and the attach
--- itself render after 0 ms, edits after `edit_delay` (ms, or a function
--- returning it). `render(buf, current)` draws into `ns`; `current()` is
--- true while the buffer is still attached and nothing newer is on the
--- way, so a render that waits on Scryfall can drop replies for an old
--- buffer state.
local data = require('scryvim.data')

local M = {}

---@param ns integer
---@param opts { edit_delay: integer|fun(): integer, render: fun(buf: integer, current: fun(): boolean) }
function M.new(ns, opts)
  -- Buffer -> { timer, generation, unsubscribe }. Also identifies the
  -- attach, so a stale buffer callback can tell it was replaced.
  local attached = {} ---@type table<integer, table>
  local decor = {}

  --- Render `buf` now, when it is attached.
  ---@param buf integer
  function decor.render(buf)
    local state = attached[buf]
    if not state or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    state.generation = state.generation + 1
    local generation = state.generation
    opts.render(buf, function()
      return attached[buf] == state and state.generation == generation and vim.api.nvim_buf_is_valid(buf)
    end)
  end

  local function schedule(buf, delay)
    local state = attached[buf]
    if not state then
      return
    end
    -- What is drawing now is about to be out of date.
    state.generation = state.generation + 1
    state.timer:stop()
    state.timer:start(
      delay,
      0,
      vim.schedule_wrap(function()
        if attached[buf] == state then
          decor.render(buf)
        end
      end)
    )
  end

  ---@param buf integer
  function decor.attach(buf)
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
        local delay = opts.edit_delay
        schedule(buf, type(delay) == 'function' and delay() or delay)
      end,
      on_reload = function()
        schedule(buf, 0)
      end,
      on_detach = function()
        if attached[buf] == state then
          decor.detach(buf)
        end
      end,
    })
    schedule(buf, 0)
  end

  ---@param buf integer
  function decor.detach(buf)
    local state = attached[buf]
    if state then
      state.unsubscribe()
      state.timer:stop()
      state.timer:close()
      attached[buf] = nil
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end

  ---@param buf integer
  ---@return boolean
  function decor.is_attached(buf)
    return attached[buf] ~= nil
  end

  --- For tests: the timer of the attach to `buf`.
  function decor._timer(buf)
    return attached[buf] and attached[buf].timer
  end

  return decor
end

return M
