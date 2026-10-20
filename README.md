# scryvim

Neovim plugin for building Magic: The Gathering decks in plain-text decklists, backed by [Scryfall](https://scryfall.com) data.

- Card name completion through LSP, so it works with any completion engine.
- `:Scryvim search <query>` shows a Scryfall search in a popup you browse like any buffer (`j`/`k`, `/`), and inserts the cards you mark with `<Tab>` and add with `<CR>`.
- Mana costs as inlay hints; full card text on hover.
- Mana symbols colored by color in mana costs, hover and picker previews, using your colorscheme's colors (`:h scryvim-colors`).
- Optionally, card names colored by card type (`type_colors = true`).
- `:Scryvim sort` orders cards by mana value.
- `:Scryvim count <query>` counts the deck's cards that match any Scryfall query, such as `otag:removal` or `produces:r`. Keep counts in the deck with `// count removal: otag:removal` lines, which show their totals live.
- `:Scryvim mana` and `// count mana symbols` lines count the colored, colorless and snow mana symbols in the deck's mana costs, to help work out how many sources each color needs.

Lookups use a local copy of Scryfall's Oracle Cards bulk data, so nothing hits the network while you type.

## Requirements

- Neovim 0.11+
- `curl` and `gzip`
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim), [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) or [fzf-lua](https://github.com/ibhagwan/fzf-lua), if you prefer a fuzzy picker for search results

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

Comment lines like these show how many cards in the deck match, by quantity, and update as you edit:

```
// count removal: otag:removal
// count red sources: produces:r
// count mana symbols
```

A `// count mana symbols` line shows the deck's mana symbols by type, such as `{W} 12  {R} 23.5  {C} 2`. Hybrid symbols count half for each half (`{R/G}` is 0.5 R and 0.5 G, `{2/R}` is 0.5 R), Phyrexian symbols count half (`{R/P}` is 0.5 R), and generic mana doesn't count. Cards with two mana costs, such as adventures, split and modal double-faced cards, count both.

| Command | |
|---|---|
| `:Scryvim search [query]` | Scryfall search → results popup → insert or increment |
| `:[range]Scryvim sort` | Sort by mana value (block under cursor without a range) |
| `:[range]Scryvim count <query>` | Count cards matching a Scryfall query, by quantity (whole deck minus sideboard without a range) |
| `:[range]Scryvim mana` | Count mana symbols in mana costs by type, by quantity (whole deck minus sideboard without a range) |
| `:Scryvim update` | Refresh card data now |
| `:Scryvim info` | Card count and cache age |

No default keymaps. `<Plug>(scryvim-search)` and `<Plug>(scryvim-sort)` are provided:

```lua
vim.keymap.set('n', '<leader>ms', '<Plug>(scryvim-search)')
vim.keymap.set({ 'n', 'x' }, '<leader>mo', '<Plug>(scryvim-sort)')
```

Search results open in a popup that is a normal buffer: move with `j`/`k` or any motion, search with `/`, mark cards with `<Tab>` (or a visual selection), add them with `<CR>`, close with `q`. Set `picker = 'auto'` to use snacks.nvim, telescope.nvim or fzf-lua instead.

Hover (`K`), code actions (`gra`) and diagnostics come from the built-in LSP client.

## Configuration

Via `vim.g.scryvim` or `require('scryvim').setup(opts)`:

```lua
{
  extensions    = { 'dec', 'deck' },
  auto_download = true,
  max_age_days  = 7,
  inlay_hints   = true,
  colors        = true,
  type_colors   = false,
  diagnostics   = true,
  counts        = true,
  picker        = 'buffer',    -- 'auto' | 'snacks' | 'telescope' | 'fzf_lua' | 'select'
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
