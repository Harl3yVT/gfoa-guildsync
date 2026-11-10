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

-- A sheet read while the game tears the unit down (logout or /reload): UnitLevel 1, UnitXPMax 0, GetMoney 0.
-- Below the level cap the XP needed for the next level is never 0, so its level, XP and money are junk.
function L.logoutGlitch(level, xpMax, maxLevel)
  if xpMax ~= 0 then return false end
  return type(level) ~= "number" or level < (maxLevel or L.MAX_LEVEL)
end

-- ---------------------------------------------------------------------------
-- Names (WoW: Forever characters have a first name and a surname)
-- ---------------------------------------------------------------------------

-- WoW: Forever clients report interface 16xxx (GetBuildInfo's 4th value); Classic Era is 115xx.
function L.isForeverInterface(v)
  v = tonumber(v)
  return v ~= nil and v >= 16000 and v < 20000
end

-- UnitName / UnitFullName return (name, second). The second value is the realm on Classic and Retail, but the
-- SURNAME on Forever. Returns first, surname, realm (nil when missing).
function L.splitUnitName(first, second, forever)
  if type(first) ~= "string" or first == "" then return nil end
  if type(second) ~= "string" or second == "" then second = nil end
  if forever then return first, second, nil end
  return first, nil, second
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

-- WoW Forever's guild roster gives "Name Surname" (and "Name Surname-Realm" off-realm); the character is
-- "Name". Returns (name, realm or nil) with the surname dropped, or nil for an empty/non-string name.
function L.splitName(full)
  if type(full) ~= "string" then return nil end
  local base, realm = string.match(full, "^([^%-]*)%-(.*)$")
  if not base then base = full end
  base = string.match(base, "^%s*(%S+)")
  if not base then return nil end
  if realm == "" then realm = nil end
  return base, realm
end

function L.stripRealm(name)
  return (L.splitName(name))
end

-- Names for a roster scan (same rule as the bot's sync.roster_names). `fulls` are roster names without realm
-- ("Bimbo Girl", "Minuscule Dog"); `discord` is the bot data. A registered match (spaces removed, then first word)
-- wins, the rest get the first word, else the joined form. Returns a list of names (false = skip).
function L.rosterNames(fulls, discord)
  local reg = {}
  if type(discord) == "table" and type(discord.characters) == "table" then
    for k in pairs(discord.characters) do
      if type(k) == "string" then reg[string.lower(k)] = k end
    end
  end
  local cands, out, taken = {}, {}, {}
  for i, full in ipairs(fulls) do
    local words = {}
    if type(full) == "string" then
      for w in string.gmatch(full, "%S+") do words[#words + 1] = w end
    end
    local c = {}
    if #words > 1 then c[#c + 1] = table.concat(words) end
    if #words > 0 then c[#c + 1] = words[1] end
    cands[i] = c
    out[i] = false
  end
  -- exact / space-removed matches first, then first-word matches
  for k = 1, 2 do
    for i, c in ipairs(cands) do
      local n = c[k]
      if not out[i] and n then
        local low = string.lower(n)
        if reg[low] and not taken[low] then out[i] = reg[low]; taken[low] = true end
      end
    end
  end
  for i, c in ipairs(cands) do
    if not out[i] then
      for j = #c, 1, -1 do
        local low = string.lower(c[j])
        if not taken[low] then
          out[i] = c[j]; taken[low] = true; break
        end
      end
    end
  end
  return out
end

local lowerIndex = setmetatable({}, { __mode = "k" })

-- discord.characters key for one candidate name (exact, then case-insensitive), or nil.
local function characterKey(chars, n)
  if type(chars[n]) == "table" then return n end
  local idx = lowerIndex[chars]
  if not idx then
    idx = {}
    for k, v in pairs(chars) do
      if type(k) == "string" and type(v) == "table" then idx[string.lower(k)] = k end
    end
    lowerIndex[chars] = idx
  end
  return idx[string.lower(n)]
end

-- The discord entry for a character name and its key there, or nil. name: "Name", "Name-Realm" or Forever's
-- "First Surname"; like the bot's roster_names, the joined form ("Minusculedog" for "Minuscule Dog") is tried
-- before the first word.
function L.memberEntry(discord, name)
  if type(discord) ~= "table" or type(discord.characters) ~= "table" then return nil end
  local short = L.stripRealm(name)
  if not short then return nil end
  local base = string.match(string.match(name, "^([^%-]*)") or "", "^%s*(.-)%s*$") or ""
  local joined = string.gsub(base, "%s+", "")
  local key = (joined ~= short and joined ~= "" and characterKey(discord.characters, joined))
    or characterKey(discord.characters, short)
  if not key then return nil end
  return discord.characters[key], key
end

-- true when `main` is a registered main in the data: it has its own entry and that entry names itself as main.
-- Guards against a link that changed or disappeared on the Discord side (an officer undid or moved a wrong roster
-- match, or a relayed copy and the file disagree): an alt never points at a character that isn't a main any more.
local function isMainKey(chars, main)
  if type(main) ~= "string" or main == "" then return false end
  local key = characterKey(chars, main)
  local m = key and chars[key]
  return type(m) == "table" and m.registered ~= false and type(m.main) == "string"
    and string.lower(m.main) == string.lower(key)
end

-- The main's name when name is an alt, else nil (also nil when that main isn't a registered main in the data).
function L.altOf(discord, name)
  local e, key = L.memberEntry(discord, name)
  if not e or type(e.main) ~= "string" or e.main == "" then return nil end
  if string.lower(e.main) == string.lower(key) then return nil end
  if not isMainKey(discord.characters, e.main) then return nil end
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

-- " (Thrall's alt)" for a chat line by an alt, or nil. Never adds it twice. disp (optional) turns the main's
-- name into the shown one ("Thrall Brightvale").
function L.altSuffix(discord, author, msg, disp)
  local main = L.altOf(discord, author)
  if not main then return nil end
  local suffix = " (" .. (disp and disp(main) or main) .. "'s alt)"
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
        m.name or "", m.zone or "", m.rank or "", m.note or "", L.altOf(discord, m.name) or "", m.fullName or "",
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
  local _, key = L.memberEntry(discord, name)
  if not key or not isMainKey(discord.characters, key) then return out end   -- not (or no longer) a main
  local short = string.lower(key)
  for k, e in pairs(discord.characters) do
    if type(k) == "string" and type(e) == "table" and type(e.main) == "string"
        and string.lower(e.main) == short and string.lower(k) ~= short then
      table.insert(out, k)
    end
  end
  table.sort(out)
  return out
end

-- "Altname is Thrall's alt" or nil. disp (optional) turns names into the shown ones ("Thrall Brightvale").
function L.altLine(discord, name, disp)
  local main = L.altOf(discord, name)
  if not main then return nil end
  local alt = L.stripRealm(name) or name
  if disp then alt, main = disp(alt), disp(main) end
  return alt .. " is " .. main .. "'s alt"
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

-- "Testy (Tailoring 285), Other" for up to max (5) crafters, plus " +N more". disp (optional) turns names into
-- the shown ones ("Testy Brightvale").
function L.formatCrafters(list, max, disp)
  max = max or 5
  local parts = {}
  for i = 1, math.min(max, #list) do
    local e = list[i]
    local s = disp and disp(e.name) or e.name
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

-- Coin letter colors (the game's gold / silver / copper text colors). Only the letter is colored, not the number.
L.COIN_COLOR = { g = "|cffffd700", s = "|cffc7c7cf", c = "|cffeda55f" }

-- n followed by its colored coin letter. resume: the color code to go back to after the letter, for amounts inside
-- colored text (a color code can't be nested: |r would end the outer color too); else "|r".
function L.coin(n, letter, resume)
  return n .. L.COIN_COLOR[letter] .. letter .. (resume or "|r")
end

-- 1234567 copper -> "123g 45s 67c" (letters in coin colors; resume as in L.coin)
function L.formatMoney(c, resume)
  if type(c) ~= "number" then return "?" end
  c = math.floor(c)
  local g, s, cc = math.floor(c / 10000), math.floor(c % 10000 / 100), c % 100
  if g > 0 then return L.coin(g, "g", resume) .. " " .. L.coin(s, "s", resume) .. " " .. L.coin(cc, "c", resume) end
  if s > 0 then return L.coin(s, "s", resume) .. " " .. L.coin(cc, "c", resume) end
  return L.coin(cc, "c", resume)
end

-- Pre-raid checklist rows { text, done, unknown } for one character. itemCount(id) -> number or nil (unknown).
function L.checklist(c, config, itemCount, maxLevel)
  local rows = {}
  if type(c) ~= "table" then return rows end
  maxLevel = maxLevel or L.MAX_LEVEL
  table.insert(rows, { text = "Level " .. maxLevel, done = (c.level or 0) >= maxLevel })
  for _, a in ipairs(config and config.attunements or {}) do
    table.insert(rows, { text = a.name .. " attunement",
      done = type(c.attunements) == "table" and c.attunements[a.name] == true,
      unknown = L.attunementPending(a) or nil })
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

-- ---------------------------------------------------------------------------
-- Forever readiness (1.5.2): instances, encounters, recipes, quest ids
-- ---------------------------------------------------------------------------

-- Instance type ("raid", "party", ...) or nil outside an instance. GetInstanceInfo's 2nd value wins; IsInInstance is
-- the fallback for clients where GetInstanceInfo is missing or says nothing.
function L.instanceType(giType, inInstance, iiType)
  if type(giType) == "string" and giType ~= "" then
    if giType == "none" then return nil end
    return giType
  end
  if inInstance and type(iiType) == "string" and iiType ~= "none" and iiType ~= "" then return iiType end
  return nil
end

-- Raid size: GetInstanceInfo's maxPlayers, else the first number in the difficulty name ("20 Player"), else nil.
function L.raidSize(maxPlayers, difficultyName)
  if type(maxPlayers) == "number" and maxPlayers > 0 then return maxPlayers end
  if type(difficultyName) == "string" then
    local n = tonumber(string.match(difficultyName, "(%d+)"))
    if n and n > 0 then return n end
  end
  return nil
end

-- ENCOUNTER_START/END / BOSS_KILL arguments made safe to compare, concatenate, store and use as table keys:
-- a "secret" value (isSecret(v) true) or a wrong type becomes nil. Returns id (number or nil), name (string or nil).
function L.cleanEncounter(id, name, isSecret)
  local function plain(v, want)
    if isSecret and isSecret(v) then return nil end
    if type(v) ~= want then return nil end
    return v
  end
  id = plain(id, "number")
  name = plain(name, "string")
  if name == "" then name = nil end
  return id, name
end

-- Index of a successful kill of the same boss (encounterId, else name) recorded within `window` seconds, or nil.
-- Used so ENCOUNTER_END and BOSS_KILL (either order) give one kill. With neither id nor name (both were secret
-- values) any kill in the window matches: two bosses dying within 30 s of each other doesn't happen.
function L.findRecentKill(kills, id, name, now, window)
  if type(kills) ~= "table" then return nil end
  for i = #kills, 1, -1 do
    local k = kills[i]
    if type(k) == "table" and k.success and now - (k.t or 0) < (window or 30) then
      if (id ~= nil and k.encounterId == id) or (id == nil and name ~= nil and k.name == name)
          or (id == nil and name == nil) then return i end
    end
  end
  return nil
end

L.UNKNOWN_BOSS = "Unknown boss"

-- Name to save for a kill. The bot drops kills without a name, so a secret/missing name falls back to the name
-- ENCOUNTER_START gave, then "Encounter <id>", then "Unknown boss".
function L.killName(name, startName, id)
  if type(name) == "string" and name ~= "" then return name end
  if type(startName) == "string" and startName ~= "" then return startName end
  if type(id) == "number" then return "Encounter " .. id end
  return L.UNKNOWN_BOSS
end

-- True when the open trade skill window shows someone else's recipes (a linked or guild profession, or an NPC
-- crafting order): those must not be saved as this character's recipes.
function L.foreignTradeSkill(linked, guild, npc)
  return (linked and true or false) or (guild and true or false) or (npc and true or false)
end

-- Profession name for the craft window (Classic Enchanting). The display skill line wins; the craft name is only
-- trusted when it matches a known profession (hunters' Beast Training uses the same window). `profs` is the
-- character's professions list ({ { name = ... } }) or nil when unknown.
function L.craftProfession(displayLine, craftName, profs)
  if type(displayLine) == "string" and displayLine ~= "" and displayLine ~= "UNKNOWN" then return displayLine end
  if type(craftName) ~= "string" or craftName == "" or craftName == "UNKNOWN" then return nil end
  if type(profs) ~= "table" or #profs == 0 then return craftName end
  for _, p in ipairs(profs) do
    if type(p) == "table" and p.name == craftName then return craftName end
  end
  return nil
end

-- "Enchanting 30, Tailoring 45" (sorted by profession), or nil when there are none.
function L.recipeSummary(recipes)
  if type(recipes) ~= "table" then return nil end
  local parts = {}
  for prof, list in pairs(recipes) do
    if type(prof) == "string" and type(list) == "table" then table.insert(parts, prof .. " " .. #list) end
  end
  if #parts == 0 then return nil end
  table.sort(parts)
  return table.concat(parts, ", ")
end

-- An attunement whose quest ids aren't known yet (empty `quests`): shown as "?" and never read from the game.
function L.attunementPending(a)
  return type(a) ~= "table" or type(a.quests) ~= "table" or #a.quests == 0
end

-- Quest log rows for /gf questid: entry(i) returns title, isHeader, questId (any client). Headers and rows without
-- an id are skipped. Returns { { id = n, title = s }, ... } in log order.
function L.questLogRows(n, entry)
  local out = {}
  for i = 1, (type(n) == "number" and n or 0) do
    local title, isHeader, id = entry(i)
    if not isHeader and type(id) == "number" and id > 0 then
      table.insert(out, { id = id, title = type(title) == "string" and title or "?" })
    end
  end
  return out
end


-- ---------------------------------------------------------------------------
-- Head-to-head from Sephya's GayFurriesLeaderboard (its SavedVariable, read only)
-- ---------------------------------------------------------------------------

-- "First Surname" (the form GayFurriesLeaderboard stores), or just "First" without a surname. nil without a name.
function L.fullName(first, surname)
  if type(first) ~= "string" or first == "" then return nil end
  if type(surname) == "string" and surname ~= "" then return first .. " " .. surname end
  return first
end

-- Display names (display only: every key stays the first name). Returns lower(first) -> surname from
--   * own characters: characters[name].surname (from UnitName, wins over the roster),
--   * roster members: m.fullName "First Surname", only when its first word is m.name ("Minuscule Dog" for a
--     registered "Minusculedog" gives nothing). "Name-Realm" names are skipped.
--   * bot Discord data (optional third argument): discord.characters[name].surname, lowest priority.
function L.surnameMap(members, characters, discord)
  local map = {}
  local dchars = type(discord) == "table" and type(discord.characters) == "table" and discord.characters or {}
  for name, c in pairs(dchars) do
    if type(name) == "string" and type(c) == "table" and type(c.surname) == "string" and c.surname ~= ""
        and not string.find(name, "-", 1, true) then
      map[string.lower(name)] = c.surname
    end
  end
  for _, m in ipairs(type(members) == "table" and members or {}) do
    if type(m) == "table" and type(m.name) == "string" and type(m.fullName) == "string"
        and not string.find(m.name, "-", 1, true) then
      local first, rest = string.match(m.fullName, "^%s*(%S+)%s+(.-)%s*$")
      if first and rest ~= "" and string.lower(first) == string.lower(m.name) then
        map[string.lower(m.name)] = rest
      end
    end
  end
  for name, c in pairs(type(characters) == "table" and characters or {}) do
    if type(name) == "string" and type(c) == "table" and type(c.surname) == "string" and c.surname ~= ""
        and not string.find(name, "-", 1, true) then
      map[string.lower(name)] = c.surname
    end
  end
  return map
end

-- "First Surname" when `surnames` (from L.surnameMap) knows the surname, else name unchanged (nil stays nil,
-- "Name-Realm" stays as it is).
function L.displayName(name, surnames)
  if type(name) ~= "string" or name == "" or string.find(name, "-", 1, true) then return name end
  local sn = type(surnames) == "table" and surnames[string.lower(name)]
  if type(sn) == "string" and sn ~= "" then return name .. " " .. sn end
  return name
end

-- Wins and losses of `me` against `other` in a list of { w = winner, l = loser } (duels or deathrolls).
-- Names compare case-insensitively; entries between anyone else are skipped.
function L.headToHead(list, me, other)
  local wins, losses = 0, 0
  if type(list) ~= "table" or type(me) ~= "string" or type(other) ~= "string" then return wins, losses end
  me, other = string.lower(me), string.lower(other)
  if me == other then return wins, losses end
  for _, d in ipairs(list) do
    if type(d) == "table" and type(d.w) == "string" and type(d.l) == "string" then
      local w, l = string.lower(d.w), string.lower(d.l)
      if w == me and l == other then
        wins = wins + 1
      elseif w == other and l == me then
        losses = losses + 1
      end
    end
  end
  return wins, losses
end

-- "You vs them: duels 3-1 · deathrolls 2-0" (your wins-losses; each part only when it has records), or nil
-- when neither has any.
function L.headToHeadLine(duelWins, duelLosses, rollWins, rollLosses)
  local parts = {}
  if (duelWins or 0) + (duelLosses or 0) > 0 then
    table.insert(parts, string.format("duels %d-%d", duelWins or 0, duelLosses or 0))
  end
  if (rollWins or 0) + (rollLosses or 0) > 0 then
    table.insert(parts, string.format("deathrolls %d-%d", rollWins or 0, rollLosses or 0))
  end
  if #parts == 0 then return nil end
  return "You vs them: " .. table.concat(parts, " \194\183 ")
end

-- ---------------------------------------------------------------------------
-- Leaderboards view in the guild window, from Sephya's GayFurriesLeaderboardDB (read only, never written)
-- ---------------------------------------------------------------------------

-- Same weekly reset as GayFurriesLeaderboard: Tuesday 15:00 UTC (epoch 0 was a Thursday). Weekly counters only
-- count while a member's `week` equals the current week id.
L.LB_RESET_OFFSET = 5 * 86400 + 15 * 3600
function L.lbWeekId(now)
  return math.floor(((now or 0) - L.LB_RESET_OFFSET) / 604800)
end

-- Board picker order. field: member field; weekly: only counts in the current week; total: the all-time field shown
-- next to the week on the same board (rank by either one); log: built from that list.
L.LB_BOARDS = {
  { key = "pvp", text = "PvP kills", field = "weekly", total = "total", weekly = true },
  { key = "deaths", text = "Deaths", field = "dWeekly", total = "dTotal", weekly = true },
  { key = "gold", text = "Gold", field = "gold" },
  { key = "duels", text = "Duels", log = "duels" },
  { key = "rolls", text = "Deathrolls", log = "rolls" },
  { key = "shame", text = "Wall of Shame", shame = true },   -- L.shameRows, not L.leaderboardRows
  -- Minigame scores heard from guildmates' addons (L.gameLeaderboardRows, GameLogic.lua), not Sephya's data.
  { key = "paw", text = "Paw Drop", game = "paw", total = "best" },
}
L.LB_BOARD = {}
for _, b in ipairs(L.LB_BOARDS) do L.LB_BOARD[b.key] = b end
-- The 1.6.0 single-number boards, still accepted (not in the picker).
L.LB_BOARD.pvpWeek = { key = "pvpWeek", text = "PvP week", field = "weekly", weekly = true }
L.LB_BOARD.pvpTotal = { key = "pvpTotal", text = "PvP total", field = "total" }
L.LB_BOARD.deathsWeek = { key = "deathsWeek", text = "Deaths week", field = "dWeekly", weekly = true }
L.LB_BOARD.deathsTotal = { key = "deathsTotal", text = "Deaths total", field = "dTotal" }

local function lbNum(v) return type(v) == "number" and v or 0 end

-- Rows for one board: { rank, name, class, value, week?, total?, wins?, losses?, net? }, best first. value is the
-- number the board ranks by: kills / deaths / copper; duels: wins (ties: fewer losses); deathrolls: net copper (ties:
-- wins). PvP and deaths rows carry both week and total; by = "total" ranks by the total (ties: week), else by the
-- week (ties: total). Hidden gold (-1) and bad entries are left out. Equal results share a rank ("1, 2, 2, 4").
-- keep (optional): keep(name) -> false leaves a name out before ranking (L.lbRosterFilter: former members).
function L.leaderboardRows(db, board, now, by, keep)
  local rows = {}
  local cfg = L.LB_BOARD[board]
  if type(db) ~= "table" or not cfg or cfg.shame then return rows end
  local members = type(db.members) == "table" and db.members or {}
  local function memberClass(name)
    local m = members[name]
    return type(m) == "table" and type(m.class) == "string" and m.class ~= "" and m.class or nil
  end
  if cfg.log then
    local byName = {}
    local function get(name, class)
      local e = byName[name]
      if not e then
        e = { name = name, wins = 0, losses = 0, net = 0 }
        byName[name] = e
        table.insert(rows, e)
      end
      if not e.class and type(class) == "string" and class ~= "" then e.class = class end   -- newest first
      return e
    end
    for _, d in ipairs(type(db[cfg.log]) == "table" and db[cfg.log] or {}) do
      if type(d) == "table" and type(d.w) == "string" and d.w ~= "" and type(d.l) == "string" and d.l ~= "" then
        local bet = (type(d.bet) == "number" and d.bet > 0) and d.bet or 0
        local w, l = get(d.w, d.wc), get(d.l, d.lc)
        w.wins, l.losses = w.wins + 1, l.losses + 1
        w.net, l.net = w.net + bet, l.net - bet
      end
    end
    for _, e in ipairs(rows) do
      e.class = memberClass(e.name) or e.class or ""
      if board == "duels" then e.value, e.net = e.wins, nil else e.value = e.net end
    end
  else
    local week = L.lbWeekId(now)
    for name, m in pairs(members) do
      if type(name) == "string" and name ~= "" and type(m) == "table" then
        local v = lbNum(m[cfg.field])
        if cfg.weekly and m.week ~= week then v = 0 end   -- a stale week counts as 0
        if not (board == "gold" and (type(m.gold) ~= "number" or m.gold < 0)) then   -- hidden gold: left out
          local r = { name = name, class = memberClass(name) or "", value = v }
          if cfg.total then
            r.week, r.total = v, lbNum(m[cfg.total])
            if by == "total" then r.value = r.total end
          end
          table.insert(rows, r)
        end
      end
    end
  end
  if keep then
    local kept = {}
    for _, r in ipairs(rows) do
      if keep(r.name) then kept[#kept + 1] = r end
    end
    rows = kept
  end
  local function tie(a)
    if cfg.total then return by == "total" and a.week or a.total end
    return board == "duels" and -a.losses or (board == "rolls" and a.wins or 0)
  end
  table.sort(rows, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    if tie(a) ~= tie(b) then return tie(a) > tie(b) end
    return string.lower(a.name) < string.lower(b.name)
  end)
  for i, r in ipairs(rows) do
    local p = rows[i - 1]
    r.rank = (p and p.value == r.value and tie(p) == tie(r)) and p.rank or i
  end
  return rows
end

-- keep(name) for L.leaderboardRows: true for names in the roster scan (members = ns.db.guild.members), matching
-- "First Surname" against a member's fullName and an old first-name-only key against its first word / name, all
-- case-insensitive. nil when there is no roster scan yet (then nobody is hidden).
function L.lbRosterFilter(members)
  if type(members) ~= "table" or #members == 0 then return nil end
  local full, first = {}, {}
  for _, m in ipairs(members) do
    if type(m) == "table" then
      if type(m.fullName) == "string" and m.fullName ~= "" then
        full[string.lower(m.fullName)] = true
        local w = string.match(m.fullName, "^%s*(%S+)")
        if w then first[string.lower(w)] = true end
      end
      if type(m.name) == "string" and m.name ~= "" then first[string.lower(m.name)] = true end
    end
  end
  return function(name)
    if type(name) ~= "string" then return false end
    local base = string.lower(string.match(name, "^([^%-]*)") or name)
    base = string.match(base, "^%s*(.-)%s*$")
    if full[base] then return true end
    return not string.find(base, " ", 1, true) and first[base] == true
  end
end

-- Wall of Shame (guild window, display only): guildmates in the last roster scan who hide their gold from Sephya's
-- Leaderboard (gold -1), or who have no Leaderboard entry at all (no addon) and were online in the last `days` (30)
-- days. Rows { rank, name ("First Surname"), class, crime = "gold" / "addon", value, quip }, gold hiders first.
L.SHAME_QUIPS = {
  gold = { "What are they hiding?", "Gold: classified", "Suspiciously rich. Or broke.", "Banks with the Shadow Council",
    "Too ashamed of their gold", "Keeps it under the mattress" },
  addon = { "Doesn't even have the addon", "Playing on hard mode", "Unranked and unbothered",
    "Too cool for addons", "Still installing it, surely", "Lives in the dark ages" },
}
L.SHAME_CRIME = { gold = "Hides their gold", addon = "No addon" }

local function quipFor(kind, name)
  local list, h = L.SHAME_QUIPS[kind], 0
  for i = 1, #name do h = (h * 31 + string.byte(name, i)) % 1000003 end
  return list[h % #list + 1]
end

function L.shameRows(lbdb, members, days)
  local rows = {}
  if type(members) ~= "table" then return rows end
  local byName, byFirst = {}, {}
  for key, e in pairs(type(lbdb) == "table" and type(lbdb.members) == "table" and lbdb.members or {}) do
    if type(key) == "string" and type(e) == "table" then
      local k = string.lower(string.match(key, "^([^%-]*)") or key)
      byName[k] = e
      if not string.find(k, " ", 1, true) then byFirst[k] = e end
    end
  end
  for _, m in ipairs(members) do
    if type(m) == "table" and type(m.name) == "string" then
      local full = type(m.fullName) == "string" and m.fullName ~= "" and m.fullName or m.name
      local low = string.lower(full)
      local e = byName[low] or byFirst[string.lower(string.match(full, "^%s*(%S+)") or full)]
        or byFirst[string.lower(m.name)]
      local crime
      if e then
        if e.gold == -1 then crime = "gold" end
      elseif m.online or (type(m.lastOnlineDays) == "number" and m.lastOnlineDays <= (days or 30)) then
        crime = "addon"
      end
      if crime then
        table.insert(rows, { name = full, class = type(m.class) == "string" and m.class or "", crime = crime,
          value = crime == "gold" and 2 or 1, quip = quipFor(crime, low) })
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return string.lower(a.name) < string.lower(b.name)
  end)
  for i, r in ipairs(rows) do r.rank = i end
  return rows
end

-- A sorted copy of board rows by "rank" (1 first), "name" (A-Z), "value" or "record" (wins, then fewer losses;
-- both biggest first). reverse flips the order. Ties keep rank order.
function L.sortLeaderboard(rows, key, reverse)
  local function k(r)
    if key == "name" then return string.lower(r.name) end
    if key == "value" then return r.value end
    if key == "record" then return (r.wins or 0) * 100000 - (r.losses or 0) end
    return -r.rank
  end
  local out = {}
  for i, r in ipairs(rows) do out[i] = r end
  table.sort(out, function(a, b)
    local ka, kb = k(a), k(b)
    if ka ~= kb then
      if key == "name" then return (ka < kb) ~= (reverse and true or false) end
      return (ka > kb) ~= (reverse and true or false)
    end
    if a.rank ~= b.rank then return a.rank < b.rank end
    return string.lower(a.name) < string.lower(b.name)
  end)
  return out
end

-- "+12g 50s 0c" / "-3s 0c" / "0c" for a net copper amount (letters in coin colors; resume as in L.coin).
function L.formatNetMoney(c, resume)
  if type(c) ~= "number" then return "?" end
  if c > 0 then return "+" .. L.formatMoney(c, resume) end
  if c < 0 then return "-" .. L.formatMoney(-c, resume) end
  return L.coin(0, "c", resume)
end

-- ---------------------------------------------------------------------------
-- Bot data relay (docs "Bot data relay"): members without the uploader get GFoAGuildSyncBotData from an officer's
-- addon. G:<generated> asks on GUILD; a holder (data from the uploader file) answers by WHISPER with
-- B:<msgId>:<i>/<n>:<chunk>, the chunks joined being a GFOA1 string of the compact JSON below. Pure parts only.
-- ---------------------------------------------------------------------------

L.RELAY_STALE = 12 * 3600        -- ask when the newest copy is older than this
L.RELAY_ASK_GAP = 1800           -- at most one request per 30 minutes
L.RELAY_MAX_RANK = 2             -- trust replies only from guild ranks 0..2 (rankIndex: 0 = guild master)
L.RELAY_MAX_MSGS = 120           -- largest reply in addon messages (about 28 KB, two minutes at 1/s)
L.RELAY_MAX_CHARS = 1000         -- bounds for a received table
L.RELAY_MAX_CRAFTS = 3000
L.RELAY_MAX_CRAFTERS = 5
L.RELAY_NAME_MAX = 48            -- character names, mains, surnames, roles, specs
L.RELAY_KEY_MAX = 100            -- crafter keys (lowercase item / recipe names)

-- G:<generated> (0 = none) and B chunks; returns kind and fields or nil. Kept apart from L.parseMessage (Codec.lua)
-- so older addons and the guild sync parser never see these kinds.
function L.parseRelayMessage(msg)
  if type(msg) ~= "string" then return nil end
  local have = string.match(msg, "^G:(%d+)$")
  if have then return "G", tonumber(have) end
  local id, i, n, chunk = string.match(msg, "^B:(%w+):(%d+)/(%d+):(.*)$")
  if id then
    i, n = tonumber(i), tonumber(n)
    if i and n and i >= 1 and i <= n and n <= L.RELAY_MAX_MSGS then return "B", id, i, n, chunk end
  end
  return nil
end

function L.relayRequestMessage(have)
  return "G:" .. tostring(math.max(0, math.floor(tonumber(have) or 0)))
end

-- The `generated` time of a bot data table, 0 when missing / not version 1.
function L.botDataGenerated(d)
  if type(d) ~= "table" or (d.version ~= nil and d.version ~= 1) then return 0 end
  return type(d.generated) == "number" and d.generated or 0
end

-- The newer of the uploader file's table and the relayed copy (the file on a tie). Returns the table itself (never a
-- copy: Roster.lua's display-name cache keys on its identity) and "file" / "relay", or nil.
function L.newerBotData(file, relay)
  local fg, rg = L.botDataGenerated(file), L.botDataGenerated(relay)
  local fileOk = type(file) == "table" and (file.version == nil or file.version == 1)
  local relayOk = type(relay) == "table" and relay.version == 1 and rg > 0
  if relayOk and (not fileOk or rg > fg) then return relay, "relay" end
  if fileOk then return file, "file" end
  return nil
end

-- Should this addon ask now? have = newest generated time we hold (0 = none). Returns want, have.
function L.relayShouldAsk(have, now, lastAsk, stale, gap)
  have = tonumber(have) or 0
  if now - (tonumber(lastAsk) or 0) < (gap or L.RELAY_ASK_GAP) then return false, have end
  if have <= 0 or now - have > (stale or L.RELAY_STALE) then return true, have end
  return false, have
end

-- Should a holder answer a G:<have>? Only with a newer copy from the uploader file.
function L.relayShouldAnswer(fileGenerated, have)
  fileGenerated, have = tonumber(fileGenerated) or 0, tonumber(have) or 0
  return fileGenerated > 0 and fileGenerated > have
end

-- The roster member for an addon message sender ("Name", "Name-Realm" or "Name Surname"), matching the roster's
-- name or the first word of its fullName, case-insensitively. nil when not in the last roster scan.
function L.rosterMember(members, who)
  local short = L.stripRealm(who)
  if not short or type(members) ~= "table" then return nil end
  short = string.lower(short)
  for _, m in ipairs(members) do
    if type(m) == "table" then
      local first = type(m.fullName) == "string" and string.match(m.fullName, "^%s*(%S+)") or nil
      if (type(m.name) == "string" and string.lower(m.name) == short) or (first and string.lower(first) == short) then
        return m
      end
    end
  end
  return nil
end

-- Trust rule for relayed bot data: the sender is in our last roster scan with rankIndex 0..maxRank.
function L.relayTrusted(members, who, maxRank)
  local m = L.rosterMember(members, who)
  if not m or type(m.rankIndex) ~= "number" then return false end
  return m.rankIndex >= 0 and m.rankIndex <= (maxRank or L.RELAY_MAX_RANK)
end

local function relayStr(v, max)
  if type(v) ~= "string" or v == "" or #v > max or string.find(v, "[%c|]") then return nil end
  return v
end

-- Compact JSON payload of a bot data table (known fields only):
--   { v = 1, g = generated, c = { Name = { main or "" (= itself) or false, 1|0 registered, role, spec, surname } },
--     f = { ["runecloth bag"] = { "Testy" } } }
-- Missing strings are "", trailing "" dropped. withCrafters = false leaves f out (a reply that would be too long).
function L.relayPayload(d, withCrafters)
  local c = {}
  for name, e in pairs(type(d) == "table" and type(d.characters) == "table" and d.characters or {}) do
    if relayStr(name, L.RELAY_NAME_MAX) and type(e) == "table" then
      local main = relayStr(e.main, L.RELAY_NAME_MAX)
      local row = { main == name and "" or main or false, e.registered == true and 1 or 0,
        relayStr(e.role, L.RELAY_NAME_MAX) or "", relayStr(e.spec, L.RELAY_NAME_MAX) or "",
        relayStr(e.surname, L.RELAY_NAME_MAX) or "" }
      while #row > 2 and row[#row] == "" do row[#row] = nil end
      c[name] = row
    end
  end
  local payload = { v = 1, g = L.botDataGenerated(d), c = c }
  if withCrafters ~= false then
    local f = {}
    for key, list in pairs(type(d) == "table" and type(d.crafters) == "table" and d.crafters or {}) do
      if relayStr(key, L.RELAY_KEY_MAX) and type(list) == "table" then
        local names = {}
        for i = 1, math.min(#list, L.RELAY_MAX_CRAFTERS) do
          if relayStr(list[i], L.RELAY_NAME_MAX) then names[#names + 1] = list[i] end
        end
        if #names > 0 then f[key] = names end
      end
    end
    payload.f = f
  end
  return payload
end

-- Validates a decoded relay payload into a GFoAGuildSyncBotData-shaped table (version 1, bounded sizes, only the
-- known fields). Returns the table, or nil + reason. now: receiver time (a `g` over a day ahead is rejected).
function L.botDataFromRelay(p, now)
  if type(p) ~= "table" or p.v ~= 1 then return nil, "not version 1" end
  local g = p.g
  if type(g) ~= "number" or g <= 0 or g ~= math.floor(g) then return nil, "no generated time" end
  if now and g > now + 86400 then return nil, "generated in the future" end
  if type(p.c) ~= "table" then return nil, "no characters" end
  local chars, n = {}, 0
  for name, row in pairs(p.c) do
    n = n + 1
    if n > L.RELAY_MAX_CHARS then return nil, "too many characters" end
    if relayStr(name, L.RELAY_NAME_MAX) and type(row) == "table" then
      local e = { registered = row[2] == 1 }
      if row[1] == "" then e.main = name else e.main = relayStr(row[1], L.RELAY_NAME_MAX) end
      e.role = relayStr(row[3], L.RELAY_NAME_MAX)
      e.spec = relayStr(row[4], L.RELAY_NAME_MAX)
      e.surname = relayStr(row[5], L.RELAY_NAME_MAX)
      chars[name] = e
    end
  end
  local crafters, k = {}, 0
  if p.f ~= nil and type(p.f) ~= "table" then return nil, "bad crafters" end
  for key, list in pairs(p.f or {}) do
    k = k + 1
    if k > L.RELAY_MAX_CRAFTS then return nil, "too many crafted items" end
    if relayStr(key, L.RELAY_KEY_MAX) and type(list) == "table" then
      local names = {}
      for i = 1, math.min(#list, L.RELAY_MAX_CRAFTERS) do
        if relayStr(list[i], L.RELAY_NAME_MAX) then names[#names + 1] = list[i] end
      end
      if #names > 0 then crafters[string.lower(key)] = names end
    end
  end
  return { version = 1, generated = g, characters = chars, crafters = crafters }
end

-- The reply messages for a bot data table: B:<msgId>:<i>/<n>:<chunk> of the GFOA1 string, crafters dropped when the
-- full reply would be over RELAY_MAX_MSGS. Returns the list and whether crafters were dropped, or nil. Needs Codec.lua.
function L.relayReplyMessages(d, msgId, maxMsgs)
  maxMsgs = maxMsgs or L.RELAY_MAX_MSGS
  for _, withCrafters in ipairs({ true, false }) do
    local msgs = L.chunkMessages(L.encodeExport(L.relayPayload(d, withCrafters)), msgId)
    if #msgs <= maxMsgs then
      for i, m in ipairs(msgs) do msgs[i] = "B" .. string.sub(m, 2) end   -- same framing as D, own kind letter
      return msgs, not withCrafters
    end
  end
  return nil
end


-- ---------------------------------------------------------------------------
-- 1.7.0: raid-night panel, guild event reminders, crafter lookup, craft-request notes, leaderboard toasts
-- ---------------------------------------------------------------------------

-- Same raids, sizes and attunement names as the bot (guildbot/store.py RAID_SIZES / RAID_ATTUNEMENT).
L.RAIDS = { "Barrow Deeps", "Hyjal Summit", "Onyxia's Lair" }
L.RAID_SIZES = { ["Barrow Deeps"] = 10, ["Hyjal Summit"] = 20, ["Onyxia's Lair"] = 40 }
L.RAID_ATTUNEMENT = { ["Onyxia's Lair"] = "Onyxia" }
L.ROLES = { "Tank", "Healer", "DPS" }

-- A group / roster name ("Asha Brightvale", "Asha-Realm", "Asha") -> "Asha", the key everything else uses.
function L.firstName(name)
  return (L.splitName(name))
end

-- Attunements in any shape we get them: a list of names (bot export `att`, payload `att`) or a { name = true }
-- table (own sheets). Returns a set, or nil when unknown (nil / not a table). An empty table means "checked, none".
function L.attSet(att)
  if type(att) ~= "table" then return nil end
  local set = {}
  for k, v in pairs(att) do
    if type(k) == "number" and type(v) == "string" then set[v] = true
    elseif type(k) == "string" and v == true then set[k] = true end
  end
  return set
end

-- "Tank" / "Healer" / "DPS" or nil, case-insensitive.
function L.normalRole(role)
  if type(role) ~= "string" then return nil end
  local low = string.lower(role)
  for _, r in ipairs(L.ROLES) do
    if string.lower(r) == low then return r end
  end
  return nil
end

-- One person for the readiness check from what the addon knows. Sources (all optional):
--   discord = GFoAGuildSyncBotData (role, `att` per registered character)
--   own     = GFoAGuildSyncDB.characters (this PC's characters: level, class, attunements)
--   synced  = { [name] = payload char } from decoded guild sync payloads (officer addons: lvl, cls, att)
-- base = { name, level, class, online } from the group or guild roster. Own sheets win, then sync, then the bot.
function L.readinessPerson(base, discord, own, synced)
  local name = L.firstName(base and base.name)
  if not name then return nil end
  local p = { name = name, level = base.level, class = base.class, online = base.online }
  local mine = type(own) == "table" and own[name]
  local sync = type(synced) == "table" and synced[name]
  local entry = L.memberEntry(discord, name)
  if type(mine) == "table" then
    p.att = L.attSet(mine.attunements)
    if type(p.level) ~= "number" or p.level == 0 then p.level = mine.level end
    p.class = p.class or mine.class
  end
  if p.att == nil and type(sync) == "table" then
    p.att = L.attSet(sync.att)
    if type(p.level) ~= "number" or p.level == 0 then p.level = sync.lvl end
    p.class = p.class or sync.cls
  end
  if p.att == nil and type(entry) == "table" then p.att = L.attSet(entry.att) end
  p.role = L.normalRole(type(entry) == "table" and entry.role or nil)
  p.spec = type(entry) == "table" and type(entry.spec) == "string" and entry.spec or nil
  return p
end

-- The bot's /raid ready split for people (from readinessPerson): ready, lowLevel (below max level), notAttuned,
-- unknown (attunement tracked but no addon data), plus the role count over everyone. Lists sorted by name.
function L.raidReadiness(people, raid, maxLevel)
  maxLevel = maxLevel or L.MAX_LEVEL
  local attune = L.RAID_ATTUNEMENT[raid]
  local r = { raid = raid, size = L.RAID_SIZES[raid], attunement = attune,
    ready = {}, lowLevel = {}, notAttuned = {}, unknown = {}, roles = { Tank = 0, Healer = 0, DPS = 0, none = 0 } }
  local seen = {}
  for _, p in ipairs(people or {}) do
    if type(p) == "table" and type(p.name) == "string" and not seen[string.lower(p.name)] then
      seen[string.lower(p.name)] = true
      local role = L.normalRole(p.role) or "none"
      r.roles[role] = r.roles[role] + 1
      if (tonumber(p.level) or 0) < maxLevel then
        table.insert(r.lowLevel, p)
      elseif attune and p.att == nil then
        table.insert(r.unknown, p)
      elseif attune and not p.att[attune] then
        table.insert(r.notAttuned, p)
      else
        table.insert(r.ready, p)
      end
    end
  end
  local function byName(a, b) return string.lower(a.name) < string.lower(b.name) end
  for _, k in ipairs({ "ready", "lowLevel", "notAttuned", "unknown" }) do table.sort(r[k], byName) end
  r.people = #r.ready + #r.lowLevel + #r.notAttuned + #r.unknown
  return r
end

-- Which raid the panel starts on: the raid you're standing in, else the one you picked last, else by group size.
function L.defaultRaid(zone, groupSize, saved)
  if type(zone) == "string" and L.RAID_SIZES[zone] then return zone end
  if type(saved) == "string" and L.RAID_SIZES[saved] then return saved end
  local n = tonumber(groupSize) or 0
  if n > 20 then return "Onyxia's Lair" end
  if n > 10 then return "Hyjal Summit" end
  return "Barrow Deeps"
end

-- "Tanks 2  Healers 3  DPS 5  (no role 1)  -  8/10 ready"
function L.roleLine(r)
  local text = string.format("Tanks %d  Healers %d  DPS %d", r.roles.Tank, r.roles.Healer, r.roles.DPS)
  if r.roles.none > 0 then text = text .. "  (no role " .. r.roles.none .. ")" end
  if r.size then text = text .. string.format("  -  %d/%d ready", #r.ready, r.size) end
  return text
end

-- Guild events from the bot export (`events`): only well-formed future ones, soonest first, at most max.
function L.upcomingEvents(list, now, max)
  local out = {}
  for _, e in ipairs(type(list) == "table" and list or {}) do
    if type(e) == "table" and type(e.name) == "string" and e.name ~= "" and type(e.start) == "number"
        and e.start > now then
      table.insert(out, e)
    end
  end
  table.sort(out, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    return a.name < b.name
  end)
  while max and #out > max do table.remove(out) end
  return out
end

-- "Onyxia (Onyxia's Lair, Team A)"; the raid is left out when it's the same as the name.
function L.eventLabel(e)
  local extra = {}
  if type(e.raid) == "string" and e.raid ~= "" and e.raid ~= e.name then table.insert(extra, e.raid) end
  if type(e.team) == "string" and e.team ~= "" then table.insert(extra, "Team " .. e.team) end
  if #extra == 0 then return e.name end
  return e.name .. " (" .. table.concat(extra, ", ") .. ")"
end

-- Short minimap text: "45m", "2h", "3d"; nil from 7 days on.
function L.shortCountdown(secs)
  if type(secs) ~= "number" or secs < 0 then return nil end
  if secs < 3600 then return math.max(1, math.ceil(secs / 60)) .. "m" end
  if secs < 86400 then return math.floor(secs / 3600) .. "h" end
  if secs < 7 * 86400 then return math.floor(secs / 86400) .. "d" end
  return nil
end

-- Minimap button offset from the minimap centre for an angle (degrees), minimap size and GetMinimapShape() value.
-- Round quadrants sit on an ellipse just outside the edge; square quadrants (Leatrix Plus "Square minimap",
-- SexyMap, ElvUI...) follow the square's edge instead of floating inside the corner. Quadrant flags per shape:
-- { bottom-right, bottom-left, top-right, top-left }, true = round there. Unknown shapes count as round.
L.MINIMAP_SHAPES = {
  ["ROUND"] = { true, true, true, true },
  ["SQUARE"] = { false, false, false, false },
  ["CORNER-TOPLEFT"] = { false, false, false, true },
  ["CORNER-TOPRIGHT"] = { false, false, true, false },
  ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
  ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
  ["SIDE-LEFT"] = { false, true, false, true },
  ["SIDE-RIGHT"] = { true, false, true, false },
  ["SIDE-TOP"] = { false, false, true, true },
  ["SIDE-BOTTOM"] = { true, true, false, false },
  ["TRICORNER-TOPLEFT"] = { false, true, true, true },
  ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
  ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
  ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

function L.minimapButtonOffset(angleDeg, width, height, shape)
  local a = math.rad(angleDeg or 315)
  local cx, cy = math.cos(a), math.sin(a)
  local q = 1
  if cx < 0 then q = q + 1 end
  if cy > 0 then q = q + 2 end
  local rx, ry = (width or 140) / 2 + 5, (height or 140) / 2 + 5
  local quads = L.MINIMAP_SHAPES[shape or "ROUND"] or L.MINIMAP_SHAPES.ROUND
  if quads[q] then return cx * rx, cy * ry end
  -- Square quadrant: push out along the diagonal, then clamp to the square's edge.
  local dx, dy = math.sqrt(2 * rx * rx) - 10, math.sqrt(2 * ry * ry) - 10
  return math.max(-rx, math.min(cx * dx, rx)), math.max(-ry, math.min(cy * dy, ry))
end

L.REMINDER_MARKS = { 30, 5 }

-- Reminders due now: per event, the smallest mark (minutes) we're inside of, once. sent[key] = start remembers
-- what was said (a /reload doesn't repeat it; logging in 3 minutes before gives only the 5-minute one). Larger
-- marks are marked as said too. Returns { { event = e, mins = m } }.
function L.dueReminders(events, now, sent, marks)
  marks = marks or L.REMINDER_MARKS
  local out = {}
  for _, e in ipairs(events or {}) do
    local left = e.start - now
    if left > 0 then
      local pick
      for _, m in ipairs(marks) do
        if left <= m * 60 and (not pick or m < pick) then pick = m end
      end
      if pick then
        local base = e.name .. ":" .. e.start .. ":"
        if not sent[base .. pick] then
          for _, m in ipairs(marks) do
            if m >= pick then sent[base .. m] = e.start end
          end
          table.insert(out, { event = e, mins = pick })
        end
      end
    end
  end
  return out
end

-- Drops reminder marks of events that started over an hour ago.
function L.pruneSent(sent, now)
  if type(sent) ~= "table" then return {} end
  for k, start in pairs(sent) do
    if type(start) ~= "number" or start < now - 3600 then sent[k] = nil end
  end
  return sent
end

-- "Discord data is 7h 00m old ..." or nil when fresh (under 6 hours) or unknown.
function L.staleHint(generated, now)
  if type(generated) ~= "number" or generated <= 0 then return nil end
  local age = now - generated
  if age < 6 * 3600 then return nil end
  return "Discord data is " .. L.formatDuration(age) .. " old (it updates when the uploader runs)"
end

-- Crafter lookup: everyone who can craft it, online first, then by skill, then by name. online = set of lower
-- first names. Each entry gets .online.
function L.crafterLookup(list, online)
  local out = {}
  for _, e in ipairs(list or {}) do
    table.insert(out, { name = e.name, prof = e.prof, skill = e.skill,
      online = type(online) == "table" and online[string.lower(e.name or "")] == true or false })
  end
  table.sort(out, function(a, b)
    if a.online ~= b.online then return a.online end
    if (a.skill or 0) ~= (b.skill or 0) then return (a.skill or 0) > (b.skill or 0) end
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)
  return out
end

-- Dedupe key of one craft request: sender + item (id when known) + day, like the bot's craft_requests key.
function L.craftRequestKey(r)
  return string.lower(r.sender or "?") .. ":" .. tostring(r.itemId or string.lower(r.item or "?")) .. ":"
    .. math.floor((r.t or 0) / 86400)
end

-- Open craft requests one of `mine` (set of lower first names: this account's characters) could make.
-- craftersOf(item) -> list of { name }. Your own requests and dismissed ones (dismissed[key]) are left out.
-- Returns { { req = r, key = k, who = { your names } } }, newest first.
function L.craftRequestsFor(requests, mine, craftersOf, dismissed, now, maxAge)
  local out = {}
  maxAge = maxAge or 7 * 86400
  for _, r in ipairs(type(requests) == "table" and requests or {}) do
    if type(r) == "table" and type(r.item) == "string" and type(r.sender) == "string" and type(r.t) == "number"
        and r.t >= now - maxAge and not mine[string.lower(r.sender)] then
      local key = L.craftRequestKey(r)
      if not (type(dismissed) == "table" and dismissed[key]) then
        local who = {}
        for _, c in ipairs(craftersOf(r.item) or {}) do
          if type(c.name) == "string" and mine[string.lower(c.name)] then table.insert(who, c.name) end
        end
        if #who > 0 then table.insert(out, { req = r, key = key, who = who }) end
      end
    end
  end
  table.sort(out, function(a, b) return a.req.t > b.req.t end)
  return out
end

-- Drops dismissed craft requests older than maxAge (default 8 days).
function L.pruneDismissed(dismissed, now, maxAge)
  if type(dismissed) ~= "table" then return {} end
  for k, t in pairs(dismissed) do
    if type(t) ~= "number" or t < now - (maxAge or 8 * 86400) then dismissed[k] = nil end
  end
  return dismissed
end

-- Leaderboard titles, same keys as the bot's boards (guildbot/stats_store.py BOARDS).
L.BOARD_TITLES = {
  deaths = "Most deaths", quests = "Most quests turned in", dungeons = "Most dungeon runs",
  bosses = "Most dungeon bosses killed", kills = "Most mobs slain", flights = "Most flight paths taken",
  hearths = "Most hearthstones", fish = "Most fish caught", skillups = "Most profession skill-ups",
  epics = "Most epics looted", explore = "Most exploration XP", xph = "Fastest levelling session",
  session = "Longest play session", first_epic = "First epic", gold = "Most gold earned",
}

-- { [board] = rank } for name on the bot export's `boards` (first names in rank order).
function L.boardRanks(boards, name)
  local out = {}
  if type(boards) ~= "table" or type(name) ~= "string" then return out end
  local low = string.lower(name)
  for key, list in pairs(boards) do
    if type(key) == "string" and type(list) == "table" then
      for i, n in ipairs(list) do
        if type(n) == "string" and string.lower(n) == low then out[key] = i; break end
      end
    end
  end
  return out
end

-- Boards where you moved up since `old` (nil old = first look: nothing to report). Entering a board counts.
-- Returns { { board, from (nil = new), to } } sorted by board key.
function L.boardMoves(old, new)
  local out = {}
  if type(old) ~= "table" then return out end
  for key, rank in pairs(new or {}) do
    local was = old[key]
    if type(was) ~= "number" or rank < was then table.insert(out, { board = key, from = was, to = rank }) end
  end
  table.sort(out, function(a, b) return a.board < b.board end)
  return out
end

function L.boardMoveText(m)
  local title = L.BOARD_TITLES[m.board] or m.board
  if m.from then return string.format("Up to #%d on %s (was #%d)", m.to, title, m.from) end
  return string.format("You're #%d on %s", m.to, title)
end

-- Guildies who reached maxLevel between two roster scans. old = { [name] = level } (nil = no earlier scan).
function L.dings(old, members, maxLevel)
  maxLevel = maxLevel or L.MAX_LEVEL
  local out = {}
  if type(old) ~= "table" then return out end
  for _, m in ipairs(members or {}) do
    if type(m) == "table" and type(m.name) == "string" and type(m.level) == "number" and m.level >= maxLevel then
      local was = old[m.name]
      if type(was) == "number" and was > 0 and was < maxLevel then table.insert(out, m.name) end
    end
  end
  table.sort(out)
  return out
end

-- { [name] = level } from a roster member list.
function L.levelMap(members)
  local out = {}
  for _, m in ipairs(members or {}) do
    if type(m) == "table" and type(m.name) == "string" and type(m.level) == "number" then out[m.name] = m.level end
  end
  return out
end

return L
