local config = require('scryvim.config')

describe('config.get', function()
  local saved

  before_each(function()
    saved = vim.g.scryvim
    vim.g.scryvim = { counts = false }
    config.setup({})
  end)

  after_each(function()
    vim.g.scryvim = saved
    config.setup({})
  end)

  it('returns the same table while nothing changes', function()
    local cfg = config.get()
    assert.are.equal(cfg, config.get())
    assert.is_false(cfg.counts)
  end)

  it('rebuilds after vim.g.scryvim changes', function()
    local cfg = config.get()
    vim.g.scryvim = { counts = true }
    local after = config.get()
    assert.are_not.equal(cfg, after)
    assert.is_true(after.counts)
  end)

  it('rebuilds after setup()', function()
    local cfg = config.get()
    config.setup({ icons = true })
    local after = config.get()
    assert.are_not.equal(cfg, after)
    assert.is_true(after.icons)
  end)
end)
