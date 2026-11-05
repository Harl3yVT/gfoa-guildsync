-- GFoA Guild Sync: pure helpers (no game API). Loaded first after Config.lua; also loaded by tests/test_logic.lua
-- with a stock Lua 5.1, so nothing in here may touch WoW globals.
local _, ns = ...
ns = ns or {}

local L = {}
ns.logic = L

L.MAX_LEVEL = 60

-- XP needed to go from level N to N+1 (Classic Era values; WoW: Forever may differ, the current level always uses
-- UnitXPMax so only later levels come from this table).
L.XP_TO_LEVEL = {
  400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600,                       -- 1-10
  8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,            -- 11-20
  25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,           -- 21-30
  50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700,           -- 31-40
  95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500,  -- 41-50
  153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800,         -- 51-59
}

-- ---------------------------------------------------------------------------
-- XP
-- ---------------------------------------------------------------------------

-- XP gained between two samples. oldMax is the XP needed for oldLevel (UnitXPMax at that time).
function L.xpGained(oldLevel, oldXp, oldMax, newLevel, newXp)
  if type(oldLevel) ~= "number" or type(newLevel) ~= "number" or type(oldXp) ~= "number" or type(newXp) ~= "number" then
    return 0
  end
  if newLevel == oldLevel then
    if newXp > oldXp then return newXp - oldXp end
    return 0
  end
  if newLevel < oldLevel then return 0 end
  local gained = ((oldMax or L.XP_TO_LEVEL[oldLevel] or 0) - oldXp) + newXp
  for lvl = oldLevel + 1, newLevel - 1 do
    gained = gained + (L.XP_TO_LEVEL[lvl] or 0)
  end
  if gained < 0 then return 0 end
  return gained
end

-- XP still needed to reach maxLevel (default 60) from level/xp with xpMax for the current level.
function L.xpToMax(level, xp, xpMax, maxLevel)
  maxLevel = maxLevel or L.MAX_LEVEL
  if type(level) ~= "number" or level >= maxLevel then return 0 end
  local need = (xpMax or L.XP_TO_LEVEL[level] or 0) - (xp or 0)
  if need < 0 then need = 0 end
  for lvl = level + 1, maxLevel - 1 do
    need = need + (L.XP_TO_LEVEL[lvl] or 0)
  end
  return need
end

-- Seconds until maxLevel at xpPerHour, or nil when there's no rate or already at max level.
function L.etaSeconds(level, xp, xpMax, xpPerHour, maxLevel)
  if type(xpPerHour) ~= "number" or xpPerHour <= 0 then return nil end
  if type(level) ~= "number" or level >= (maxLevel or L.MAX_LEVEL) then return nil end
  return math.floor(L.xpToMax(level, xp, xpMax, maxLevel) / xpPerHour * 3600 + 0.5)
end

-- XP/hour as a whole number, or nil when the sample is shorter than minSeconds.
function L.xpPerHour(gained, seconds, minSeconds)
  if type(gained) ~= "number" or type(seconds) ~= "number" or seconds <= 0 then return nil end
  if seconds < (minSeconds or 600) then return nil end
  return math.floor(gained * 3600 / seconds + 0.5)
end

