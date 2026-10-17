local M = {}

function M.check()
  local h = vim.health
  h.start('scryvim')

  if vim.fn.has('nvim-0.11') == 1 then
    h.ok('Neovim ' .. tostring(vim.version()))
  else
    h.error('Neovim 0.11 or newer is required')
  end
  for _, exe in ipairs({ 'curl', 'gzip' }) do
    if vim.fn.executable(exe) == 1 then
      h.ok(exe .. ' found')
    else
      h.error(exe .. ' not found on $PATH')
    end
  end

  local ok, cfg = pcall(require('scryvim.config').get)
  if not ok then
    h.error('invalid configuration: ' .. tostring(cfg))
    return
  end

  local data = require('scryvim.data')
  local info = data.info()
  h.info('cache: ' .. info.cache_dir)
  if vim.uv.fs_stat(data.paths().cards) then
    h.ok(('card data present; %d cards loaded'):format(info.count))
  else
    h.warn('no card data yet', { 'Open a deck buffer or run :Scryvim update' })
  end
  h.info('data updated_at: ' .. (info.updated_at or 'unknown'))
  if info.age_days then
    local msg = ('cache age %.1f days (max_age_days = %d)'):format(info.age_days, cfg.max_age_days)
    if info.age_days > cfg.max_age_days then
      h.warn(msg)
    else
      h.ok(msg)
    end
  end
  if info.last_error then
    h.warn('last error: ' .. info.last_error)
  end

  local _, name = require('scryvim.picker').adapter(cfg.picker)
  h.info('picker adapter: ' .. name)
end

return M
