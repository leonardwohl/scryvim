local helpers = require('helpers')
local attach = require('scryvim.attach')

describe('attach', function()
  local ns = vim.api.nvim_create_namespace('scryvim.attach_spec')
  local buf, decor, renders, currents

  local function settle(ms)
    vim.wait(ms or 50, function()
      return false
    end)
  end

  setup(function()
    helpers.block_network()
  end)

  before_each(function()
    renders, currents = 0, {}
    decor = attach.new(ns, {
      edit_delay = 10,
      render = function(_, current)
        renders = renders + 1
        currents[#currents + 1] = current
      end,
    })
    buf = vim.api.nvim_create_buf(true, false)
  end)

  after_each(function()
    decor.detach(buf)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it('renders once on attach and once after a burst of edits', function()
    decor.attach(buf)
    settle()
    assert.are.equal(1, renders)
    for i = 1, 5 do
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line ' .. i })
    end
    settle()
    assert.are.equal(2, renders)
  end)

  it('does not render twice after a detach and re-attach', function()
    decor.attach(buf)
    settle()
    decor.detach(buf)
    decor.attach(buf)
    settle()
    renders = 0
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'edit' })
    settle()
    assert.are.equal(1, renders)
  end)

  it('turns current() false after an edit or a detach', function()
    decor.attach(buf)
    settle()
    local current = currents[1]
    assert.is_true(current())
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'edit' })
    assert.is_false(current())
    settle()
    current = currents[#currents]
    assert.is_true(current())
    decor.detach(buf)
    assert.is_false(current())
  end)

  it('clears its namespace on detach', function()
    decor.attach(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x' })
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {})
    decor.detach(buf)
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
    assert.is_false(decor.is_attached(buf))
  end)

  it('closes the timer when the buffer is wiped', function()
    decor.attach(buf)
    local timer = decor._timer(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_true(timer:is_closing())
    assert.is_false(decor.is_attached(buf))
  end)
end)
