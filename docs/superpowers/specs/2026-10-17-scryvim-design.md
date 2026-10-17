# scryvim — Design

Neovim plugin for building Magic: The Gathering decks in plain-text decklists, backed by Scryfall data.

## Goals

1. Autocomplete card names.
2. Fuzzy picker over a Scryfall query; insert chosen cards into the buffer.
3. Mana cost shown inline; full card text on hover.
4. Sort selected cards by mana value.

Fast (local data, no per-keystroke network), publishable (no hard plugin dependencies), works with any completion engine and picker.

## Non-goals

- Printing-specific data (set, art, prices). Oracle data only.
- Reimplementing Scryfall query syntax locally.
- Typo quick-fixes, semantic tokens, go-to-definition, workspace features (possible later additions to the same LSP server).
- Default keymaps.

## Prior art (reviewed, not depended on)

- No Lua Scryfall wrapper exists (checked GitHub, LuaRocks). The required API surface is ~3 endpoints, so a thin internal wrapper is written.
- `surveil.nvim` (offline bulk search, plenary-dependent, WIP), `mtglsp` (Zig LSP: hover + completion), `vim-mtg` (Vim/Python deck builder), `mtg-code` (VS Code). Used as reference for feature scope and line formats.

## Requirements

- Neovim ≥ 0.11 (`vim.lsp.config`, `vim.lsp.enable`, function-valued `cmd` for in-process servers — see `:h lsp-server`).
- `curl` and `gzip` on `$PATH`.
- No Lua plugin dependencies. Optional pickers: snacks.nvim, telescope.nvim, fzf-lua.

## Architecture

```
plugin/scryvim.lua        -- filetype registration, :Scryvim command, vim.lsp.config/enable; requires nothing heavy
lua/scryvim/
  init.lua                -- setup(opts), public API
  config.lua              -- defaults, merge with vim.g.scryvim and setup() opts, vim.validate
  parse.lua               -- pure: line -> parsed line
  sort.lua                -- pure: lines + lookup -> sorted lines
  data.lua                -- card store: load, lookup, complete, refresh
  build.lua               -- bulk JSONL.gz -> stripped cards.json (runs as child `nvim -l`); exports strip()
  http.lua                -- curl via vim.system; headers; per-endpoint rate limiting
  lsp.lua                 -- in-process LSP server
  picker/init.lua         -- search -> adapter -> insert/increment
  picker/snacks.lua
  picker/telescope.lua
  picker/fzf_lua.lua
  picker/select.lua
  health.lua              -- :checkhealth scryvim
doc/scryvim.txt
```

Dependency rules:

- `parse` and `sort` are pure (no Neovim state); `sort` receives a lookup function.
- `data` is the only module that knows the cache format.
- `lsp` and `picker` depend on `data`, `parse`, `sort`; never on each other.
- `http` is used only by `data` and `picker`.

### Activation

- `vim.filetype.add({ extension = { dec = 'deck', deck = 'deck' } })`, extensions from config.
- `vim.lsp.config('scryvim', { cmd = <in-process server>, filetypes = { 'deck' } })` and `vim.lsp.enable('scryvim')`.
- Any buffer can opt in with `:set ft=deck`.
- Heavy modules load on first `deck` buffer.

### Command

Single command `:Scryvim {subcommand}` with completion:

- `search [query]` — open picker (prompts via `vim.ui.input` if no query).
- `sort` — accepts a range; without one, sorts the block under the cursor.
- `update` — force data refresh.
- `info` — card count, cache age, data source timestamp.

`<Plug>(scryvim-search)` and `<Plug>(scryvim-sort)` mappings are provided (normal and visual for sort).

## Decklist format (`parse.lua`)

Each line parses to one of:

| Kind | Examples |
|---|---|
| `card` | `4 Lightning Bolt`, `4x Lightning Bolt`, `Lightning Bolt`, `4 Lightning Bolt (M10) 146`, `4 Lightning Bolt [M10]` |
| `section` | `Deck`, `Sideboard`, `Commander`, `Companion`, `Maybeboard` (case-insensitive, optional trailing `:`) |
| `comment` | `// ...`, `# ...` |
| `blank` | empty / whitespace |

