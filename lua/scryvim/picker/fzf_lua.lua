--- fzf-lua adapter: multi-select with markdown preview.
local M = {}

function M.pick(items, opts)
  local fzf = require('fzf-lua')
  local lines, by_line = {}, {}
  for i, card in ipairs(items) do
    lines[i] = opts.format_item(card)
    by_line[lines[i]] = card
  end

  local preview
  if fzf.shell and fzf.shell.raw_preview_action_cmd then
    preview = fzf.shell.raw_preview_action_cmd(function(selected)
      local card = selected and by_line[selected[1]]
      return card and ('printf %%s %s'):format(vim.fn.shellescape(opts.preview(card))) or 'true'
    end)
  end

  fzf.fzf_exec(lines, {
    prompt = 'Scryfall> ',
    preview = preview,
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
