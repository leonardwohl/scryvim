# scryvim

Neovim plugin for building Magic: The Gathering decks in plain-text decklists, backed by [Scryfall](https://scryfall.com) data.

- Card name completion through LSP, so it works with any completion engine.
- `:Scryvim search <query>` opens a fuzzy picker over a Scryfall search and inserts the chosen cards.
- Mana costs as inlay hints; full card text on hover.
- `:Scryvim sort` orders cards by mana value.

Lookups use a local copy of Scryfall's Oracle Cards bulk data, so nothing hits the network while you type.

## Requirements

- Neovim 0.11+
- `curl` and `gzip`
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim), [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) or [fzf-lua](https://github.com/ibhagwan/fzf-lua) for the picker

## Install

With lazy.nvim:

```lua
{ 'leonardwohl/scryvim' }
```

No `setup()` call is needed. Open a `.dec` or `.deck` file (or `:set ft=deck`); card data downloads on first use.

## Usage

```
Deck
4 Lightning Bolt
4x Counterspell (M10) 146
20 Island

Sideboard
SB: 2 Duress
```

| Command | |
|---|---|
| `:Scryvim search [query]` | Scryfall search → picker → insert or increment |
| `:[range]Scryvim sort` | Sort by mana value (block under cursor without a range) |
| `:Scryvim update` | Refresh card data now |
| `:Scryvim info` | Card count and cache age |

No default keymaps. `<Plug>(scryvim-search)` and `<Plug>(scryvim-sort)` are provided:

```lua
vim.keymap.set('n', '<leader>ms', '<Plug>(scryvim-search)')
vim.keymap.set({ 'n', 'x' }, '<leader>mo', '<Plug>(scryvim-sort)')
```

Hover (`K`), code actions (`gra`) and diagnostics come from the built-in LSP client.

## Configuration

Via `vim.g.scryvim` or `require('scryvim').setup(opts)`:

```lua
{
  extensions    = { 'dec', 'deck' },
  auto_download = true,
  max_age_days  = 7,
  inlay_hints   = true,
  diagnostics   = true,
  picker        = 'auto',      -- 'snacks' | 'telescope' | 'fzf_lua' | 'select'
  search        = { max_pages = 3 },
  cache_dir     = vim.fn.stdpath('cache') .. '/scryvim',
}
```

See `:h scryvim` for details.

## Development

Tests use [busted](https://lunarmodules.github.io/busted/) run by Neovim via [nlua](https://github.com/mfussenegger/nlua):

```sh
luarocks install busted
luarocks install nlua
make test    # busted
make lint    # stylua --check
```

Two opt-in suites run in CI:

- `SCRYVIM_TEST_PLUGINS=<dir>` drives the real snacks.nvim, telescope.nvim and fzf-lua pickers. `<dir>` holds checkouts of those three plus plenary.nvim, and `fzf` must be on `$PATH`.
- `SCRYVIM_LIVE=1 busted spec/live_spec.lua` talks to the real Scryfall API and downloads the full Oracle Cards file once.

## Disclaimer

scryvim is unofficial Fan Content. It is not produced by or endorsed by Scryfall or Wizards of the Coast. Card data is provided by Scryfall's API and bulk data.
