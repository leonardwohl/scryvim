local build = require('scryvim.build')
local helpers = require('helpers')
local http = require('scryvim.http')
local tags = require('scryvim.tags')

local BOLT = '10000000-0000-0000-0000-000000000001'
local COUNTERSPELL = '10000000-0000-0000-0000-000000000002'
local MOUNTAIN = '10000000-0000-0000-0000-000000000015'

describe('tags', function()
  local download = http.download
  local dir, downloads

  local function settle()
    assert(vim.wait(10000, function()
      return not tags.info().updating
    end, 10))
  end

  before_each(function()
    helpers.block_network()
    dir = vim.fn.tempname()
    vim.g.scryvim = { cache_dir = dir }
    tags._reset()
    downloads = 0
    http.download = function(url, path, cb)
      assert.are.equal(tags.URL, url)
      downloads = downloads + 1
      vim.uv.fs_copyfile(helpers.root .. '/spec/fixtures/oracle-tags.json', path)
      vim.schedule(function()
        cb(nil)
      end)
    end
  end)

  after_each(function()
    http.download = download
  end)

  it('builds one line per card, labels sorted and listed once', function()
    vim.fn.mkdir(dir, 'p')
    assert.are.equal(4, build.tags(helpers.root .. '/spec/fixtures/oracle-tags.json', dir .. '/tags.txt'))
    local f = assert(io.open(dir .. '/tags.txt'))
    local text = f:read('*a')
    f:close()
    local lines = vim.split(vim.trim(text), '\n')
    assert.are.same({ labels = { 'burn', 'counterspell', 'removal' } }, vim.json.decode(lines[1]))
    assert.are.same(BOLT .. '\t1,3', lines[2])
  end)

  it('downloads the tag list on first use, then looks cards up', function()
    local ready = 0
    local unsubscribe = tags.on_ready(function()
      ready = ready + 1
    end)
    assert.are.same({ nil, nil }, { tags.get(BOLT) })
    settle()
    unsubscribe()
    assert.are.equal(1, ready)
    assert.are.same({ 'burn', 'removal' }, tags.get(BOLT))
    assert.are.same({ 'counterspell' }, tags.get(COUNTERSPELL))
    assert.are.same({}, tags.get(MOUNTAIN))
    assert.is_nil(vim.uv.fs_stat(dir .. '/oracle-tags.json'), 'the download should be removed')

    -- A new session reads the cache without downloading again.
    tags._reset()
    assert.are.same({ 'burn', 'removal' }, tags.get(BOLT))
    assert.are.equal(1, downloads)
  end)

  it('refreshes a cache older than max_age_days in the background', function()
    tags.update()
    settle()
    local path = dir .. '/tags.txt'
    local old = os.time() - 8 * 86400
    vim.uv.fs_utime(path, old, old)
    tags._reset()
    assert.are.same({ 'burn', 'removal' }, tags.get(BOLT))
    settle()
    assert.are.equal(2, downloads)
  end)

  it('reports a failed download instead of retrying', function()
    http.download = function(_, _, cb)
      downloads = downloads + 1
      vim.schedule(function()
        cb('download failed (HTTP 500)')
      end)
    end
    tags.get(BOLT)
    settle()
    assert.are.same({ nil, 'download failed (HTTP 500)' }, { tags.get(BOLT) })
    assert.are.equal(1, downloads)
  end)

  it('does not download without auto_download', function()
    vim.g.scryvim = { cache_dir = dir, auto_download = false }
    assert.are.same({ nil, 'not downloaded; run :Scryvim update' }, { tags.get(BOLT) })
    assert.are.equal(0, downloads)
  end)
end)
