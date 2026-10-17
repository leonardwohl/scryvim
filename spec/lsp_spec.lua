local helpers = require('helpers')

local LINES = {
  'Deck',
  '4 Lightning Bolt',
  '2 Counterspell',
  '1 Fire // Ice',
  '3 Island',
  '1 Wrath of God',
  '1 Delver of Secrets',
  '1 Not A Real Card',
  '',
  'Sideboard',
  '2 Jace, the Mind Sculptor',
}

local buf, client_id

local function request(method, params)
  local res = vim.lsp.buf_request_sync(buf, method, params, 5000)
  assert(res and res[client_id], 'no response to ' .. method)
  assert(not res[client_id].err, vim.inspect(res[client_id].err))
  return res[client_id].result
end

local function doc()
  return { uri = vim.uri_from_bufnr(buf) }
end

local function pos(line, character)
  return { textDocument = doc(), position = { line = line, character = character } }
end

describe('lsp', function()
  setup(function()
    helpers.block_network()
    helpers.load_fixture()
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '.deck')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)
    client_id = assert(vim.lsp.start({
      name = 'scryvim',
      cmd = function(dispatchers)
        return require('scryvim.lsp').create(dispatchers)
      end,
    }, { bufnr = buf }))
    assert(vim.wait(5000, function()
      local client = vim.lsp.get_client_by_id(client_id)
      return client ~= nil and client.initialized == true
    end))
  end)

  teardown(function()
    vim.lsp.stop_client(client_id, true)
  end)

  it('negotiates utf-8 positions', function()
    assert.are.equal('utf-8', vim.lsp.get_client_by_id(client_id).offset_encoding)
  end)

  it('completes card names with a textEdit over the name span', function()
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '4 Lightn (M10) 146' })
    local result = request('textDocument/completion', pos(1, 7))
    assert.is_true(result.isIncomplete)
    local item = result.items[1]
    assert.are.equal('Lightning Bolt', item.label)
    assert.are.equal('{R} · Instant', item.detail)
    assert.are.equal('markdown', item.documentation.kind)
    assert.are.same({
      range = { start = { line = 1, character = 2 }, ['end'] = { line = 1, character = 8 } },
      newText = 'Lightning Bolt',
    }, item.textEdit)
    -- Cursor inside the set suffix: no completion.
    assert.are.same({}, request('textDocument/completion', pos(1, 12)).items)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { LINES[2] })
  end)

  it('renders hover markdown', function()
    local result = request('textDocument/hover', pos(1, 5))
    assert.are.equal('markdown', result.contents.kind)
    local md = result.contents.value
    assert.truthy(md:find('**Lightning Bolt**  {R}', 1, true))
    assert.truthy(md:find('*Instant*', 1, true))
    assert.truthy(md:find('Lightning Bolt deals 3 damage to any target.', 1, true))
    assert.truthy(md:find('[Scryfall](https://scryfall.com/card/', 1, true))
  end)

  it('renders one hover block per face, with stats', function()
    local md = request('textDocument/hover', pos(6, 5)).contents.value
    assert.truthy(md:find('**Delver of Secrets**  {U}', 1, true))
    assert.truthy(md:find('**Insectile Aberration**', 1, true))
    assert.truthy(md:find('P/T: 3/2', 1, true))
    md = request('textDocument/hover', pos(10, 5)).contents.value
    assert.truthy(md:find('Loyalty: 3', 1, true))
  end)

  it('returns no hover for unknown cards or non-card lines', function()
    assert.is_nil(request('textDocument/hover', pos(7, 5)))
    assert.is_nil(request('textDocument/hover', pos(0, 1)))
  end)

  it('shows mana costs as inlay hints, skipping lands and unknown cards', function()
    local hints = request('textDocument/inlayHint', {
      textDocument = doc(),
      range = { start = { line = 0, character = 0 }, ['end'] = { line = #LINES, character = 0 } },
    })
    local by_line = {}
    for _, h in ipairs(hints) do
      by_line[h.position.line] = h.label
      assert.is_true(h.paddingLeft)
      assert.are.equal(#LINES[h.position.line + 1], h.position.character)
    end
    assert.are.same({
      [1] = '{R}',
      [2] = '{U}{U}',
      [3] = '{1}{R} // {1}{U}',
      [5] = '{2}{W}{W}',
      [6] = '{U}',
      [10] = '{2}{U}{U}',
    }, by_line)
  end)

  it('offers a sort code action for the block under the cursor', function()
    local actions = request('textDocument/codeAction', {
      textDocument = doc(),
      range = { start = { line = 2, character = 0 }, ['end'] = { line = 2, character = 0 } },
      context = { diagnostics = {} },
    })
    assert.are.equal(1, #actions)
    assert.are.equal('Sort by mana value', actions[1].title)
    assert.are.equal('refactor.rewrite', actions[1].kind)
    vim.lsp.util.apply_workspace_edit(actions[1].edit, 'utf-8')
    assert.are.same({
      'Deck',
      '1 Delver of Secrets',
      '4 Lightning Bolt',
      '2 Counterspell',
      '1 Fire // Ice',
      '1 Wrath of God',
      '3 Island',
      '1 Not A Real Card',
      '',
      'Sideboard',
      '2 Jace, the Mind Sculptor',
    }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)
  end)

  it('publishes unknown-card diagnostics', function()
    local ns_diags
    assert(
      vim.wait(3000, function()
        ns_diags = vim.diagnostic.get(buf)
        return #ns_diags == 1
      end),
      vim.inspect(vim.diagnostic.get(buf))
    )
    local d = ns_diags[1]
    assert.are.equal(7, d.lnum)
    assert.are.equal(2, d.col)
    assert.are.equal(#LINES[8], d.end_col)
    assert.are.equal(vim.diagnostic.severity.WARN, d.severity)
    assert.are.equal('Unknown card: Not A Real Card', d.message)
  end)
end)