-- 3725 -> "1h 02m", 90061 -> "1d 1h", 59 -> "59s".
function L.formatDuration(s)
  if type(s) ~= "number" then return "?" end
  if s < 0 then s = 0 end
  s = math.floor(s)
  if s < 60 then return s .. "s" end
  if s < 3600 then return math.floor(s / 60) .. "m" end
  if s < 86400 then return string.format("%dh %02dm", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
  return string.format("%dd %dh", math.floor(s / 86400), math.floor(s % 86400 / 3600))
end

-- 41000 -> "41.0k"
function L.shortNumber(n)
  if type(n) ~= "number" then return "?" end
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

-- ---------------------------------------------------------------------------
-- Dungeon runs
-- ---------------------------------------------------------------------------

function L.runKey(start, instanceId)
  return tostring(start) .. "-" .. tostring(instanceId or 0)
end

-- Index of the run to continue (same instance, same character, last seen within gap seconds), or nil.
-- instanceId 0 means the client didn't report one: then the zone name must match too.
function L.findRun(runs, instanceId, zone, character, now, gap)
  if type(runs) ~= "table" then return nil end
  instanceId = instanceId or 0
  for i = #runs, 1, -1 do
    local r = runs[i]
    if type(r) == "table" and r.instanceId == instanceId and r.character == character
        and (instanceId ~= 0 or r.zone == zone)
        and now - (r.last or r.start or 0) <= gap then
      return i
    end
  end
  return nil
end

function L.newRun(now, zone, instanceId, character, level)
  return {
    key = L.runKey(now, instanceId),
    zone = zone,
    instanceId = instanceId or 0,
    start = now,
    last = now,
    members = {},
    character = character,
    levelAtStart = level,
    bossesKilled = 0,
  }
end

-- Adds names not already in list; keeps the list sorted. Returns the list.
function L.mergeNames(list, names)
  local seen = {}
  for _, n in ipairs(list) do seen[n] = true end
  local added = false
  for _, n in ipairs(names or {}) do
    if type(n) == "string" and n ~= "" and not seen[n] then
      table.insert(list, n)
      seen[n] = true
      added = true
    end
  end
  if added then table.sort(list) end
  return list
end

-- Boss kill dedupe: returns true when this kill should be counted (no kill with the same key within window s).
function L.newKill(seen, key, now, window)
  key = key or "?"
  local t = seen[key]
  if t and now - t < (window or 30) then return false end
  seen[key] = now
  return true
end

-- Keeps entries whose `last` (or `start`, or `t`) is at or after cutoff.
function L.pruneByTime(list, cutoff)
  local out = {}
  for _, e in ipairs(list or {}) do
    if type(e) == "table" and (e.last or e.start or e.t or 0) >= cutoff then table.insert(out, e) end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Discord data (GFoAGuildSyncBotData, read only)
-- ---------------------------------------------------------------------------

function L.stripRealm(name)
  if type(name) ~= "string" then return nil end
  return string.match(name, "^([^%-]+)") or name
end

local lowerIndex = setmetatable({}, { __mode = "k" })

-- The discord entry for a character name ("Name" or "Name-Realm"), or nil.
function L.memberEntry(discord, name)
  if type(discord) ~= "table" or type(discord.characters) ~= "table" then return nil end
  local short = L.stripRealm(name)
  if not short then return nil end
  local e = discord.characters[short]
  if type(e) == "table" then return e end
  local idx = lowerIndex[discord.characters]
  if not idx then
    idx = {}
    for k, v in pairs(discord.characters) do
      if type(k) == "string" and type(v) == "table" then idx[string.lower(k)] = v end
    end
    lowerIndex[discord.characters] = idx
  end
  return idx[string.lower(short)]
end

-- The main's name when name is an alt, else nil.
function L.altOf(discord, name)
  local e = L.memberEntry(discord, name)
  if not e or type(e.main) ~= "string" or e.main == "" then return nil end
  if string.lower(e.main) == string.lower(L.stripRealm(name) or "") then return nil end
  return e.main
end

function L.isRegistered(discord, name)
  local e = L.memberEntry(discord, name)
  return e ~= nil and e.registered == true
end

-- Up to 5 crafter names for an item/recipe name, or nil.
function L.crafters(discord, itemName)
  if type(discord) ~= "table" or type(discord.crafters) ~= "table" or type(itemName) ~= "string" then return nil end
  local list = discord.crafters[string.lower(itemName)]
  if type(list) ~= "table" or #list == 0 then return nil end
  local out = {}
  for i = 1, math.min(5, #list) do
    if type(list[i]) == "string" then table.insert(out, list[i]) end
  end
  if #out == 0 then return nil end
  return out
end

-- " (Thrall's alt)" for a chat line by an alt, or nil. Never adds it twice.
function L.altSuffix(discord, author, msg)
  local main = L.altOf(discord, author)
  if not main then return nil end
  local suffix = " (" .. main .. "'s alt)"
  if type(msg) == "string" and string.sub(msg, -#suffix) == suffix then return nil end
  return suffix
end

-- ---------------------------------------------------------------------------
-- Guild window filter and sort
-- ---------------------------------------------------------------------------

-- filter = { onlineOnly, class, minLevel, maxLevel, search }. Returns a new list.
function L.filterRoster(members, filter, discord)
  local out = {}
  filter = filter or {}
  local search = filter.search and string.lower(filter.search) or ""
  for _, m in ipairs(members or {}) do
    local ok = type(m) == "table"
    if ok and filter.onlineOnly and not m.online then ok = false end
    if ok and filter.class and filter.class ~= "" and m.class ~= filter.class then ok = false end
    if ok and filter.minLevel and (m.level or 0) < filter.minLevel then ok = false end
    if ok and filter.maxLevel and (m.level or 0) > filter.maxLevel then ok = false end
    if ok and search ~= "" then
      local hay = string.lower(table.concat({
        m.name or "", m.zone or "", m.rank or "", m.note or "", L.altOf(discord, m.name) or "",
      }, "\001"))
      if not string.find(hay, search, 1, true) then ok = false end
    end
    if ok then table.insert(out, m) end
  end
  return out
end

local function seenValue(m)
  if m.online then return -1 end
  return m.lastOnlineDays or 99999
end

local SORT_VALUE = {
  name = function(m) return string.lower(m.name or "") end,
  level = function(m) return m.level or 0 end,
  class = function(m) return m.class or "" end,
  rank = function(m) return m.rankIndex or 99 end,
  zone = function(m) return string.lower(m.zone or "") end,
  seen = seenValue,
}

-- Sorts list in place by key ("name", "level", "class", "rank", "zone", "main", "seen"); ties by name.
function L.sortRoster(list, key, desc, discord)
  local value = SORT_VALUE[key]
  if key == "main" then
    value = function(m) return string.lower(L.altOf(discord, m.name) or "") end
  end
  value = value or SORT_VALUE.name
  table.sort(list, function(a, b)
    local va, vb = value(a), value(b)
    if va ~= vb then
      if desc then return va > vb end
      return va < vb
    end
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)
  return list
end

-- ---------------------------------------------------------------------------
-- 1.2.0: alts, roles, guild crafters, reagents, levelling, guildie finder, race to 60, cooldowns, stats, checklist
-- ---------------------------------------------------------------------------

-- Every alt (name) whose main is `name`, sorted. Empty list when none.
function L.altsOf(discord, name)
  local out = {}
  if type(discord) ~= "table" or type(discord.characters) ~= "table" then return out end
  local short = string.lower(L.stripRealm(name) or "")
  if short == "" then return out end
  for k, e in pairs(discord.characters) do
    if type(k) == "string" and type(e) == "table" and type(e.main) == "string"
        and string.lower(e.main) == short and string.lower(k) ~= short then
      table.insert(out, k)
    end
  end
  table.sort(out)
  return out
end

-- "Altname is Thrall's alt" or nil.
function L.altLine(discord, name)
  local main = L.altOf(discord, name)
  if not main then return nil end
  return (L.stripRealm(name) or name) .. " is " .. main .. "'s alt"
end

-- Role from the Discord data ("Tank", "Healer", "DPS") or nil.
function L.roleOf(discord, name)
  local e = L.memberEntry(discord, name)
  if e and type(e.role) == "string" and e.role ~= "" then return e.role end
  return nil
end

-- Orders a (filtered, sorted) roster so each alt follows its main. Returns the new list and a set of members shown
-- indented (alts whose main is in the list). Groups keep the position of their first member.
function L.groupAlts(list, discord)
  local groups, order = {}, {}
  for _, m in ipairs(list or {}) do
    local main = L.altOf(discord, m.name)
    local key = string.lower(main or L.stripRealm(m.name) or "")
    if not groups[key] then
      groups[key] = { main = nil, alts = {} }
      table.insert(order, key)
    end
    if main then
      table.insert(groups[key].alts, m)
    else
      groups[key].main = m
    end
  end
  local out, indent = {}, {}
  for _, key in ipairs(order) do
    local g = groups[key]
    if g.main then table.insert(out, g.main) end
    for _, a in ipairs(g.alts) do
      table.insert(out, a)
      if g.main then indent[a] = true end
    end
  end
  return out, indent
end

-- Recipe items ("Pattern: Runecloth Bag") -> the thing they teach ("Runecloth Bag"), else nil.
L.RECIPE_PREFIXES = { "Pattern: ", "Recipe: ", "Formula: ", "Plans: ", "Schematic: ", "Manual: ", "Design: " }
function L.recipeTarget(name)
  if type(name) ~= "string" then return nil end
  for _, p in ipairs(L.RECIPE_PREFIXES) do
    if string.sub(name, 1, #p) == p then return string.sub(name, #p + 1) end
  end
  return nil
end

local function addCrafter(index, recipe, who, prof, skill)
  if type(recipe) ~= "string" or type(who) ~= "string" then return end
  local key = string.lower(recipe)
  index[key] = index[key] or {}
  for _, e in ipairs(index[key]) do
    if string.lower(e.name) == string.lower(who) then return end
  end
  table.insert(index[key], { name = who, prof = prof, skill = skill })
end

local function skillOf(profs, prof)
  for _, p in ipairs(type(profs) == "table" and profs or {}) do
    if type(p) == "table" and p.name == prof then return p.skill end
    if type(p) == "table" and p[1] == prof then return p[2] end
  end
  return nil
end

-- lower recipe name -> { { name, prof, skill } } from characters on this PC (GFoAGuildSyncDB.characters).
function L.crafterIndexFromOwn(characters)
  local index = {}
  local names = {}
  for who in pairs(characters or {}) do
    if type(who) == "string" then table.insert(names, who) end
  end
  table.sort(names)
  for _, who in ipairs(names) do
    local c = characters[who]
    if type(c) == "table" and type(c.recipes) == "table" then
      for prof, list in pairs(c.recipes) do
        for _, r in ipairs(type(list) == "table" and list or {}) do
          addCrafter(index, r, who, prof, skillOf(c.professions, prof))
        end
      end
    end
  end
  return index
end

-- Same shape from decoded guild sync payload characters ({ n, prof = {{name, skill, max}}, rec = { prof = {...} } }).
function L.crafterIndexFromSync(chars, index)
  index = index or {}
  for _, c in ipairs(chars or {}) do
    if type(c) == "table" and type(c.n) == "string" and type(c.rec) == "table" then
      for prof, list in pairs(c.rec) do
        for _, r in ipairs(type(list) == "table" and list or {}) do
          addCrafter(index, r, c.n, prof, skillOf(c.prof, prof))
        end
      end
    end
  end
  return index
end

-- Everyone known to craft itemName: the given indexes first (they carry profession + skill), then the Discord
-- crafters. Returns a list of { name, prof, skill } (maybe empty).
function L.guildCrafters(itemName, discord, ...)
  local out, seen = {}, {}
  if type(itemName) ~= "string" or itemName == "" then return out end
  local key = string.lower(itemName)
  local indexes = { ... }
  for i = 1, select("#", ...) do
    local index = indexes[i]
    for _, e in ipairs(type(index) == "table" and index[key] or {}) do
      local k = string.lower(e.name)
      if not seen[k] then
        seen[k] = true
        table.insert(out, e)
      end
    end
  end
  for _, n in ipairs(L.crafters(discord, itemName) or {}) do
    local k = string.lower(n)
    if not seen[k] then
      seen[k] = true
      table.insert(out, { name = n })
    end
  end
  return out
end

-- "Testy (Tailoring 285), Other" for up to max (5) crafters, plus " +N more".
function L.formatCrafters(list, max)
  max = max or 5
  local parts = {}
  for i = 1, math.min(max, #list) do
    local e = list[i]
    local s = e.name
    if e.prof then s = s .. " (" .. e.prof .. (e.skill and (" " .. e.skill) or "") .. ")" end
    table.insert(parts, s)
  end
  local text = table.concat(parts, ", ")
  if #list > max then text = text .. " +" .. (#list - max) .. " more" end
  return text
end

-- reagents[lower reagent] = { crafted names } (from your own profession windows).
function L.addReagent(map, reagent, crafted)
  if type(reagent) ~= "string" or type(crafted) ~= "string" or reagent == "" or crafted == "" then return end
  local key = string.lower(reagent)
  local list = map[key] or {}
  for _, n in ipairs(list) do if n == crafted then return end end
  table.insert(list, crafted)
  table.sort(list)
  map[key] = list
end

function L.reagentFor(map, itemName)
  if type(map) ~= "table" or type(itemName) ~= "string" then return nil end
  local list = map[string.lower(itemName)]
  if type(list) ~= "table" or #list == 0 then return nil end
  return list
end

-- Levelling buddy: seconds to the next level at xpPerHour (nil without a rate or at max level).
function L.etaNextLevel(level, xp, xpMax, xpPerHour, maxLevel)
  if type(level) ~= "number" or level >= (maxLevel or L.MAX_LEVEL) then return nil end
  if type(xpPerHour) ~= "number" or xpPerHour <= 0 then return nil end
  local need = (xpMax or L.XP_TO_LEVEL[level] or 0) - (xp or 0)
  if need < 0 then need = 0 end
  return math.floor(need / xpPerHour * 3600 + 0.5)
end

-- Rested XP as a whole percentage of the current level.
function L.restedPercent(rested, xpMax)
  if type(rested) ~= "number" or type(xpMax) ~= "number" or xpMax <= 0 then return 0 end
  return math.floor(rested * 100 / xpMax + 0.5)
end

-- Guildie finder: online members within +-range levels of myLevel (not me), with optional class / role filter.
-- Closest level first, then name.
function L.finder(members, myLevel, range, filter, discord, me)
  local out = {}
  filter = filter or {}
  range = range or 3
  if type(myLevel) ~= "number" then return out end
  for _, m in ipairs(members or {}) do
    if type(m) == "table" and m.online and m.name ~= me and type(m.level) == "number"
        and math.abs(m.level - myLevel) <= range
        and (not filter.class or m.class == filter.class)
        and (not filter.role or string.lower(L.roleOf(discord, m.name) or "") == string.lower(filter.role)) then
      table.insert(out, m)
    end
  end
  table.sort(out, function(a, b)
    local da, db = math.abs(a.level - myLevel), math.abs(b.level - myLevel)
    if da ~= db then return da < db end
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)
  return out
end

-- Race to 60: history[name] = { { d = day, l = level }, ... } (one entry per day, last 8 days). Names not seen for
-- 30 days are dropped.
function L.recordLevels(history, members, day)
  for _, m in ipairs(members or {}) do
    if type(m) == "table" and type(m.name) == "string" and type(m.level) == "number" then
      local h = history[m.name] or {}
      local last = h[#h]
      if last and last.d == day then
        last.l = m.level
      else
        table.insert(h, { d = day, l = m.level })
      end
      while #h > 8 do table.remove(h, 1) end
      history[m.name] = h
    end
  end
  for name, h in pairs(history) do
    if type(h) ~= "table" or not h[#h] or day - (h[#h].d or 0) > 30 then history[name] = nil end
  end
end

-- Levels gained over the last 7 days (0 when unknown).
function L.weekGain(h, day, level)
  if type(h) ~= "table" or type(level) ~= "number" then return 0 end
  for _, e in ipairs(h) do
    if type(e) == "table" and (e.d or 0) >= day - 7 then
      local g = level - (e.l or level)
      return g > 0 and g or 0
    end
  end
  return 0
end

-- Members under maxLevel, highest level first (then most gained this week, then name), at most limit.
function L.raceTo60(members, history, day, limit, maxLevel)
  maxLevel = maxLevel or L.MAX_LEVEL
  local out = {}
  for _, m in ipairs(members or {}) do
    if type(m) == "table" and type(m.level) == "number" and m.level < maxLevel then
      table.insert(out, { member = m, gain = L.weekGain(history and history[m.name], day, m.level) })
    end
  end
  table.sort(out, function(a, b)
    if a.member.level ~= b.member.level then return a.member.level > b.member.level end
    if a.gain ~= b.gain then return a.gain > b.gain end
    return string.lower(a.member.name or "") < string.lower(b.member.name or "")
  end)
  while limit and #out > limit do table.remove(out) end
  return out
end

-- Profession cooldowns: is this recipe one with a cooldown? known = set of names seen with a cooldown before.
function L.isCooldownRecipe(name, known)
  if type(name) ~= "string" then return false end
  if name == "Mooncloth" or string.sub(name, 1, 11) == "Transmute: " then return true end
  return type(known) == "table" and known[name] == true
end

-- { { name, readyAt } } for one character: every cooldown recipe it knows; readyAt 0 = ready now. Sorted by name.
function L.cooldownState(c, now, known)
  local out, seen = {}, {}
  if type(c) ~= "table" then return out end
  local cds = type(c.cooldowns) == "table" and c.cooldowns or {}
  for _, list in pairs(type(c.recipes) == "table" and c.recipes or {}) do
    for _, r in ipairs(type(list) == "table" and list or {}) do
      if not seen[r] and L.isCooldownRecipe(r, known) then
        seen[r] = true
        local t = cds[r]
        table.insert(out, { name = r, readyAt = (type(t) == "number" and t > now) and t or 0 })
      end
    end
  end
  for r, t in pairs(cds) do
    if not seen[r] and type(t) == "number" then
      seen[r] = true
      table.insert(out, { name = r, readyAt = t > now and t or 0 })
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- Personal stats (per character, never sent anywhere): money in / out.
function L.addMoney(stats, old, new)
  if type(old) ~= "number" or type(new) ~= "number" or old == new then return end
  if new > old then
    stats.goldEarned = (stats.goldEarned or 0) + (new - old)
  else
    stats.goldSpent = (stats.goldSpent or 0) + (old - new)
  end
end

-- Adds played seconds to the current level; gaps longer than cap (logged off, stalled timers) are not counted.
function L.addLevelTime(stats, level, secs, cap)
  if type(level) ~= "number" or type(secs) ~= "number" or secs <= 0 then return end
  if secs > (cap or 120) then return end
  stats.levelTime = stats.levelTime or {}
  stats.levelTime[level] = (stats.levelTime[level] or 0) + secs
end

-- 1234567 copper -> "123g 45s 67c"
function L.formatMoney(c)
  if type(c) ~= "number" then return "?" end
  c = math.floor(c)
  local g, s, cc = math.floor(c / 10000), math.floor(c % 10000 / 100), c % 100
  if g > 0 then return string.format("%dg %ds %dc", g, s, cc) end
  if s > 0 then return string.format("%ds %dc", s, cc) end
  return cc .. "c"
end

-- Pre-raid checklist rows { text, done, unknown } for one character. itemCount(id) -> number or nil (unknown).
function L.checklist(c, config, itemCount, maxLevel)
  local rows = {}
  if type(c) ~= "table" then return rows end
  maxLevel = maxLevel or L.MAX_LEVEL
  table.insert(rows, { text = "Level " .. maxLevel, done = (c.level or 0) >= maxLevel })
  for _, a in ipairs(config and config.attunements or {}) do
    table.insert(rows, { text = a.name .. " attunement",
      done = type(c.attunements) == "table" and c.attunements[a.name] == true })
  end
  for _, p in ipairs(config and config.preRaid or {}) do
    local have, known = false, false
    for _, id in ipairs(p.items or {}) do
      local n = itemCount and itemCount(id)
      if type(n) == "number" then
        known = true
        if n > 0 then have = true end
      end
    end
    table.insert(rows, { text = p.name, done = have, unknown = not known })
  end
  return rows
end

-- Discord link status of one of your characters: "main", "alt" (+ main name), "unlinked", or "unknown" when there
-- is no Discord data file on this PC.
function L.linkStatus(discord, name)
  if type(discord) ~= "table" then return "unknown" end
  local e = L.memberEntry(discord, name)
  if not e or e.registered ~= true then return "unlinked" end
  local main = L.altOf(discord, name)
  if main then return "alt", main end
  return "main"
end

-- filterRoster extension: filter.role (Discord role) on top of the 1.1 filters.
local baseFilter = L.filterRoster
function L.filterRoster(members, filter, discord)
  local out = baseFilter(members, filter, discord)
  if not filter or not filter.role or filter.role == "" then return out end
  local kept = {}
  for _, m in ipairs(out) do
    if string.lower(L.roleOf(discord, m.name) or "") == string.lower(filter.role) then table.insert(kept, m) end
  end
  return kept
end

-- ---------------------------------------------------------------------------
-- "New version is out" (1.2.1): versions heard from guildmates' addons. Only a version string is ever used.
-- ---------------------------------------------------------------------------

L.UPDATE_URL = "curseforge.com/wow/addons/gfoa-guild-sync"

-- "1.2.3" -> { 1, 2, 3 }; nil for anything else (no prefixes, suffixes or parts over 4 digits).
function L.parseVersion(s)
  if type(s) ~= "string" or #s > 14 then return nil end
  local a, b, c = string.match(s, "^(%d%d?%d?%d?)%.(%d%d?%d?%d?)%.(%d%d?%d?%d?)$")
  if not a then return nil end
  return { tonumber(a), tonumber(b), tonumber(c) }
end

-- -1 / 0 / 1 like a < b, a == b, a > b; nil when either is not a valid version.
function L.compareVersions(a, b)
  local va, vb = L.parseVersion(a), L.parseVersion(b)
  if not va or not vb then return nil end
  for i = 1, 3 do
    if va[i] ~= vb[i] then return va[i] < vb[i] and -1 or 1 end
  end
  return 0
end

-- The record to keep after hearing `version` from `from`: { version, from, at } when it's newer than both ours
-- and the one already kept, else `seen` unchanged (nil when `seen` is junk).
function L.noteVersion(seen, version, from, now, mine)
  local kept = type(seen) == "table" and L.parseVersion(seen.version) and seen or nil
  if L.compareVersions(version, mine) ~= 1 then return kept end
  if kept and L.compareVersions(version, kept.version) ~= 1 then return kept end
  return { version = version, from = type(from) == "string" and string.sub(from, 1, 48) or nil, at = now }
end

-- One passive line when a newer version than ours was seen, else nil.
function L.updateNotice(seen, mine)
  if type(seen) ~= "table" or L.compareVersions(seen.version, mine) ~= 1 then return nil end
  return seen.version .. " is out: update with WowUp or CurseForge, or " .. L.UPDATE_URL
end

return L
