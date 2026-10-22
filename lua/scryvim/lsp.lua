--- In-process LSP server (see `:h lsp-server`).
local config = require('scryvim.config')
local data = require('scryvim.data')
local icons = require('scryvim.icons')
local parse = require('scryvim.parse')
local render = require('scryvim.render')
local sort = require('scryvim.sort')
local types = require('scryvim.types')

local M = {}

M.DIAGNOSTIC_DEBOUNCE_MS = 200

M.STAGE_MESSAGES = {
  checking = 'Checking Scryfall for new card data',
  downloading = 'Downloading card data from Scryfall',
  building = 'Building the card index',
  loading = 'Loading card data',
}

local function split_lines(text)
  local lines = vim.split((text:gsub('\r', '')), '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  return lines
end

local function range(line, s, e)
  return { start = { line = line, character = s }, ['end'] = { line = line, character = e } }
end

local function card_at(lines, row)
  local line = lines and lines[row + 1]
  if not line then
    return nil
  end
  local parsed = parse.parse(line)
  if parsed.kind ~= 'card' then
    return nil
  end
  return parsed, data.get(parsed.name)
end

--- Create a server instance. Passed as `cmd` to `vim.lsp.config`.
---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
function M.create(dispatchers)
  local docs = {} ---@type table<string, string[]>
  local timers = {} ---@type table<string, uv.uv_timer_t>
  local closing = false
  local next_id = 0
  local handlers = {}

  local function diagnostics(uri)
    local out = {}
    local lines = docs[uri]
    if not lines or not data.ready() or not config.get().diagnostics then
      return out
    end
    for i, line in ipairs(lines) do
      local parsed = parse.parse(line)
      if parsed.kind == 'card' and not data.get(parsed.name) then
        out[#out + 1] = {
          range = range(i - 1, parsed.name_range[1], parsed.name_range[2]),
          severity = vim.lsp.protocol.DiagnosticSeverity.Warning,
          source = 'scryvim',
          message = 'Unknown card: ' .. parsed.name,
        }
      end
    end
    return out
  end

  local function publish(uri)
    if closing then
      return
    end
    dispatchers.notification('textDocument/publishDiagnostics', { uri = uri, diagnostics = diagnostics(uri) })
  end

  local function schedule_publish(uri, delay)
    local timer = timers[uri]
    if not timer then
      timer = assert(vim.uv.new_timer())
      timers[uri] = timer
    end
    timer:stop()
    timer:start(
      delay,
      0,
      vim.schedule_wrap(function()
        publish(uri)
      end)
    )
  end

  local function stop_timer(uri)
    local timer = timers[uri]
    if timer then
      timer:stop()
      timer:close()
      timers[uri] = nil
    end
  end

  local unsubscribe = data.on_ready(function()
    vim.schedule(function()
      if closing then
        return
      end
      for uri in pairs(docs) do
        publish(uri)
      end
      pcall(dispatchers.server_request, 'workspace/inlayHint/refresh', nil)
      if config.get().type_colors then
        pcall(dispatchers.server_request, 'workspace/semanticTokens/refresh', nil)
      end
    end)
  end)

  -- Card data progress, shown by any UI that displays LSP progress
  -- (`vim.lsp.status()`, fidget.nvim, noice, snacks).
  local progress_token
  local progress_count = 0
  local last_stage
  local function report_stage(stage)
    if closing or stage == last_stage then
      return
    end
    last_stage = stage
    if stage and not progress_token then
      progress_count = progress_count + 1
      progress_token = 'scryvim-data-' .. progress_count
      pcall(dispatchers.server_request, 'window/workDoneProgress/create', { token = progress_token })
      dispatchers.notification('$/progress', {
        token = progress_token,
        value = { kind = 'begin', title = 'scryvim', message = M.STAGE_MESSAGES[stage] },
      })
    elseif stage then
      dispatchers.notification('$/progress', {
        token = progress_token,
        value = { kind = 'report', message = M.STAGE_MESSAGES[stage] },
      })
    elseif progress_token then
      dispatchers.notification('$/progress', {
        token = progress_token,
        value = { kind = 'end', message = data.ready() and 'Card data ready' or 'Card data unavailable' },
      })
      progress_token = nil
    end
  end
  local unprogress = data.on_progress(function(stage)
    vim.schedule(function()
      report_stage(stage)
    end)
  end)

  handlers['initialize'] = function()
    data.ensure()
    local colored = config.get().colors
    local capabilities = {
      positionEncoding = 'utf-8',
      textDocumentSync = { openClose = true, change = 1 },
      completionProvider = {},
      hoverProvider = true,
      -- With colors on, scryvim.mana draws the mana costs instead, so a
      -- config that enables inlay hints for every server doesn't show them
      -- twice.
      inlayHintProvider = not colored,
      codeActionProvider = { codeActionKinds = { 'refactor.rewrite' } },
    }
    if config.get().type_colors then
      capabilities.semanticTokensProvider = {
        legend = { tokenTypes = types.TYPES, tokenModifiers = {} },
        full = true,
      }
    end
    return {
      capabilities = capabilities,
      serverInfo = { name = 'scryvim', version = require('scryvim.http').version },
    }
  end

  handlers['shutdown'] = function()
    return nil
  end

  handlers['textDocument/completion'] = function(params)
    local empty = { isIncomplete = true, items = {} }
    local line = docs[params.textDocument.uri] and docs[params.textDocument.uri][params.position.line + 1]
    if not line or not data.ready() then
      return empty
    end
    local kind = parse.parse(line).kind
    if kind == 'comment' then
      return empty
    end
    local card = parse.card(line, true)
    local col = params.position.character
    if not card or col < card.name_range[1] or (card.has_set and col > card.name_range[2]) then
      return empty
    end
    local typed = line:sub(card.name_range[1] + 1, col)
    -- A bare count ("1", "4x") with no space yet: still typing the count.
    if not card.count_range and typed:match('^%d+[xX]?$') then
      return empty
    end
    local edit_range = range(params.position.line, card.name_range[1], math.max(card.name_range[2], col))
    local items = {}
    for _, c in ipairs(data.complete(typed)) do
      items[#items + 1] = {
        label = c.name,
        kind = vim.lsp.protocol.CompletionItemKind.Value,
        detail = render.detail(c),
        documentation = { kind = 'markdown', value = render.markdown(c) },
        textEdit = { range = edit_range, newText = c.name },
      }
    end
    return { isIncomplete = true, items = items }
  end

  handlers['textDocument/hover'] = function(params)
    local parsed, card = card_at(docs[params.textDocument.uri], params.position.line)
    if not card then
      local stage = data.stage()
      if parsed and not data.ready() and stage then
        return { contents = { kind = 'markdown', value = '*scryvim: ' .. M.STAGE_MESSAGES[stage]:lower() .. '…*' } }
      end
      return nil
    end
    return {
      contents = { kind = 'markdown', value = render.markdown(card) },
      range = range(params.position.line, parsed.name_range[1], parsed.name_range[2]),
    }
  end

  handlers['textDocument/inlayHint'] = function(params)
    local lines = docs[params.textDocument.uri]
    local hints = {}
    if not lines then
      return hints
    end
    local last = math.min(params.range['end'].line, #lines - 1)
    for row = params.range.start.line, last do
      local _, card = card_at(lines, row)
      local cost = card and render.mana_cost(card)
      if cost then
        hints[#hints + 1] = {
          position = { line = row, character = #lines[row + 1] },
          label = icons.replace(cost),
          paddingLeft = true,
        }
      end
    end
    return hints
  end

  -- Card names, typed by their card type.
  handlers['textDocument/semanticTokens/full'] = function(params)
    local lines = docs[params.textDocument.uri]
    local out = {}
    if not lines or not data.ready() or not config.get().type_colors then
      return { data = out }
    end
    local prev_line, prev_start = 0, 0
    for row = 0, #lines - 1 do
      local parsed, card = card_at(lines, row)
      local t = card and types.of(card)
      if t then
        local s, e = parsed.name_range[1], parsed.name_range[2]
        local delta_start = row == prev_line and s - prev_start or s
        vim.list_extend(out, { row - prev_line, delta_start, e - s, types.INDEX[t], 0 })
        prev_line, prev_start = row, s
      end
    end
    return { data = out }
  end

  handlers['textDocument/codeAction'] = function(params)
    local uri = params.textDocument.uri
    local lines = docs[uri]
    if not lines or not data.ready() then
      return {}
    end
    local r = params.range
    local first, last
    if r.start.line == r['end'].line and r.start.character == r['end'].character then
      first, last = sort.block_at(lines, r.start.line + 1)
      if not first then
        return {}
      end
    else
      first, last = r.start.line + 1, r['end'].line + 1
      if r['end'].character == 0 and last > first then
        last = last - 1
      end
      last = math.min(last, #lines)
    end
    local segment = vim.list_slice(lines, first, last)
    local sorted = sort.lines(segment, data.get)
    if vim.deep_equal(segment, sorted) then
      return {}
    end
    return {
      {
        title = 'Sort by mana value',
        kind = 'refactor.rewrite',
        edit = {
          changes = {
            [uri] = {
              {
                range = {
                  start = { line = first - 1, character = 0 },
                  ['end'] = { line = last - 1, character = #lines[last] },
                },
                newText = table.concat(sorted, '\n'),
              },
            },
          },
        },
      },
    }
  end

  local notifications = {
    initialized = function()
      -- An update may already be running (another buffer started it).
      vim.schedule(function()
        report_stage(data.stage())
      end)
    end,
    ['textDocument/didOpen'] = function(params)
      docs[params.textDocument.uri] = split_lines(params.textDocument.text)
      schedule_publish(params.textDocument.uri, 0)
    end,
    ['textDocument/didChange'] = function(params)
      local changes = params.contentChanges
      docs[params.textDocument.uri] = split_lines(changes[#changes].text)
      schedule_publish(params.textDocument.uri, M.DIAGNOSTIC_DEBOUNCE_MS)
    end,
    ['textDocument/didClose'] = function(params)
      local uri = params.textDocument.uri
      stop_timer(uri)
      docs[uri] = nil
      dispatchers.notification('textDocument/publishDiagnostics', { uri = uri, diagnostics = {} })
    end,
  }

  local function terminate()
    if closing then
      return
    end
    closing = true
    unsubscribe()
    unprogress()
    for uri in pairs(timers) do
      stop_timer(uri)
    end
    vim.schedule(function()
      dispatchers.on_exit(0, 0)
    end)
  end

  return {
    request = function(method, params, callback, notify_reply_callback)
      next_id = next_id + 1
      local id = next_id
      vim.schedule(function()
        if notify_reply_callback then
          notify_reply_callback(id)
        end
        -- Newer clients read the request id from the third argument (the
        -- semantic token highlighter drops responses without it).
        local handler = handlers[method]
        if not handler then
          local err = { code = vim.lsp.protocol.ErrorCodes.MethodNotFound, message = 'unsupported: ' .. method }
          return callback(err, nil, id)
        end
        local ok, result = pcall(handler, params)
        if ok then
          callback(nil, result, id)
        else
          callback({ code = vim.lsp.protocol.ErrorCodes.InternalError, message = tostring(result) }, nil, id)
        end
      end)
      return true, id
    end,
    notify = function(method, params)
      if method == 'exit' then
        terminate()
      elseif notifications[method] then
        notifications[method](params)
      end
      return true
    end,
    is_closing = function()
      return closing
    end,
    terminate = terminate,
  }
end

return M
