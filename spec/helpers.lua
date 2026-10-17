local M = {}

M.root = vim.fn.getcwd()
M.fixture = M.root .. '/spec/fixtures/oracle-cards.jsonl.gz'

--- Build the fixture into a fresh cache dir and load it. Returns the dir.
function M.load_fixture()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.g.scryvim = { cache_dir = dir, auto_download = false }
  local data = require('scryvim.data')
  data._reset()
  local done, err = false, nil
  data.build(M.fixture, dir .. '/cards.json', function(e)
    err, done = e, true
  end)
  assert(
    vim.wait(10000, function()
      return done
    end),
    'build timed out'
  )
  assert(not err, err)
  local meta = assert(io.open(dir .. '/meta.json', 'w'))
  meta:write(vim.json.encode({ updated_at = 'fixture', checked_at = os.time(), format = data.CACHE_FORMAT }))
  meta:close()
  assert(data.load_file(dir .. '/cards.json'))
  return dir
end

--- Fail any test that reaches the network.
function M.block_network()
  require('scryvim.http')._system = function(cmd)
    error('network access in tests: ' .. table.concat(cmd, ' '))
  end
end

return M
