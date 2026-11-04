-- GFoA Guild Sync: 5-man dungeon runs (party instances) -> db.dungeons.
-- Data only: nothing is announced.
local _, ns = ...
local L = ns.logic

local current      -- the run table we're in (an entry of db.dungeons), or nil
local kills = {}   -- encounter id/name -> time counted (ENCOUNTER_END + BOSS_KILL dedupe)

-- zone, instanceId when inside a party instance, else nil.
local function partyInstance()
  local inInstance, instanceType = ns.call("IsInInstance")
  if not inInstance or instanceType ~= "party" then return nil end
  local name, _, _, _, _, _, _, instanceId = ns.call("GetInstanceInfo")
  if not name then name = ns.call("GetRealZoneText") or ns.call("GetZoneText") end
  if not name then return nil end
  return name, instanceId or 0
end

local function partyMembers()
  local out = {}
  local me = ns.call("UnitName", "player")
  if me then table.insert(out, me) end
  for i = 1, 4 do
    local unit = "party" .. i
    if ns.call("UnitExists", unit) then
      local name, realm = ns.call("UnitName", unit)
      if type(name) == "string" and name ~= "" and name ~= UNKNOWNOBJECT then
        local full = (type(realm) == "string" and realm ~= "") and (name .. "-" .. realm) or name
        table.insert(out, ns.shortName(full))
      end
    end
  end
  return out
end

function ns.currentDungeon()
  return current
end

local function check()
  local zone, instanceId = partyInstance()
  if not zone then
    current = nil
    return
  end
  local db = ns.db
  local t = ns.now()
  local me = ns.call("UnitName", "player")
  if not me then return end
  if not current or current.instanceId ~= instanceId or current.character ~= me then
    if type(db.dungeons) ~= "table" then db.dungeons = {} end
    local idx = L.findRun(db.dungeons, instanceId, zone, me, t, ns.config.dungeonRunGap)
    if idx then
      current = db.dungeons[idx]
    else
      current = L.newRun(t, zone, instanceId, me, ns.call("UnitLevel", "player"))
      table.insert(db.dungeons, current)
      if ns.statsNewRun then ns.statsNewRun() end
    end
  end
  current.last = t
  current.members = current.members or {}
  L.mergeNames(current.members, partyMembers())
  if ns.updateUI then ns.updateUI() end
end

local function bossKilled(id, name)
  check()
  if not current then return end
  if not L.newKill(kills, id or name, ns.now(), 30) then return end
  current.bossesKilled = (current.bossesKilled or 0) + 1
  if ns.statsBoss then ns.statsBoss() end
  if ns.updateDungeonList then ns.updateDungeonList() end
end

ns.on("ENCOUNTER_END", function(_, id, name, _, _, success)
  if success == 1 or success == true then bossKilled(id, name) end
end)
ns.on("BOSS_KILL", function(_, id, name) bossKilled(id, name) end)

ns.on("PLAYER_ENTERING_WORLD", function() ns.after(3, "dungeonZone", check) end)
ns.on("ZONE_CHANGED_NEW_AREA", function() ns.after(3, "dungeonZone", check) end)
ns.on("GROUP_ROSTER_UPDATE", function() ns.after(5, "dungeonZone", check) end)
ns.on("PARTY_MEMBERS_CHANGED", function() ns.after(5, "dungeonZone", check) end)
ns.every(60, "dungeon", check)
