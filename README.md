# scryvim

Build Magic: The Gathering decks in plain-text decklists in Neovim, backed by [Scryfall](https://scryfall.com) data.

- **Completion** of card names, through LSP, so it works with any completion engine.
- **Mana costs** shown after each card, and **full card text** on hover (`K`).
- **Search** Scryfall from a popup and insert the cards you pick.
- **Live counts** in the deck: `// Removal (otag:removal)` shows `12 Removal` at its end.
- **Sort** by mana value, with lands after spells.
- **Preview pane** that follows the cursor and shows each card's odds of being cast on curve and its oracle tags.
- **Statusline** text with the deck's size and mana symbols, plus a lualine component.

Card lookups use a local copy of Scryfall's card data, so nothing hits the network while you type. Only search and count lines ask Scryfall.

## Requirements

- Neovim 0.11+
- `curl` and `gzip`
- Optional: a [Nerd Font](https://www.nerdfonts.com) (v3+), for mana symbol icons
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim), [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) or [fzf-lua](https://github.com/ibhagwan/fzf-lua), if you'd rather search with a fuzzy picker

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'leonardwohl/scryvim' }
```

`vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({ 'https://github.com/leonardwohl/scryvim' })
```

Or as a plain package:

```sh
git clone https://github.com/leonardwohl/scryvim ~/.local/share/nvim/site/pack/plugins/start/scryvim
nvim -c 'helptags ALL' -c q
```

No `setup()` call is needed, and startup cost is tiny, so don't lazy-load it on `ft = 'deck'`: the plugin itself is what gives `.deck` files that filetype.

Open a `.dec` or `.deck` file (or run `:set ft=deck` in any buffer). The first time, scryvim downloads Scryfall's card data, then refreshes it weekly in the background. Run `:checkhealth scryvim` if something seems off.

## Usage

A decklist is one card per line, with optional sections and comments:

```
Deck
4 Lightning Bolt
4x Counterspell (M10) 146
20 Island

// Removal (otag:removal)
// Red sources (produces:r)
// count mana symbols
// count cards

Sideboard
SB: 2 Duress
```

### Commands

| Command | What it does |
|---|---|
| `:Scryvim search [query]` | Search Scryfall and insert cards from the results |
| `:[range]Scryvim sort` | Sort by mana value: the block under the cursor, or the range |
| `:[range]Scryvim count <query>` | Count the cards matching a Scryfall query |
| `:[range]Scryvim mana` | Count mana symbols in mana costs, by color |
| `:Scryvim pane` | Toggle the preview pane |
| `:Scryvim update` | Refresh the card data and oracle tags now |
| `:Scryvim info` | Card count and cache age |

Without a range, `count` and `mana` cover the whole deck except the sideboard and maybeboard.

There are no default keymaps. Map the `<Plug>` ones if you like:

```lua
vim.keymap.set('n', '<leader>ms', '<Plug>(scryvim-search)')
vim.keymap.set({ 'n', 'x' }, '<leader>mo', '<Plug>(scryvim-sort)')
vim.keymap.set('n', '<leader>mp', '<Plug>(scryvim-pane)')
```

### Search

The results popup is a normal buffer: move with `j`/`k` or any motion, search with `/`, mark cards with `<Tab>` (or a visual selection), add them with `<CR>`, close with `q`. Adding a card that's already in the deck bumps its count. Set `picker = 'auto'` to use your fuzzy picker instead.

### Count lines

Comment lines that end in a Scryfall query in parentheses show a live total, so they read like section headers:

```
// Removal (otag:removal)                     12 Removal
# Red sources (produces:r)                    40 Red sources
// Cheap spells ((t:instant or t:sorcery) mv<=2)   9 Cheap spells
```

`//` and `#` both work. The query needs at least one Scryfall keyword or operator (`:`, `=`, `<`, `>`, `!`), so a comment like `// cut these (too slow)` stays a plain comment. Two special lines need no query:

- `// count mana symbols` shows `{W} 12  {R} 23.5  {C} 2`. Hybrid symbols count half for each color, and Phyrexian symbols count half.
- `// count cards` shows `60 cards  24 lands  36 nonlands`.

Counts leave out the sideboard and maybeboard. With the cursor on a count line, `:Scryvim sort` gathers the cards it counts under it.

### Preview pane

Decklists are tall and narrow, so a pane on the right follows the cursor. On a card it shows the full card, its odds of being cast on curve, on the play and on the draw, and its Scryfall oracle tags (the `otag:` names, handy for writing count lines). On a count line it lists the cards counted, and on `// count mana symbols` each color's share.

It opens on its own when the editor is at least 100 columns wide, and closes when it gets narrower. Set `pane = { auto_open = false }` to only open it with `:Scryvim pane`.

Scryfall's card data has no tags, so the first card the pane shows downloads Scryfall's oracle tag list (about 23 MB, once a week like the card data). Set `pane = { tags = false }` to leave tags out and skip the download.

The on-curve odds follow Frank Karsten's hypergeometric model, without mulligans. Sources are lands, plus mana creatures and rocks that cost less than the card. A dual land counts for either color but pays only one symbol, and fetch lands count as every color.

### Statusline

Show `60 cards  {W} 12  {R} 23.5` in deck windows, with no count line needed:

```lua
-- lualine.nvim
require('lualine').setup({ sections = { lualine_x = { 'scryvim', 'filetype' } } })

-- or any statusline / winbar
vim.o.statusline = "%f %m%=%{%v:lua.require'scryvim'.statusline()%} %l:%c"
```

Options such as `{ 'scryvim', lands = true }` are in `:h scryvim-statusline`.

## Configuration

Everything works without configuration. To change something, set `vim.g.scryvim` before the plugin loads, or call `require('scryvim').setup(opts)`. With lazy.nvim, `opts = { ... }` does the latter. The defaults:

```lua
{
  extensions    = { 'dec', 'deck' },  -- file extensions that get the deck filetype
  auto_download = true,               -- download card data on first use
  max_age_days  = 7,                  -- refresh card data in the background after this
  inlay_hints   = true,               -- mana costs after card lines
  colors        = true,               -- color mana symbols, from your colorscheme
  type_colors   = false,              -- color card names by card type
  icons         = false,              -- Nerd Font mana icons; true, or a table of overrides
  diagnostics   = true,               -- flag unknown card names
  counts        = true,               -- live totals on count lines
  picker        = 'buffer',           -- 'auto' | 'snacks' | 'telescope' | 'fzf_lua' | 'select'
  search        = { max_pages = 3 },  -- 175 cards per page
  hover         = { max_width = 60 }, -- 0 for no limit
  pane          = { width = 50, auto_open = true, min_columns = 100, tags = true },
  cache_dir     = vim.fn.stdpath('cache') .. '/scryvim',
}
```

For example, with lazy.nvim:

```lua
{ 'leonardwohl/scryvim', opts = { icons = true, type_colors = true } }
```

`:h scryvim` has the full reference, including the highlight groups (`:h scryvim-colors`) and icon overrides (`:h scryvim-icons`).

## Development

Tests use [busted](https://lunarmodules.github.io/busted/) run by Neovim via [nlua](https://github.com/mfussenegger/nlua):

```sh
luarocks install busted
luarocks install nlua
make test    # busted
make lint    # stylua --check
```

Two opt-in suites run in CI:

- `SCRYVIM_TEST_PLUGINS=<dir>` drives the real snacks.nvim, telescope.nvim and fzf-lua pickers and the lualine.nvim component. `<dir>` holds checkouts of those four plus plenary.nvim, and `fzf` must be on `$PATH`.
- `SCRYVIM_LIVE=1 busted spec/live_spec.lua` talks to the real Scryfall API and downloads the full Oracle Cards file once.

## License

[MIT](LICENSE)

scryvim is unofficial Fan Content. It is not produced by or endorsed by Scryfall or Wizards of the Coast. Card data is provided by Scryfall's API and bulk data.
