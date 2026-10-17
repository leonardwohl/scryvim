--- telescope.nvim adapter: multi-select with markdown preview.
local M = {}

function M.pick(items, opts)
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local conf = require('telescope.config').values
  local finders = require('telescope.finders')
  local pickers = require('telescope.pickers')
  local previewers = require('telescope.previewers')

  pickers
    .new({}, {
      prompt_title = opts.prompt,
      finder = finders.new_table({
        results = items,
        entry_maker = function(card)
          return { value = card, display = opts.format_item(card), ordinal = card.name }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        define_preview = function(self, entry)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(opts.preview(entry.value), '\n'))
          vim.bo[self.state.bufnr].filetype = 'markdown'
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local picker = action_state.get_current_picker(prompt_bufnr)
          local entries = picker:get_multi_selection()
          if #entries == 0 then
            entries = { action_state.get_selected_entry() }
          end
          actions.close(prompt_bufnr)
          local cards = {}
          for _, e in ipairs(entries) do
            cards[#cards + 1] = e.value
          end
          opts.on_choose(cards)
        end)
        return true
      end,
    })
    :find()
end

return M