- `SB: 2 Duress` parses as `card` (count 2, name `Duress`); the `SB: ` text is kept in `prefix`.
- A `card` result has `count` (default 1), `name`, byte ranges for `count` and `name` (0-based, end-exclusive, for LSP ranges), and the untouched `prefix` and `suffix` strings (count text, `SB:`, `(SET) 123`, `[SET]`), so lines are rewritten without loss.
- Lookups use the name only; set suffixes are preserved but ignored.

## Data (`build.lua`, `data.lua`)

Source: Scryfall **Oracle Cards** bulk file (one object per Oracle ID, ~24 MB gzipped JSONL).

### Update flow

1. `GET https://api.scryfall.com/bulk-data/oracle-cards` → `download_uri`, `updated_at`. If `updated_at` equals stored metadata, stop.
2. `curl` downloads the `.jsonl.gz` to `cache_dir` (async, `vim.system`).
3. Child process `vim.system({ vim.v.progpath, '--clean', '-l', build.lua, in, out })` reads `gzip -dc` output line by line and writes the stripped cards.
   - Excluded layouts: `token`, `double_faced_token`, `emblem`, `art_series`, `planar`, `scheme`, `vanguard`.
   - Kept fields: `name`, `mana_cost`, `cmc`, `type_line`, `oracle_text`, `power`, `toughness`, `loyalty`, `defense`, `scryfall_uri`, and `card_faces[]` with `name`, `mana_cost`, `type_line`, `oracle_text`, `power`, `toughness`, `loyalty`, `defense`.
   - Output written to `cards.json.tmp`, then renamed to `cards.json`; metadata (`updated_at`) written to `meta.json` the same way.
4. On child exit success: reload store, refresh inlay hints and diagnostics in attached buffers.

`build.strip(card)` is exported and reused by the picker for live search results.

### Load and index

- `vim.json.decode` of `cards.json` (~40 ms measured for 35k synthetic cards).
- `byname[lower(name)] → card`. Multi-face cards are also indexed by `lower(card_faces[1].name)`.
- `names[]` — display names for completion.
- `data.get(name) → card|nil`, `data.complete(prefix, limit) → card[]`: case-insensitive; prefix matches first, then substring matches; default limit 50.
- `data.ready() → boolean`; `data.on_ready(fn)` for subscribers (LSP refresh).

### Freshness and failure

- Cache older than `max_age_days` (default 7) is used immediately and refreshed in the background.
- Missing cache + `auto_download = true`: start download, one `vim.notify` (INFO). LSP returns empty results until ready.
- Missing cache + `auto_download = false`: one `vim.notify` telling the user to run `:Scryvim update`.
- Any download/build failure: one `vim.notify` (WARN); existing cache is left intact; last error recorded for `:checkhealth`.

## HTTP (`http.lua`)

- All requests via `curl` through `vim.system`, async with callbacks.
- Headers: `User-Agent: scryvim/<version>`, `Accept: application/json`.
- Minimum interval between requests per endpoint: 500 ms for `/cards/search`, `/cards/named`, `/cards/collection`; 100 ms for everything else. Requests queue to respect it.
- HTTP 429: abort, notify, no retry.
- Scryfall error objects (`object = "error"`) are surfaced as errors, except `/cards/search` 404 (no matches), which is returned as an empty list.

## LSP server (`lsp.lua`)

In-process server returned by the `cmd` function, per `:h lsp-server`.

Capabilities: full text sync, completion, hover, inlay hints, code actions, push diagnostics.

### Completion

- Active when the cursor is within the name span of a `card` line (or a line that would parse as one).
- Prefix = text from name start to cursor → `data.complete(prefix)`.
- Item: `label = name`, `detail = "<mana_cost> · <type_line>"`, `documentation` = hover markdown, `textEdit` replacing the full name span (count and suffix untouched).
- `isIncomplete = true`, so the client re-queries as the user types.

