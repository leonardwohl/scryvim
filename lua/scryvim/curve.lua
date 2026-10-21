--- Pure: the chance of casting a card on curve, on the turn equal to its
--- mana value.
---
--- After Frank Karsten's hypergeometric model: on the play you see 7 cards
--- plus one per turn after the first, on the draw one more. No mulligans.
--- Each mana source pays one mana of any color it produces. Casting needs
--- as many sources as the mana value, and a way to pay every colored
--- symbol with a different source: a dual land counts for either color
--- but pays only one symbol. The draw is enumerated exactly over groups of
--- sources that produce the same colors.
---
--- Sources are lands, and nonland permanents that produce mana (mana
--- creatures and rocks) with a lower mana value than the card. A land
--- that searches for lands (a fetch land) produces every color.
---
--- A hybrid symbol (`{W/U}`) can be paid by either color. Phyrexian
--- (`{W/P}`) can be paid with life, and `{2/W}` with two generic mana, so
--- neither needs a colored source. `{C}` needs a colorless source and
--- `{S}` a snow source. X counts as 0.
local M = {}

M.HAND = 7

local BIT = { W = 1, U = 2, B = 4, R = 8, G = 16, C = 32, S = 64 }
local WUBRG = 31

--- Symbol types in display order.
M.TYPES = { 'W', 'U', 'B', 'R', 'G', 'C', 'S' }

local function has_type(type_line, word)
  return type_line ~= nil and type_line:find('%f[%a]' .. word .. '%f[%A]') ~= nil
end

--- Whether any face of `card` is a land.
---@param card table
---@return boolean
function M.is_land(card)
  if has_type(card.type_line, 'Land') then
    return true
  end
  for _, face in ipairs(card.card_faces or {}) do
    if has_type(face.type_line, 'Land') then
      return true
    end
  end
  return false
end

