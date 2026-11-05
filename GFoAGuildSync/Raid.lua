-- GFoA Guild Sync: raid attendance, boss kills, deaths and loot.
-- Data only: nothing is announced in game.
local _, ns = ...

local active          -- the raid visit table we're in (an entry of db.raids), or nil
local encounter       -- { id, name, start, deaths = {} } while a boss encounter runs
local combat          -- { start, deaths = {} } fallback for clients without ENCOUNTER_START
local lastKill = {}   -- encounterId/name -> time of last recorded kill (BOSS_KILL dedupe)

-- ---------------------------------------------------------------------------
-- Where are we?
-- ---------------------------------------------------------------------------

local function inRaidGroup()
  if ns.api("IsInRaid") then return ns.call("IsInRaid") and true or false end
  local n = ns.call("GetNumRaidMembers")
  return (n or 0) > 0
end

-- zone, instanceId, size when inside a raid instance, else nil.
-- Works for WoW: Forever's 10 (Barrow Deeps), 20 (Hyjal Summit) and 40 (Onyxia's Lair) player raids alike.
local function raidInstance()
  local kind, name, maxPlayers, instanceId, difficultyName = ns.instanceInfo()
  if kind ~= "raid" or type(name) ~= "string" then return nil end
  return name, instanceId, ns.logic.raidSize(maxPlayers, difficultyName)
end

function ns.currentRaid()
  return active
end

-- ---------------------------------------------------------------------------
-- Roster of the raid group
-- ---------------------------------------------------------------------------

local function raidMembers()
  local out = {}
  local n = ns.call("GetNumGroupMembers") or ns.call("GetNumRaidMembers") or 0
  for i = 1, n do
    local name, _, _, _, _, _, _, online = ns.call("GetRaidRosterInfo", i)
    name = ns.plain(name)   -- a secret name (restricted context) is skipped, never compared
    if type(name) == "string" and online ~= false then
      local short = ns.shortName(name)
      if short then table.insert(out, short) end
    end
  end
  table.sort(out)
  return out
end

