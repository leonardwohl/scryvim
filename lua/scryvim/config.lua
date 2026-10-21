local M = {}

local function defaults()
  return {
    extensions = { 'dec', 'deck' },
    auto_download = true,
    max_age_days = 7,
    inlay_hints = true,
    colors = true,
    type_colors = false,
    icons = false,
    diagnostics = true,
    counts = true,
    picker = 'buffer',
    search = { max_pages = 3 },
    hover = { max_width = 60 },
    pane = { width = 50, auto_open = false },
    cache_dir = vim.fn.stdpath('cache') .. '/scryvim',
  }
end

local PICKERS = { buffer = true, auto = true, snacks = true, telescope = true, fzf_lua = true, select = true }

local user_opts = {}

--- Deep merge into the dict-shaped defaults; lists and scalars replace.
local function merge(base, over)
  if over == nil then
    return base
  end
  if type(base) ~= 'table' or vim.islist(base) or type(over) ~= 'table' then
    return over
  end
  local out = vim.deepcopy(base)
  for k, v in pairs(over) do
    out[k] = merge(base[k], v)
  end
  return out
end

local function validate(cfg)
  vim.validate('extensions', cfg.extensions, 'table')
  vim.validate('auto_download', cfg.auto_download, 'boolean')
  vim.validate('max_age_days', cfg.max_age_days, 'number')
  vim.validate('inlay_hints', cfg.inlay_hints, 'boolean')
  vim.validate('colors', cfg.colors, 'boolean')
  vim.validate('type_colors', cfg.type_colors, 'boolean')
  vim.validate('icons', cfg.icons, { 'boolean', 'table' })
  vim.validate('diagnostics', cfg.diagnostics, 'boolean')
  vim.validate('counts', cfg.counts, 'boolean')
  vim.validate('picker', cfg.picker, function(v)
    return (type(v) == 'string' and PICKERS[v] ~= nil) or (type(v) == 'table' and type(v.pick) == 'function')
  end, "one of 'buffer', 'auto', 'snacks', 'telescope', 'fzf_lua', 'select', or a table with pick()")
  vim.validate('search', cfg.search, 'table')
  vim.validate('search.max_pages', cfg.search.max_pages, 'number')
  vim.validate('hover', cfg.hover, 'table')
  vim.validate('hover.max_width', cfg.hover.max_width, 'number')
  vim.validate('pane', cfg.pane, 'table')
  vim.validate('pane.width', cfg.pane.width, 'number')
  vim.validate('pane.auto_open', cfg.pane.auto_open, 'boolean')
  vim.validate('cache_dir', cfg.cache_dir, 'string')
end

-- The last result of `M.get()` and what it was built from.
local last = nil ---@type { cfg: table, g: table|nil, user: table }|nil

--- Effective config: defaults < vim.g.scryvim < setup() opts. The result
--- is kept until `vim.g.scryvim` or the setup() opts change, and is shared
--- between callers, so treat it as read-only.
function M.get()
  local g = vim.g.scryvim
  if last and last.user == user_opts and vim.deep_equal(last.g, g) then
    return last.cfg
  end
  local cfg = merge(merge(defaults(), g or {}), user_opts)
  validate(cfg)
  -- `vim.g.scryvim` hands out a new copy on every read, so `g` is ours.
  last = { cfg = cfg, g = g, user = user_opts }
  return cfg
end

function M.setup(opts)
  user_opts = opts or {}
  return M.get()
end

return M
