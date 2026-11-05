-- GFoA Guild Sync: pure helpers for the private "My stats" collector (Stats.lua) and the opt-in shared totals.
-- No game API in here: also loaded by tests/test_logic.lua with a stock Lua 5.1. Patterns are built from the
-- client's own global strings (passed in), never hardcoded English.
local _, ns = ...
ns = ns or {}
local L = ns.logic or {}
ns.logic = L

local floor = math.floor

-- ---------------------------------------------------------------------------
-- Format strings -> patterns
-- ---------------------------------------------------------------------------

-- Turns a client format string ("%s dies, you gain %d experience.", "%2$d ... %1$s") into an anchored Lua pattern
-- plus, for each capture, the format argument it belongs to and whether it is a number. Returns nil for junk.
function L.formatPattern(fmt)
  if type(fmt) ~= "string" or fmt == "" then return nil end
  local args, n = {}, 0
  local out = {}
  local i, len = 1, #fmt
  while i <= len do
    local c = string.sub(fmt, i, i)
    if c == "%" then
      local pos, kind, nextI = string.match(fmt, "^%%(%d*)%$?([sd])()", i)
      if kind then
        n = n + 1
        local idx = tonumber(pos) or n
        table.insert(args, { arg = idx, num = kind == "d" })
        table.insert(out, kind == "d" and "(%d+)" or "(.+)")
        i = nextI
      elseif string.sub(fmt, i + 1, i + 1) == "%" then
        table.insert(out, "%%")
        i = i + 2
      else
        table.insert(out, "%%")
        i = i + 1
      end
    elseif string.find(c, "[%(%)%.%+%-%*%?%[%]%^%$]") then
      table.insert(out, "%" .. c)
      i = i + 1
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  if n == 0 then return nil end
  return { pat = "^" .. table.concat(out) .. "$", args = args, len = #fmt }
end

-- Matches msg against one built pattern. Returns a table arg index -> value (numbers converted), or nil.
function L.matchFormat(p, msg)
  if not p or type(msg) ~= "string" then return nil end
  local caps = { string.match(msg, p.pat) }
  if caps[1] == nil then return nil end
  local out = {}
  for i, a in ipairs(p.args) do
    local v = caps[i]
    if a.num then v = tonumber(v) end
    out[a.arg] = v
  end
  return out
end

-- First string and first number argument (by argument index) of a match.
local function firstOf(vals)
  local s, d
  local keys = {}
  for k in pairs(vals) do table.insert(keys, k) end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = vals[k]
    if type(v) == "number" then d = d or v elseif type(v) == "string" then s = s or v end
  end
  return s, d
end

-- Builds { kill = {...}, unnamed = {...} } patterns from a lookup of global strings (get(name) -> string or nil).
-- Kill messages name the mob ("X dies, you gain N experience"); unnamed ones are quests and other XP.
function L.xpPatterns(get)
  local kill, unnamed = {}, {}
  local bases = { "FIRSTPERSON", "EXHAUSTION1", "EXHAUSTION2", "EXHAUSTION4", "EXHAUSTION5" }
  local tails = { "", "_GROUP", "_RAID" }
  for _, b in ipairs(bases) do
    for _, t in ipairs(tails) do
      local p = L.formatPattern(get("COMBATLOG_XPGAIN_" .. b .. t))
      if p then table.insert(kill, p) end
      p = L.formatPattern(get("COMBATLOG_XPGAIN_" .. b .. "_UNNAMED" .. t))
      if p then table.insert(unnamed, p) end
    end
  end
  for _, extra in ipairs({ "COMBATLOG_XPGAIN_QUEST", "COMBATLOG_XPGAIN" }) do
    local p = L.formatPattern(get(extra))
    if p then table.insert(unnamed, p) end
  end
  local longestFirst = function(a, b) return a.len > b.len end
  table.sort(kill, longestFirst)
  table.sort(unnamed, longestFirst)
  return { kill = kill, unnamed = unnamed, explore = L.formatPattern(get("ERR_ZONE_EXPLORED_XP")) }
end

-- CHAT_MSG_COMBAT_XP_GAIN text -> "kill", xp, mob | "unnamed", xp | nil.
function L.classifyXp(patterns, msg)
  if type(patterns) ~= "table" or type(msg) ~= "string" then return nil end
  for _, p in ipairs(patterns.kill or {}) do
    local v = L.matchFormat(p, msg)
    if v then
      local mob, xp = firstOf(v)
      if xp then return "kill", xp, mob end
    end
  end
  for _, p in ipairs(patterns.unnamed or {}) do
    local v = L.matchFormat(p, msg)
    if v then
      local _, xp = firstOf(v)
      if xp then return "unnamed", xp end
    end
  end
  return nil
end

-- ERR_ZONE_EXPLORED_XP system message -> xp, zone | nil.
function L.exploreXp(patterns, msg)
  local v = L.matchFormat(patterns and patterns.explore, msg)
  if not v then return nil end
  local zone, xp = firstOf(v)
  return xp, zone
end

-- Own-loot patterns (LOOT_ITEM_SELF_MULTIPLE first). Returns list of { pattern, multiple }.
function L.selfLootPatterns(get)
  local out = {}
  for _, e in ipairs({ { "LOOT_ITEM_SELF_MULTIPLE", true }, { "LOOT_ITEM_SELF", false } }) do
    local p = L.formatPattern(get(e[1]))
    if p then
      p.multiple = e[2]
      table.insert(out, p)
    end
  end
  return out
end

-- CHAT_MSG_LOOT text -> item link, count (only the player's own loot) | nil.
function L.parseSelfLoot(patterns, msg)
  for _, p in ipairs(patterns or {}) do
    local v = L.matchFormat(p, msg)
    if v then
      local link, count = firstOf(v)
      if link then return link, (p.multiple and count) or 1 end
    end
  end
  return nil
end

-- SKILL_RANK_UP ("Your skill in %s has increased to %d.") -> profession, new rank | nil.
function L.parseSkillUp(pattern, msg)
  local v = L.matchFormat(pattern, msg)
  if not v then return nil end
  return firstOf(v)
end

local QUALITY_BY_COLOR = {
  ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2, ["0070dd"] = 3,
  ["a335ee"] = 4, ["ff8000"] = 5, ["e6cc80"] = 6,
}

-- Item quality from a link's colour code (fallback when GetItemInfo has no data yet).
function L.qualityFromLink(link)
  if type(link) ~= "string" then return nil end
  local color = string.match(link, "|c%x%x(%x%x%x%x%x%x)")
  return color and QUALITY_BY_COLOR[string.lower(color)] or nil
end

function L.itemName(link)
  if type(link) ~= "string" then return nil end
  return string.match(link, "|h%[(.-)%]|h") or link
end

-- ---------------------------------------------------------------------------
-- XP by source (quest / kill / exploration / other)
-- ---------------------------------------------------------------------------

L.XP_MATCH_WINDOW = 3   -- seconds: a quest or exploration XP event and its "You gain N experience" line

local function recentList(state, now)
  local keep = {}
  for _, r in ipairs(state.recent or {}) do
    if not r.used and now - r.t <= L.XP_MATCH_WINDOW then table.insert(keep, r) end
  end
  state.recent = keep
  return keep
end

-- Finds an unused recent record of one of the kinds, preferring an equal amount.
local function takeRecent(list, kinds, amount)
  local best
  for _, r in ipairs(list) do
    if kinds[r.kind] then
      if r.amount == amount then best = r break end
      best = best or r
    end
  end
  if best then best.used = true end
  return best
end

-- Adds one XP event to stats.xp. kind: "kill" (named mob, also counts a kill), "unnamed" (the generic
-- "You gain N experience" line), "quest" (QUEST_TURNED_IN reward) or "explore" (zone discovered).
-- Quest and exploration XP also print an unnamed line, in either order: the pair counts once, under its source.
function L.addXp(stats, state, kind, amount, now)
  amount = tonumber(amount)
  if not amount or amount <= 0 then return end
  amount = floor(amount)
  stats.xp = stats.xp or {}
  local xp = stats.xp
  if kind == "kill" then
    xp.kill = (xp.kill or 0) + amount
    stats.kills = (stats.kills or 0) + 1
    return
  end
  local list = recentList(state, now or 0)
  if kind == "unnamed" then
    if takeRecent(list, { quest = true, explore = true }, amount) then return end
    xp.other = (xp.other or 0) + amount
    table.insert(state.recent, { kind = "unnamed", amount = amount, t = now or 0 })
  elseif kind == "quest" or kind == "explore" then
    xp[kind] = (xp[kind] or 0) + amount
    local u = takeRecent(list, { unnamed = true }, amount)
    if u then
      xp.other = math.max(0, (xp.other or 0) - u.amount)
    else
      table.insert(state.recent, { kind = kind, amount = amount, t = now or 0 })
    end
  end
end

-- Keeps the best XP/hour of any session at least minSecs long.
function L.bestRate(stats, perHour, secs, now, minSecs)
  if type(perHour) ~= "number" or type(secs) ~= "number" or secs < (minSecs or 1800) then return false end
  perHour = floor(perHour)
  local b = stats.bestXph
  if type(b) ~= "table" or perHour > (b.rate or 0) then
    stats.bestXph = { rate = perHour, secs = floor(secs), t = now }
    return true
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Gold by source
-- ---------------------------------------------------------------------------

L.MONEY_WINDOW = 3   -- seconds a closed window / recent event still explains a money change

L.INCOME_SOURCES = { "loot", "quest", "vendor", "ah", "other" }
L.SPEND_SOURCES = { "repair", "trainer", "flight", "vendor", "ah", "other" }
L.MONEY_LABELS = {
  loot = "Looted", quest = "Quests", vendor = "Vendor", ah = "AH / mail", other = "Other",
  repair = "Repairs", trainer = "Trainers", flight = "Flights",
}

-- ctx: { open = { merchant = true, ... }, closed = { merchant = t, ... }, at = { quest = t, loot = t, repair = t },
-- repairMode = bool }. Windows: merchant, trainer, taxi, mail, ah, loot.
local function active(ctx, kind, now)
  if ctx.open and ctx.open[kind] then return true end
  local t = ctx.closed and ctx.closed[kind]
  return type(t) == "number" and now - t <= L.MONEY_WINDOW
end

local function recent(ctx, kind, now)
  local t = ctx.at and ctx.at[kind]
  return type(t) == "number" and now - t <= L.MONEY_WINDOW
end

-- Which source explains a money change of `delta` copper right now.
function L.moneySource(ctx, delta, now)
  ctx = ctx or {}
  if type(delta) ~= "number" or delta == 0 then return nil end
  if delta > 0 then
    if recent(ctx, "quest", now) then return "quest" end
    if recent(ctx, "loot", now) or active(ctx, "loot", now) then return "loot" end
    if active(ctx, "merchant", now) then return "vendor" end
    if active(ctx, "mail", now) or active(ctx, "ah", now) then return "ah" end
    return "other"
  end
  if active(ctx, "taxi", now) then return "flight" end
  if active(ctx, "trainer", now) then return "trainer" end
  if active(ctx, "merchant", now) then
    if ctx.repairMode or recent(ctx, "repair", now) then return "repair" end
    return "vendor"
  end
  if active(ctx, "mail", now) or active(ctx, "ah", now) then return "ah" end
  return "other"
end

-- Adds a money change to the totals and the per-source breakdown. Returns the source.
function L.addMoneyBySource(stats, old, new, ctx, now)
  if type(old) ~= "number" or type(new) ~= "number" or old == new then return nil end
  local delta = new - old
  local src = L.moneySource(ctx, delta, now)
  if delta > 0 then
    stats.goldEarned = (stats.goldEarned or 0) + delta
    stats.income = stats.income or {}
    stats.income[src] = (stats.income[src] or 0) + delta
  else
    stats.goldSpent = (stats.goldSpent or 0) - delta
    stats.spend = stats.spend or {}
    stats.spend[src] = (stats.spend[src] or 0) - delta
    if src == "flight" then stats.flights = (stats.flights or 0) + 1 end
  end
  return src
end

-- ---------------------------------------------------------------------------
-- Loot, professions, deaths, sessions
-- ---------------------------------------------------------------------------

function L.addLoot(stats, quality, count, item, itemId, now, level)
  quality = tonumber(quality)
  if not quality or quality < 0 or quality > 7 then return end
  count = math.max(1, floor(tonumber(count) or 1))
  stats.loot = stats.loot or {}
  stats.loot[quality] = (stats.loot[quality] or 0) + count
  if quality >= 4 and type(stats.firstEpic) ~= "table" then
    stats.firstEpic = { item = item, id = itemId, t = now, level = level }
    return true
  end
end

function L.addSkillUp(stats, prof)
  if type(prof) ~= "string" or prof == "" then return end
  stats.skillUps = stats.skillUps or {}
  stats.skillUps[prof] = (stats.skillUps[prof] or 0) + 1
end

function L.addDeath(stats, zone, level)
  stats.deaths = (stats.deaths or 0) + 1
  if type(zone) == "string" and zone ~= "" then
    stats.deathsByZone = stats.deathsByZone or {}
    stats.deathsByZone[zone] = (stats.deathsByZone[zone] or 0) + 1
  end
  level = tonumber(level)
  if level and level >= 1 then
    stats.deathsByLevel = stats.deathsByLevel or {}
    stats.deathsByLevel[level] = (stats.deathsByLevel[level] or 0) + 1
  end
end

L.SESSION_GAP = 300   -- a /reload or reconnect within this many seconds continues the session

-- Called at PLAYER_ENTERING_WORLD. initial/reload are the event's arguments (nil on clients without them).
-- Returns true when a new session started.
function L.sessionEnter(stats, now, initial, reload)
  local s = stats.session
  -- A real login is always a new session; a /reload (or an old client without the arguments) continues the
  -- previous one unless it ended more than SESSION_GAP ago.
  local fresh = (initial == true and reload ~= true)
    or type(s) ~= "table" or now - (s.last or 0) > L.SESSION_GAP
  if fresh then
    stats.sessions = (stats.sessions or 0) + 1
    stats.session = { start = now, last = now }
  end
  return fresh and true or false
end

-- Called every minute and at logout: extends the session and keeps the longest one.
function L.sessionTick(stats, now)
  local s = stats.session
  if type(s) ~= "table" or type(s.start) ~= "number" then return end
  if now - (s.last or now) > L.SESSION_GAP then return end   -- timers stalled (sleep / long load); not played
  s.last = now
  local len = now - s.start
  if len > (stats.longestSession or 0) then stats.longestSession = len end
end

-- Map entries sorted by count (desc) as { key, n } pairs, at most `limit`.
function L.topCounts(map, limit)
  local out = {}
  for k, n in pairs(map or {}) do
    if type(n) == "number" and n > 0 then table.insert(out, { key = k, n = n }) end
  end
  table.sort(out, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return tostring(a.key) < tostring(b.key)
  end)
  while limit and #out > limit do table.remove(out) end
  return out
end

local function sum(map)
  local n = 0
  for _, v in pairs(map or {}) do if type(v) == "number" then n = n + v end end
  return n
end
L.sumCounts = sum

-- ---------------------------------------------------------------------------
-- Opt-in shared totals (docs/sync-format.md "Shared stats")
-- ---------------------------------------------------------------------------

L.SHARED_STATS_VERSION = 1

-- The small totals block copied into the character sheet when sharing is on. No gold unless withGold.
function L.sharedStats(stats, now, withGold)
  if type(stats) ~= "table" then return nil end
  local xp = stats.xp or {}
  local loot = stats.loot or {}
  local out = {
    v = L.SHARED_STATS_VERSION, t = now, since = stats.since,
    quests = stats.quests or 0, kills = stats.kills or 0, deaths = stats.deaths or 0,
    dungeons = stats.dungeons or 0, bosses = stats.bosses or 0, flights = stats.flights or 0,
    hearths = stats.hearths or 0, sessions = stats.sessions or 0, longestSession = stats.longestSession or 0,
    fish = stats.fish or 0, skillUps = sum(stats.skillUps), explore = xp.explore or 0,
    epics = (loot[4] or 0) + (loot[5] or 0) + (loot[6] or 0) + (loot[7] or 0), rares = loot[3] or 0,
  }
  if type(stats.bestXph) == "table" and type(stats.bestXph.rate) == "number" then out.bestXph = stats.bestXph.rate end
  if type(stats.firstEpic) == "table" then
    out.firstEpic = type(stats.firstEpic.item) == "string" and L.utf8Cut and L.utf8Cut(stats.firstEpic.item, 60)
      or stats.firstEpic.item
    out.firstEpicAt = stats.firstEpic.t
  end
  if withGold then out.gold = stats.goldEarned or 0 end
  return out
end

-- What the sheet carries when sharing is off: tells the bot to drop this character's shared stats.
function L.sharedStatsOff(now)
  return { v = L.SHARED_STATS_VERSION, t = now, off = true }
end

return L