local function searches_for_land(card)
  local texts = { card.oracle_text }
  for _, face in ipairs(card.card_faces or {}) do
    texts[#texts + 1] = face.oracle_text
  end
  for _, text in ipairs(texts) do
    if text:lower():find('search your library for [^.]*land card') then
      return true
    end
  end
  return false
end

--- Bit mask of the symbol types `card` can pay as a mana source: 0 for a
--- land that produces none, nil for a nonland that is not a permanent
--- producing mana.
---@param card table
---@return integer|nil
function M.produces(card)
  local land = M.is_land(card)
  local mask = 0
  for _, c in ipairs(card.produced_mana or {}) do
    mask = bit.bor(mask, BIT[c] or 0)
  end
  if land and mask == 0 and searches_for_land(card) then
    mask = WUBRG
  end
  if not land then
    -- Instants and sorceries (rituals) are spent, not kept as sources.
    local type_line = card.type_line or ''
    if mask == 0 or has_type(type_line, 'Instant') or has_type(type_line, 'Sorcery') then
      return nil
    end
  end
  if mask ~= 0 and has_type(card.type_line, 'Snow') then
    mask = bit.bor(mask, BIT.S)
  end
  return mask
end

--- What casting `cost` needs: its mana value and, per colored symbol, a
--- mask of the types that can pay it.
---@param cost string
---@return { mv: integer, pips: integer[] }
function M.requirements(cost)
  local mv, pips = 0, {}
  for sym in cost:gmatch('{([^}]+)}') do
    sym = sym:upper()
    local parts = vim.split(sym, '/', { plain = true })
    local n = tonumber(sym)
    if n then
      mv = mv + n
    elseif sym == 'X' or sym == 'Y' or sym == 'Z' or sym:match('^H') then
      -- Counts as 0; half mana only exists on joke cards.
    elseif parts[#parts] == 'P' then
      mv = mv + 1
    elseif tonumber(parts[1]) then
      mv = mv + tonumber(parts[1])
    else
      local mask = 0
      for _, part in ipairs(parts) do
        mask = bit.bor(mask, BIT[part] or 0)
      end
      mv = mv + 1
      if mask ~= 0 then
        pips[#pips + 1] = mask
      end
    end
  end
  return { mv = mv, pips = pips }
end

--- Deck size, lands by what they produce, and nonland mana sources.
---@param entries { name: string, count: integer }[]
---@param lookup fun(name: string): table|nil
---@return { size: integer, lands: table<integer, integer>, others: { mask: integer, mv: number, count: integer }[] }
function M.deck(entries, lookup)
  local out = { size = 0, lands = {}, others = {} }
  for _, e in ipairs(entries) do
    out.size = out.size + e.count
    local card = lookup(e.name)
    local mask = card and M.produces(card)
    if mask and M.is_land(card) then
      out.lands[mask] = (out.lands[mask] or 0) + e.count
    elseif mask then
      out.others[#out.others + 1] = { mask = mask, mv = card.cmc or 0, count = e.count }
    end
  end
  return out
end

--- The sources in `deck` for a card of mana value `mv`: lands, plus
--- nonland sources that cost less.
---@param deck table
---@param mv number
---@return { size: integer, lands: integer, others: integer, by_mask: table<integer, integer> }
function M.pool(deck, mv)
  local out = { size = deck.size, lands = 0, others = 0, by_mask = {} }
  for mask, k in pairs(deck.lands) do
    out.lands = out.lands + k
    out.by_mask[mask] = (out.by_mask[mask] or 0) + k
  end
  for _, o in ipairs(deck.others) do
    if o.mv < mv then
      out.others = out.others + o.count
      out.by_mask[o.mask] = (out.by_mask[o.mask] or 0) + o.count
    end
  end
  return out
end

--- Sources in `pool` that can pay a symbol of a type in `mask`.
---@param pool table
---@param mask integer
---@return integer
function M.sources(pool, mask)
  local n = 0
  for m, k in pairs(pool.by_mask) do
    if bit.band(m, mask) ~= 0 then
      n = n + k
    end
  end
  return n
end

local binom_cache = {}

local function binom(n, k)
  if k < 0 or k > n then
    return 0
  end
  local key = n * 1000 + k
  local v = binom_cache[key]
  if not v then
    v = 1
    for i = 1, math.min(k, n - k) do
      v = v * (n - i + 1) / i
    end
    binom_cache[key] = v
  end
  return v
end

-- The unpaid symbols are counted per kind (symbols with the same mask),
-- and a combination of counts is coded as one number. What is left to pay
-- is a set of alternative combinations, and the symbols can be paid once
-- one alternative is all zeros. An alternative that needs at least as
-- much as another of every kind is dropped.
local function popcount(x)
  local n = 0
  while x ~= 0 do
    x = bit.band(x, x - 1)
    n = n + 1
  end
  return n
end

local function payer(pips)
  local kinds, index = {}, {}
  for _, pip in ipairs(pips) do
    if not index[pip] then
      kinds[#kinds + 1] = { mask = pip, n = 0 }
      index[pip] = #kinds
    end
    local kind = kinds[index[pip]]
    kind.n = kind.n + 1
  end
  local radix, full = 1, 0
  for _, kind in ipairs(kinds) do
    kind.radix = radix
    full = full + kind.n * radix
    radix = radix * (kind.n + 1)
  end
  local function digit(code, i)
    return math.floor(code / kinds[i].radix) % (kinds[i].n + 1)
  end
  local function covers(a, b) -- a needs at least as much as b everywhere
    for i = 1, #kinds do
      if digit(a, i) < digit(b, i) then
        return false
      end
    end
    return true
  end
  local function minimal(codes)
    table.sort(codes)
    local out, seen = {}, {}
    for _, c in ipairs(codes) do
      local keep = not seen[c]
      seen[c] = true
      for _, o in ipairs(out) do
        if not keep then
          break
        end
        keep = not covers(c, o)
      end
      if keep then
        out[#out + 1] = c
      end
    end
    return out
  end
  -- Every way `k` sources producing `mask` can pay down `code`, from
  -- kind `i` up. Paying fewer than possible is never better.
  local function pay(code, k, mask, i, out)
    if k == 0 or i > #kinds then
      out[#out + 1] = code
      return
    end
    local kind = kinds[i]
    if bit.band(kind.mask, mask) == 0 then
      return pay(code, k, mask, i + 1, out)
    end
    local most = math.min(k, digit(code, i))
    local least = most
    -- Leave some of this kind only when later kinds can take the rest.
    local later = 0
    for j = i + 1, #kinds do
      if bit.band(kinds[j].mask, mask) ~= 0 then
        later = later + digit(code, j)
      end
    end
    least = math.max(0, math.min(most, k - later))
    for t = least, most do
      pay(code - t * kind.radix, k - t, mask, i + 1, out)
    end
  end
  local memo = {}
  local self = { full = full }
  --- The alternatives after drawing `k` sources producing `mask`.
  function self.after(alts, key, k, mask)
    if k == 0 or mask == 0 then
      return alts, key
    end
    local mkey = key .. '|' .. k .. '|' .. mask
    local hit = memo[mkey]
    if not hit then
      local out = {}
      for _, code in ipairs(alts) do
        pay(code, k, mask, 1, out)
      end
      out = minimal(out)
      hit = { out, table.concat(out, ',') }
      memo[mkey] = hit
    end
    return hit[1], hit[2]
  end
  return self
end

--- Chance that `cards` cards from `pool` hold enough sources for `req`
--- and can pay its colored symbols, and the chance they hold enough
--- sources.
---@param pool table
---@param req { mv: integer, pips: integer[] }
---@param cards integer
---@return number castable, number enough
function M.chance(pool, req, cards)
  cards = math.min(cards, pool.size)
  local total = binom(pool.size, cards)
  if total == 0 then
    return 0, 0
  end
  local relevant = 0
  for _, pip in ipairs(req.pips) do
    relevant = bit.bor(relevant, pip)
  end
  -- Sources that pay none of the symbols differ only in count.
  local groups, count = {}, 0
  for m, k in pairs(pool.by_mask) do
    local r = bit.band(m, relevant)
    groups[r] = (groups[r] or 0) + k
    count = count + k
  end
  local list = {}
  for r, k in pairs(groups) do
    list[#list + 1] = { mask = r, count = k }
  end
  -- Most colors first, which keeps fewer alternatives open.
  table.sort(list, function(a, b)
    local pa, pb = popcount(a.mask), popcount(b.mask)
    if pa ~= pb then
      return pa > pb
    end
    return a.mask < b.mask
  end)

  -- Forward over groups. A state is the unpaid alternatives, holding the
  -- weight of each count of sources drawn so far; the count also says
  -- whether there are enough sources.
  local payment = payer(req.pips)
  local full = { payment.full }
  local states = { [tostring(payment.full)] = { alts = full, weight = { [0] = 1 } } }
  for _, g in ipairs(list) do
    local nxt = {}
    for key, s in pairs(states) do
      for k = 0, math.min(g.count, cards) do
        local alts, nkey = payment.after(s.alts, key, math.min(k, #req.pips), g.mask)
        local t = nxt[nkey]
        if not t then
          t = { alts = alts, weight = {} }
          nxt[nkey] = t
        end
        local ways = binom(g.count, k)
        for used, w in pairs(s.weight) do
          if used + k <= cards then
            t.weight[used + k] = (t.weight[used + k] or 0) + w * ways
          end
        end
      end
    end
    states = nxt
  end

  local rest = pool.size - count
  local castable = 0
  local paid = states['0']
  for used, w in pairs(paid and paid.weight or {}) do
    if used >= req.mv then
      castable = castable + w * binom(rest, cards - used)
    end
  end

  local enough = 0
  for k = req.mv, math.min(count, cards) do
    enough = enough + binom(count, k) * binom(rest, cards - k)
  end
  return castable / total, enough / total
end

--- Cards seen by turn `turn`.
---@param turn integer
---@param draw boolean on the draw rather than the play
---@return integer
function M.cards_seen(turn, draw)
  return M.HAND + turn - 1 + (draw and 1 or 0)
end

--- The on-curve odds of casting `cost` from `deck`, or nil for a cost with
--- mana value 0. On the play, `enough` is the chance of drawing as many
--- sources as the mana value, and `colors` the chance of having the
--- colors given that many.
---@param deck table
---@param cost string
---@return { turn: integer, play: number, draw: number, enough: number, colors: number|nil, pips: integer[], pool: table }|nil
function M.odds(deck, cost)
  local req = M.requirements(cost)
  if req.mv == 0 then
    return nil
  end
  local pool = M.pool(deck, req.mv)
  local play, enough = M.chance(pool, req, M.cards_seen(req.mv, false))
  local draw = M.chance(pool, req, M.cards_seen(req.mv, true))
  local colors
  if #req.pips > 0 then
    colors = enough > 0 and play / enough or 0
  end
  return { turn = req.mv, play = play, draw = draw, enough = enough, colors = colors, pips = req.pips, pool = pool }
end

--- Symbol types in `mask`, in display order: `{W}{U}`.
---@param mask integer
---@return string
function M.symbols(mask)
  local out = {}
  for _, t in ipairs(M.TYPES) do
    if bit.band(mask, BIT[t]) ~= 0 then
      out[#out + 1] = '{' .. t .. '}'
    end
  end
  return table.concat(out)
end

return M