### Inlay hints

- Mana cost at end of each `card` line in the requested range, `paddingLeft = true`.
- Multi-face cards use the top-level `mana_cost`, falling back to `card_faces[1].mana_cost`.
- No hint when the cost is empty (e.g., lands) or the card is unknown.
- Enabled for `deck` buffers on attach when `inlay_hints = true`.

### Hover

Markdown for the card on the current line:

```markdown
**Lightning Bolt**  {R}
*Instant*
---
Lightning Bolt deals 3 damage to any target.

[Scryfall](https://scryfall.com/card/...)
```

- Multi-face: one block per face, separated by `---`.
- Includes `P/T`, `Loyalty`, or `Defense` when present.
- Unknown card or non-card line: `nil` result.

### Code action

- Title "Sort by mana value", kind `refactor.rewrite`.
- Range = selection; empty range = the block under the cursor.
- Returns a `WorkspaceEdit` replacing the affected lines with `sort.lua` output (single undo step).

### Diagnostics

- Unknown card name → `WARN` over the name span, message `Unknown card: <name>`.
- Published on open, on change (debounced 200 ms), and when data becomes ready.
- Disabled when `diagnostics = false`.

## Sort (`sort.lua`)

Input: lines and a `lookup(name) → card|nil`. Output: new lines.

- `section`, `comment`, and `blank` lines are fixed dividers; each block between dividers is sorted independently.
- Order within a block: non-land known cards by ascending `cmc`, then name; then lands (type line contains `Land`, front face for multi-face) by name; then unknown cards in original order.
- Sort is stable; lines are emitted unchanged (only reordered).
- No range: the block containing the cursor.

## Picker (`picker/`)

1. `:Scryvim search [query]`; empty → `vim.ui.input`.
2. `http` pages `/cards/search?q=<query>` up to `search.max_pages` (default 3, 175 cards/page).
3. Results mapped through `build.strip`.
4. Adapter displays `name   mana_cost   type_line`; preview = hover markdown (adapters that support preview).
5. On choose (one or many):
   - If a `card` line with the same name exists in the buffer, increment its count, keeping the line's style: `Bolt` → `2 Bolt`, `4 Bolt` → `5 Bolt`, `4x Bolt` → `5x Bolt`.
   - Otherwise insert `1 <name>` below the cursor; multiple cards insert consecutive lines.

Adapter contract: `pick(items, { format_item, preview, on_choose })`.

`picker = 'auto'` resolution order: snacks → telescope → fzf-lua → `vim.ui.select` (single-select, no preview).

## Configuration

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

Sources, lowest to highest precedence: defaults, `vim.g.scryvim`, `require('scryvim').setup(opts)`. `setup()` is optional.

## Health (`:checkhealth scryvim`)

Reports: Neovim version, `curl` and `gzip` presence, cache path, card count, data `updated_at`, cache age vs `max_age_days`, last error, selected picker adapter.

## Testing

- Framework: busted executed by Neovim via `nlua`.
- Fixture: `spec/fixtures/oracle-cards.jsonl.gz` with ~20 real cards covering a DFC, a split card, a land, an X-cost card, and a token (must be filtered).
- Unit: `parse`, `sort`, `build.strip` and full build from fixture, `data` index/lookup/complete.
- Integration: start the LSP server in headless Neovim against a fixture buffer; assert completion items and textEdit, hover markdown, inlay hints, code-action edit, diagnostics.
- Picker: stub adapter; assert insert and increment behavior.
- No network access in tests; `http` is replaced by fixture paths.
- CI: GitHub Actions on Neovim stable and nightly; `stylua --check`.

## Scryfall compliance

- Required `User-Agent` and `Accept` headers on every request.
- Rate limits respected; 429 never retried.
- Bulk data preferred over per-card API calls; refresh at most weekly by default.
- No Scryfall logos or implied endorsement; card data is used to add editor functionality, not republished.
