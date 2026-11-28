local open = require('scryvim.open')

describe('open', function()
  local base = 'https://scryfall.com/search?q='

  local saved

  before_each(function()
    saved = { vim.env.SSH_TTY, vim.env.SSH_CONNECTION, vim.g.scryvim }
    vim.env.SSH_TTY, vim.env.SSH_CONNECTION = nil, nil
    vim.g.scryvim = nil
  end)

  after_each(function()
    vim.env.SSH_TTY, vim.env.SSH_CONNECTION, vim.g.scryvim = saved[1], saved[2], saved[3]
  end)

  it('searches the exact name without count or SB:', function()
    local bolt = base .. '%21%22Lightning%20Bolt%22'
    for _, line in ipairs({
      'Lightning Bolt',
      '4 Lightning Bolt',
      '  SB: 2 Lightning Bolt  ',
    }) do
      assert.are.equal(bolt, open.url(line), line)
    end
  end)

  it("opens the line's printing", function()
    assert.are.equal('https://scryfall.com/card/m10/146', open.url('4x Lightning Bolt (M10) 146'))
    assert.are.equal('https://scryfall.com/card/plst/CLB-187', open.url('1 Lightning Bolt (PLST) CLB-187 *F*'))
    -- A set code alone searches that set.
    assert.are.equal(base .. '%21%22Lightning%20Bolt%22%20set%3Am10', open.url('  SB: 2 Lightning Bolt [M10]  '))
    assert.are.equal(base .. '%21%22Lightning%20Bolt%22%20set%3Am10', open.url('1 Lightning Bolt (M10) *F*'))
  end)

  it('encodes split card names and punctuation', function()
    assert.are.equal(base .. '%21%22Fire%20%2F%2F%20Ice%22', open.url('1 Fire // Ice'))
    assert.are.equal(base .. '%21%22Jace%2C%20the%20Mind%20Sculptor%22', open.url('Jace, the Mind Sculptor'))
    assert.are.equal(base .. '%21%22R%26D%27s%20Secret%20Lair%22', open.url("R&D's Secret Lair"))
  end)

  it('has no URL for non-card lines', function()
    for _, line in ipairs({ '', 'Sideboard', 'SB:', '// Removal (otag:removal)', '# note' }) do
      assert.is_nil(open.url(line), line)
    end
  end)

  it('opens the cursor line with vim.ui.open', function()
    local orig = vim.ui.open
    local opened
    vim.ui.open = function(url)
      opened = url
      return {
        wait = function()
          return { code = 0 }
        end,
      }, nil
    end
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Deck', '4 Counterspell' })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    require('scryvim').open()
    assert.are.equal(base .. '%21%22Counterspell%22', opened)

    opened = nil
    local notify = vim.notify
    local warned
    vim.notify = function(msg)
      warned = msg
    end
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    require('scryvim').open()
    vim.notify, vim.ui.open = notify, orig
    assert.is_nil(opened)
    assert.are.equal('scryvim: no card on this line', warned)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('reports an opener that fails or is missing', function()
    local orig, notify = vim.ui.open, vim.notify
    local msgs = {}
    vim.notify = function(msg, level)
      msgs[#msgs + 1] = { msg, level }
    end
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Duress' })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local url = base .. '%21%22Duress%22'

    vim.ui.open = function()
      return {
        cmd = { 'xdg-open', url },
        wait = function()
          return { code = 3, stderr = 'no method available\n' }
        end,
      }
    end
    require('scryvim').open()
    vim.ui.open = function()
      return nil, 'vim.ui.open: no handler found'
    end
    require('scryvim').open()
    vim.ui.open, vim.notify = orig, notify
    vim.api.nvim_buf_delete(buf, { force = true })

    assert.are.same({
      { 'scryvim: could not open ' .. url .. ': xdg-open failed (3): no method available', vim.log.levels.ERROR },
      { 'scryvim: could not open ' .. url .. ': vim.ui.open: no handler found', vim.log.levels.ERROR },
    }, msgs)
  end)

  it('copies the URL over SSH, or always with open = copy', function()
    local orig_open, orig_copy, notify = vim.ui.open, open._copy, vim.notify
    local opened, copied, msg = 0, {}, nil
    vim.ui.open = function()
      opened = opened + 1
      return {
        wait = function()
          return { code = 0 }
        end,
      }, nil
    end
    open._copy = function(url)
      copied[#copied + 1] = url
    end
    vim.notify = function(m)
      msg = m
    end
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '2 Duress' })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local url = base .. '%21%22Duress%22'

    vim.env.SSH_TTY = '/dev/pts/3'
    require('scryvim').open()
    assert.are.same({ url }, copied)
    assert.are.equal('scryvim: copied ' .. url, msg)

    vim.g.scryvim = { open = 'browser' }
    require('scryvim').open()
    assert.are.equal(1, opened)

    vim.env.SSH_TTY = nil
    vim.g.scryvim = { open = 'copy' }
    require('scryvim').open()
    assert.are.same({ url, url }, copied)
    assert.are.equal(1, opened)

    vim.ui.open, open._copy, vim.notify = orig_open, orig_copy, notify
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
