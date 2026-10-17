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

-- Straight to the client, so methods the server doesn't advertise under the
-- current config (inlay hints) still reach it.
local function request(method, params)
  local res = vim.lsp.get_client_by_id(client_id):request_sync(method, params, 5000, buf)
  assert(res, 'no response to ' .. method)
  assert(not res.err, vim.inspect(res.err))
  return res.result
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
    -- With colors on, scryvim.mana draws them instead.
    assert.is_false(vim.lsp.get_client_by_id(client_id).server_capabilities.inlayHintProvider)
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

  it('colors card names by color identity with semantic tokens', function()
    local legend = vim.lsp.get_client_by_id(client_id).server_capabilities.semanticTokensProvider.legend
    assert.are.same(require('scryvim.colors').TOKEN_TYPES, legend.tokenTypes)
    local tokens = request('textDocument/semanticTokens/full', { textDocument = doc() }).data
    local by_line, row = {}, 0
    for i = 1, #tokens, 5 do
      row = row + tokens[i]
      local s, len = tokens[i + 1], tokens[i + 2]
      by_line[row] = {
        LINES[row + 1]:sub(s + 1, s + len),
        legend.tokenTypes[tokens[i + 3] + 1],
        tokens[i + 4] == 1 and 'land' or nil,
      }
    end
    assert.are.same({
      [1] = { 'Lightning Bolt', 'red' },
      [2] = { 'Counterspell', 'blue' },
      [3] = { 'Fire // Ice', 'multicolor' },
      [4] = { 'Island', 'blue', 'land' },
      [5] = { 'Wrath of God', 'white' },
      [6] = { 'Delver of Secrets', 'blue' },
      [10] = { 'Jace, the Mind Sculptor', 'blue' },
    }, by_line)
  end)

  it('highlights card names through the client', function()
    vim.api.nvim_set_current_buf(buf)
    local found
    assert(vim.wait(3000, function()
      found = vim.lsp.semantic_tokens.get_at_pos(buf, 4, 3)
      return found ~= nil and #found > 0
    end))
    assert.are.equal('blue', found[1].type)
    assert.are.same({ land = true }, found[1].modifiers)
    -- The count is not highlighted.
    assert.are.same({}, vim.lsp.semantic_tokens.get_at_pos(buf, 4, 0) or {})
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

describe('lsp while card data downloads', function()
  it('reports progress and explains empty hovers', function()
    helpers.block_network()
    local dir = helpers.load_fixture()
    local data = require('scryvim.data')
    data._reset()
    vim.g.scryvim = { cache_dir = dir, auto_download = false }
    local http = require('scryvim.http')
    local get_json, download = http.get_json, http.download
    local finish_download
    http.get_json = function(_, cb)
      cb(nil, { jsonl_download_uri = 'https://data.example/x.jsonl.gz', updated_at = 'u' })
    end
    http.download = function(_, path, cb)
      vim.uv.fs_copyfile(helpers.fixture, path)
      finish_download = cb
    end

    local progress, requests = {}, {}
    local server = require('scryvim.lsp').create({
      notification = function(method, params)
        if method == '$/progress' then
          progress[#progress + 1] = params.value.kind .. ':' .. (params.value.message or '')
        end
      end,
      server_request = function(method)
        requests[#requests + 1] = method
        return nil, vim.NIL
      end,
      on_exit = function() end,
      on_error = function() end,
    })
    local function call(method, params)
      local res
      server.request(method, params, function(_, r)
        res = { r }
      end)
      assert(vim.wait(2000, function()
        return res ~= nil
      end))
      return res[1]
    end
    server.notify('textDocument/didOpen', { textDocument = { uri = 'file:///x.deck', text = '4 Lightning Bolt\n' } })
    data.update({ force = true })
    assert(vim.wait(2000, function()
      return finish_download ~= nil
    end))
    local hover = call('textDocument/hover', {
      textDocument = { uri = 'file:///x.deck' },
      position = { line = 0, character = 3 },
    })
    assert.are.equal('*scryvim: downloading card data from scryfall…*', hover.contents.value)

    finish_download(nil)
    assert(
      vim.wait(5000, function()
        return data.ready() and progress[#progress] and progress[#progress]:find('^end') ~= nil
      end),
      vim.inspect(progress)
    )
    http.get_json, http.download = get_json, download
    server.terminate()

    assert.are.same({
      'begin:Checking Scryfall for new card data',
      'report:Downloading card data from Scryfall',
      'report:Building the card index',
      'report:Loading card data',
      'end:Card data ready',
    }, progress)
    assert.are.equal('window/workDoneProgress/create', requests[1])
  end)
end)
