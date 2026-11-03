# Shared logic refactor — Design

Recent features (count lines, statusline, preview pane, colored mana, icons)
each grew private copies of the same rules. The copies have started to
disagree (`sort` and `curve` decide "is this a land" differently). This
refactor gives each rule one home so features can't drift apart.

Goal: fewer bugs and less drift between features. Secondary: cheaper new
features, tidier command code, a faster statusline.

Six PRs, in this order. A comes first because B builds on it. After B,
C, D and E can go in any order (C uses B's `stats.mana`). F is last
because it builds on the slimmer tally from C and D.

## PR A — Shared card rules

| Rule | Home | Callers |
|---|---|---|
| `is_land`: any face, whole word `Land` | `curve.is_land` (exists) | `sort.lua` drops its local front-face, substring version |
| Side sections + `SB:` lines | `parse.SIDE_SECTIONS`, `parse.is_sb(parsed)` | `count.entries`, `sort.candidates` |
| Scryfall search URL | `http.SEARCH_URL` | `count`, `picker` (and tests that stub them) |
| `plural(n, word)` | `render.plural` | `tally`, `statusline`, `pane` |

Behavior change: spell // land modal double-faced cards (e.g. *Emeria's
Call*) now sort into the land group, matching the land count and on-curve
odds. Nothing else changes.

Tests: `sort_spec.lua` "uses the front face to decide whether a card is a
land" flips to expect the land group. Add a `parse.is_sb` case. The other
specs must pass unchanged.

## PR B — Deck stats

`count.stats(entries, lookup)` returns `{ cards, lands, mana }`. `cards` is
the total quantity, `lands` uses `curve.is_land` and `mana` uses
`symbols.entries`. With `lookup = nil` (card data not loaded), `lands` and
`mana` are nil.

| Caller | Change |
|---|---|
| `statusline.stats(buf)` | Keeps its changedtick cache; body calls `count.stats` |
| `tally.cards(entries)` | Calls `count.stats`; keeps only the `60 cards  24 lands  36 nonlands` formatting |
| `tally.refresh`, `pane.content`, `init.mana` | Use `stats.mana` instead of calling `symbols.entries` |

No shared per-buffer cache: only the statusline redraws often enough to
need one. `curve.deck` stays as it is (sources for the odds, a different
job).

Tests: `count_spec` cases for `stats` with a lookup and with `nil`. The
statusline, tally and pane specs pass unchanged.

## PR C — One path for colored mana text

Deck totals go through the same path as mana costs:
`colors.mana_chunks(symbols.format(totals))`. Totals get the same icons,
icon spacing and colors as costs.

- New `colors.virt_text(text, base_hl, colored)`: mana chunks as extmark
  `virt_text`, `{ text, { base_hl, ScryvimMana<Color> } }` when colored,
  else `{ text, base_hl }`. It replaces `mana.chunks` and `tally.mana_text`.
- `statusline.chunks` uses `colors.mana_chunks(symbols.format(stats.mana))`
  and drops its `pcall(require, 'scryvim.icons')` helper.
- `symbols.chunks` and `symbols.COLORS` are deleted once nothing else uses
  them. `symbols.format` builds its string directly.

Behavior: the text and highlights stay the same. Chunk boundaries may
merge (`' 3  '` is one chunk), which nothing depends on.

Tests: `colors_spec` cases for `virt_text`, colored and plain, and for a
totals string coloring `{C}` and `{S}` as colorless. Update or remove the
`symbols_spec` cases for `chunks`. The tally, statusline and mana specs pass
unchanged.

Skipped: the duplicated `%`-escape loop in `statusline.statusline` and the
lualine component (different highlight formats, about 2 lines saved).

## PR D — Count lines recognized in `parse`

`parse.parse` keeps `kind = 'comment'` for count lines and adds a `count`
field:

- `// count red sources: produces:r` →
  `{ kind = 'comment', count = 'query', query = 'produces:r', label = 'red sources' }`
- `// count mana symbols` → `{ kind = 'comment', count = 'mana' }`
- `// count cards` → `{ kind = 'comment', count = 'cards' }`

Keeping `kind = 'comment'` means existing checks (no LSP completion on
comments, comments divide sort blocks) need no edits.

Callers: `tally.refresh` and `pane.content` branch on `.count`. `init.sort`
checks `parse.parse(lines[row]).count == 'query'`. `tally.query`,
`tally.is_mana` and `tally.is_cards` are deleted (internal, not in
`doc/scryvim.txt`).

Tests: the cases in `tally_spec.lua:6-31` move to `parse_spec.lua` with the
same inputs and expectations, including `4 Count of Monte Cristo: the card`
(a card) and `// count cards: t:land` (a query labeled `cards`).

## PR E — Command plumbing and config cache

Config cache: `config.get()` keeps its last result. It reuses it while
`user_opts` is the same table and `vim.g.scryvim` is `vim.deep_equal` to the
copy it saw last time; otherwise it rebuilds and validates. Live changes to
`vim.g.scryvim` keep working. The returned table is shared, so its doc
comment says it is read-only (no caller writes to it today).

`init.lua` file-local helpers:

- `buf(b)`: `nil` or `0` → current buffer, for `sort`, `count` and `mana`.
- `range(o)`: `o.line1, o.line2` with a range, else nil, for the `sort`,
  `count` and `mana` subcommands.
- `ready()`: `data.ensure()`; warns "card data is not loaded yet" and
  returns false when the data isn't there. Used by `sort` and `mana`
  (`count` works on typed names, so it only calls `ensure()`).

Behavior: no change.

Tests: a `config` case that `get()` returns the same table on repeat calls
and a new one after `vim.g.scryvim` changes. Existing specs cover the rest.

## PR F — Buffer-attach helper

New `lua/scryvim/attach.lua` for the shared tally and mana lifecycle:

```lua
local decor = require('scryvim.attach').new(ns, {
  edit_delay = 1000,              -- tally: M.DEBOUNCE_MS; mana: 0
  render = function(buf, current) -- current(): still attached and no newer render
    ...
  end,
})
-- decor.attach(buf), decor.detach(buf), decor.is_attached(buf)
```

- One timer per buffer: card data loads and buffer reloads render after
  0 ms, edits after `edit_delay`. Mana's `vim.schedule` coalescing becomes a
  0 ms timer.
- `current()` replaces tally's hand-written generation check, so late
  Scryfall replies for an old buffer state are dropped.
- A token per attach: after a detach and re-attach, the old `on_lines`
  callback returns `true` to stop itself.
- Detach unsubscribes from `data.on_ready`, stops and closes the timer and
  clears `ns`.
- `tally.attach`, `mana.attach`, `detach` and `is_attached` keep their
  names; `plugin/scryvim.lua` doesn't change.

Out of scope: the pane (follows windows and tabs) and the LSP (per
document over RPC). They don't share this lifecycle.

Tests: new `attach_spec.lua` covering re-attach (the old callback doesn't
render twice), `current()` going false after an edit or a detach, and
buffer wipe closing the timer. The tally and mana specs pass unchanged.

## Process

- Each PR is its own branch off `main`.
- Each PR passes `make test` and `make lint` (stylua) before review.