local function sameList(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Raid visits
-- ---------------------------------------------------------------------------

local function findOrStartVisit(zone, instanceId, size)
  local db = ns.db
  local t = ns.now()
  local id = instanceId or 0
  for i = #db.raids, 1, -1 do
    local r = db.raids[i]
    if type(r) == "table" and r.instanceId == id and t - (r.last or 0) <= ns.config.raidVisitGap then
      return r
    end
  end
  local r = {
    key = t .. "-" .. id,
    zone = zone,
    instanceId = id,
    size = size,
    start = t,
    last = t,
    snapshots = {},
    kills = {},
  }
  table.insert(db.raids, r)
  return r
end

-- Takes an attendance snapshot when in a raid group inside a raid instance.
local function snapshot(force)
  if not inRaidGroup() then
    active = nil
    return
  end
  local zone, instanceId, size = raidInstance()
  if not zone then
    active = nil
    return
  end
  if not active or active.instanceId ~= (instanceId or 0) then
    active = findOrStartVisit(zone, instanceId, size)
  end
  local t = ns.now()
  local members = raidMembers()
  active.last = t
  active.snapshots = active.snapshots or {}
  local prev = active.snapshots[#active.snapshots]
  -- Skip a timer snapshot identical to the previous one taken less than an interval ago.
  if not force and prev and sameList(prev.members or {}, members)
      and t - (prev.t or 0) < ns.config.raidSnapshotInterval then
    return
  end
  if #members > 0 then
    table.insert(active.snapshots, { t = t, members = members })
  end
  if ns.updateUI then ns.updateUI() end
end

-- Midnight-style clients (12.0+, and WoW: Forever 1.6x, which Details! treats the same way) don't give addons the
-- combat log; never try to register it there (deaths are then simply not recorded).
local COMBAT_LOG_OK = true
do
  local toc = select(4, ns.call("GetBuildInfo"))
  if type(toc) == "number" and (toc >= 120000 or ns.logic.isForeverInterface(toc)) then COMBAT_LOG_OK = false end
end
ns.combatLogOff = not COMBAT_LOG_OK   -- for /gf api
local getCombatLogEvent = ns.api("CombatLogGetCurrentEventInfo")   -- looked up once, not on every combat log event

local function updateCombatLog()
  if not COMBAT_LOG_OK then return end
  if active then
    ns.reregister("COMBAT_LOG_EVENT_UNFILTERED")
  else
    ns.unregister("COMBAT_LOG_EVENT_UNFILTERED")
  end
end

local function checkZone()
  snapshot(true)
  updateCombatLog()
end

-- ---------------------------------------------------------------------------
-- Encounters
-- ---------------------------------------------------------------------------

local function recordKill(id, name, success, duration, deaths)
  snapshot(true)
  if not active then return end
  active.kills = active.kills or {}
  local t = ns.now()
  -- ENCOUNTER_END and BOSS_KILL both fire for one kill, in either order: keep one entry, fill in what's missing.
  local i = success and ns.logic.findRecentKill(active.kills, id, name, t, 30)
  if i then
    local k = active.kills[i]
    k.encounterId = k.encounterId or id
    if name and k.name == ns.logic.UNKNOWN_BOSS then k.name = name end
    k.duration = k.duration or duration
    if #(k.deaths or {}) == 0 then k.deaths = deaths or {} end
    lastKill[id or name or "?"] = t
    return
  end
  table.insert(active.kills, {
    t = t,
    encounterId = id,
    name = ns.logic.killName(name, nil, id),
    success = success and true or false,
    duration = duration,
    members = raidMembers(),
    deaths = deaths or {},
  })
  if success then lastKill[id or name or "?"] = t end
end

-- Encounter ids/names may be secret values on Midnight-style clients: ns.logic.cleanEncounter turns those into nil.
ns.on("ENCOUNTER_START", function(_, id, name)
  id, name = ns.logic.cleanEncounter(id, name, ns.isSecret)
  encounter = { id = id, name = name, start = ns.now(), deaths = {} }
  snapshot(true)
end)

ns.on("ENCOUNTER_END", function(_, id, name, _, _, success)
  id, name = ns.logic.cleanEncounter(id, name, ns.isSecret)
  success = ns.plain(success)
  local e = encounter
  encounter = nil
  local start = e and e.start
  local deaths = e and e.deaths or {}
  if not name and e and (id == nil or e.id == id) then name = e.name end   -- END's name was secret, START's wasn't
  recordKill(id, name, success == 1 or success == true, start and (ns.now() - start) or nil, deaths)
end)

-- Fallback for clients that only fire BOSS_KILL.
ns.on("BOSS_KILL", function(_, id, name)
  id, name = ns.logic.cleanEncounter(id, name, ns.isSecret)
  local key = id or name or "?"
  if lastKill[key] and ns.now() - lastKill[key] < 30 then return end   -- ENCOUNTER_END already did it
  local c = combat
  recordKill(id, name, true, c and (ns.now() - c.start) or nil, c and c.deaths or {})
end)

ns.on("PLAYER_REGEN_DISABLED", function()
  if active and not encounter then combat = { start = ns.now(), deaths = {} } end
end)

-- ---------------------------------------------------------------------------
-- Deaths (combat log UNIT_DIED for raid members)
-- ---------------------------------------------------------------------------

local AFFILIATION_GROUP = 0x00000007   -- mine | party | raid

local function isGroupPlayer(guid, flags)
  if type(guid) ~= "string" or string.sub(guid, 1, 7) ~= "Player-" then return false end
  if type(flags) == "number" and bit and bit.band then
    return bit.band(flags, AFFILIATION_GROUP) ~= 0
  end
  return true
end

local function onCombatLog(_, ...)
  if not active then return end
  local _, sub, _, _, _, _, _, destGUID, destName, destFlags
  if getCombatLogEvent then
    _, sub, _, _, _, _, _, destGUID, destName, destFlags = getCombatLogEvent()
  else
    _, sub, _, _, _, _, _, destGUID, destName, destFlags = ...
  end
  if sub ~= "UNIT_DIED" or not isGroupPlayer(destGUID, destFlags) then return end
  local name = ns.shortName(destName)
  if not name then return end
  local bucket = (encounter and encounter.deaths) or (combat and combat.deaths)
  if bucket then table.insert(bucket, name) end
end
if COMBAT_LOG_OK then
  ns.on("COMBAT_LOG_EVENT_UNFILTERED", onCombatLog)
  ns.unregister("COMBAT_LOG_EVENT_UNFILTERED")   -- only listened to inside raid instances
end

-- ---------------------------------------------------------------------------
-- Loot (CHAT_MSG_LOOT, patterns built from the client's LOOT_ITEM* strings)
-- ---------------------------------------------------------------------------

-- Turns a format string like "%s receives loot: %sx%d." into a Lua pattern with captures.
local function toPattern(fmt)
  local p = string.gsub(fmt, "%%%d%$", "%%")                -- "%1$s" -> "%s"
  p = string.gsub(p, "([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")  -- escape magic chars (not %)
  p = string.gsub(p, "%%s", "(.+)")
  p = string.gsub(p, "%%d", "(%%d+)")
  return "^" .. p .. "$"
end

local lootPatterns
local function buildPatterns()
  lootPatterns = {}
  -- Most specific first. self = true means the looter is the player.
  local list = {
    { "LOOT_ITEM_SELF_MULTIPLE", true }, { "LOOT_ITEM_PUSHED_SELF_MULTIPLE", true },
    { "LOOT_ITEM_MULTIPLE", false }, { "LOOT_ITEM_PUSHED_MULTIPLE", false },
    { "LOOT_ITEM_SELF", true }, { "LOOT_ITEM_PUSHED_SELF", true },
    { "LOOT_ITEM", false }, { "LOOT_ITEM_PUSHED", false },
  }
  for _, e in ipairs(list) do
    local fmt = _G[e[1]]
    if type(fmt) == "string" and fmt ~= "" then
      local ok, pat = pcall(toPattern, fmt)
      if ok then table.insert(lootPatterns, { pat = pat, self = e[2] }) end
    end
  end
end

local QUALITY_BY_COLOR = {
  ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2, ["0070dd"] = 3,
  ["a335ee"] = 4, ["ff8000"] = 5, ["e6cc80"] = 6,
}

local function itemQuality(link)
  local q
  if ns.api("C_Item.GetItemInfo") then
    q = select(3, ns.call("C_Item.GetItemInfo", link))
  end
  if type(q) ~= "number" then q = select(3, ns.call("GetItemInfo", link)) end
  if type(q) == "number" then return q end
  local color = string.match(link, "|c%x%x(%x%x%x%x%x%x)")
  if color then return QUALITY_BY_COLOR[string.lower(color)] end
  return nil
end

-- Returns player, link for a loot message, or nil.
local function parseLoot(msg)
  if not lootPatterns then buildPatterns() end
  for _, p in ipairs(lootPatterns) do
    local a, b = string.match(msg, p.pat)
    if a then
      if p.self then return ns.call("UnitName", "player"), a end
      return ns.shortName(a), b
    end
  end
  return nil
end

ns.on("CHAT_MSG_LOOT", function(_, msg)
  if type(msg) ~= "string" or ns.isSecret(msg) then return end   -- secret in restricted instances: skip quietly
  local zone = raidInstance()
  if not zone then return end
  local player, link = parseLoot(msg)
  if not player or not link then return end
  local itemId = tonumber(string.match(link, "|Hitem:(%d+)"))
  if not itemId then return end
  local quality = itemQuality(link)
  if not quality or quality < ns.lootMin() then return end
  local item = string.match(link, "|h%[(.-)%]|h") or link
  local t = ns.now()
  -- Same item to the same player in the same second: one entry (dedupe key t:player:itemId).
  for i = #ns.db.loot, math.max(1, #ns.db.loot - 10), -1 do
    local l = ns.db.loot[i]
    if l and l.t == t and l.player == player and l.itemId == itemId then return end
  end
  if not active then snapshot(true) end
  table.insert(ns.db.loot, {
    t = t, player = player, itemId = itemId, item = item, quality = quality,
    zone = zone, raidKey = active and active.key or nil,
  })
  if ns.updateUI then ns.updateUI() end
end)

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

ns.on("PLAYER_ENTERING_WORLD", function() ns.after(3, "raidZone", checkZone) end)
ns.on("ZONE_CHANGED_NEW_AREA", function() ns.after(3, "raidZone", checkZone) end)
ns.on("GROUP_ROSTER_UPDATE", function() ns.after(5, "raidZone", checkZone) end)
ns.on("RAID_ROSTER_UPDATE", function() ns.after(5, "raidZone", checkZone) end)

ns.every(ns.config.raidSnapshotInterval, "raidSnapshot", function()
  snapshot(false)
  updateCombatLog()
end)
