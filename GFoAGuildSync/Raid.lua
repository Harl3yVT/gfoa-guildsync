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
local function raidInstance()
  local inInstance, instanceType = ns.call("IsInInstance")
  if not inInstance or instanceType ~= "raid" then return nil end
  local name, _, _, _, maxPlayers, _, _, instanceId = ns.call("GetInstanceInfo")
  if not name then name = ns.call("GetRealZoneText") or ns.call("GetZoneText") end
  return name, instanceId, maxPlayers
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
    if name and online ~= false then
      table.insert(out, ns.shortName(name))
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

local function updateCombatLog()
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
  table.insert(active.kills, {
    t = t,
    encounterId = id,
    name = name,
    success = success and true or false,
    duration = duration,
    members = raidMembers(),
    deaths = deaths or {},
  })
  if success then lastKill[id or name or "?"] = t end
end

ns.on("ENCOUNTER_START", function(_, id, name)
  encounter = { id = id, name = name, start = ns.now(), deaths = {} }
  snapshot(true)
end)

ns.on("ENCOUNTER_END", function(_, id, name, _, _, success)
  local e = encounter
  encounter = nil
  local start = e and e.start
  local deaths = e and e.deaths or {}
  recordKill(id, name, success == 1 or success == true, start and (ns.now() - start) or nil, deaths)
end)

-- Fallback for clients that only fire BOSS_KILL.
ns.on("BOSS_KILL", function(_, id, name)
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

ns.on("COMBAT_LOG_EVENT_UNFILTERED", function(_, ...)
  if not active then return end
  local _, sub, _, _, _, _, _, destGUID, destName, destFlags
  if ns.api("CombatLogGetCurrentEventInfo") then
    _, sub, _, _, _, _, _, destGUID, destName, destFlags = CombatLogGetCurrentEventInfo()
  else
    _, sub, _, _, _, _, _, destGUID, destName, destFlags = ...
  end
  if sub ~= "UNIT_DIED" or not isGroupPlayer(destGUID, destFlags) then return end
  local name = ns.shortName(destName)
  if not name then return end
  local bucket = (encounter and encounter.deaths) or (combat and combat.deaths)
  if bucket then table.insert(bucket, name) end
end)
ns.unregister("COMBAT_LOG_EVENT_UNFILTERED")   -- only listened to inside raid instances

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
  if type(msg) ~= "string" then return end
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
