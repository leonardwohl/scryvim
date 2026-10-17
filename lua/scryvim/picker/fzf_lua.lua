--- fzf-lua adapter: multi-select with markdown preview.
local M = {}

function M.pick(items, opts)
  local fzf = require('fzf-lua')
  local lines, by_line = {}, {}
  for i, card in ipairs(items) do
    lines[i] = opts.format_item(card)
    by_line[lines[i]] = card
  end

  fzf.fzf_exec(lines, {
    prompt = 'Scryfall> ',
    -- fzf-lua runs a Lua function preview in Neovim and shows what it returns.
    preview = function(selected)
      local card = selected and by_line[selected[1]]
      return card and opts.preview(card) or ''
    end,
    fzf_opts = { ['--multi'] = true },
    actions = {
      ['default'] = function(selected)
        local cards = {}
        for _, line in ipairs(selected or {}) do
          cards[#cards + 1] = by_line[line]
        end
        opts.on_choose(cards)
      end,
    },
  })
end

return M
