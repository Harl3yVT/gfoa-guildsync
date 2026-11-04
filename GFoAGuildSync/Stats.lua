-- GFoA Guild Sync: private personal stats for the logged-in character (dungeon runs, bosses, deaths, time per level,
-- gold earned and spent). Kept in the per-character settings file (GFoAGuildSyncSettings.stats): never in
-- GFoAGuildSyncDB, never in the export or guild sync, never sent anywhere. Shown only in the "My stats" window.
local _, ns = ...
local L = ns.logic

local lastMoney, lastTick

function ns.stats()
  if not ns.settings then return nil end
  local s = ns.settings.stats
  if type(s) ~= "table" then
    s = { since = ns.now() }
    ns.settings.stats = s
  end
  return s
end

-- Called by Dungeon.lua when a new run starts.
function ns.statsNewRun()
  local s = ns.stats()
  if s then s.dungeons = (s.dungeons or 0) + 1 end
end

-- Called by Dungeon.lua when a boss in a run dies.
function ns.statsBoss()
  local s = ns.stats()
  if s then s.bosses = (s.bosses or 0) + 1 end
end

local function tick()
  local s = ns.stats()
  if not s then return end
  local t = ns.now()
  if lastTick then L.addLevelTime(s, ns.call("UnitLevel", "player"), t - lastTick, 120) end
  lastTick = t
end

ns.on("PLAYER_LOGIN", function()
  ns.stats()
  lastMoney = ns.call("GetMoney")
  lastTick = ns.now()
end)

ns.on("PLAYER_MONEY", function()
  local s = ns.stats()
  local money = ns.call("GetMoney")
  if s and type(money) == "number" then
    L.addMoney(s, lastMoney, money)
    lastMoney = money
  end
end)

ns.on("PLAYER_DEAD", function()
  local s = ns.stats()
  if s then s.deaths = (s.deaths or 0) + 1 end
end)

ns.on("PLAYER_LEVEL_UP", function(_, level)
  tick()
  local s = ns.stats()
  level = tonumber(level)
  if s and level then
    s.levelReached = s.levelReached or {}
    s.levelReached[level] = ns.now()
  end
end)

-- /played (typed by the player; the addon never asks) gives the exact time at this level: keep the larger value.
ns.on("TIME_PLAYED_MSG", function(_, _, thisLevel)
  local s = ns.stats()
  local level = ns.call("UnitLevel", "player")
  if s and type(thisLevel) == "number" and type(level) == "number" then
    s.levelTime = s.levelTime or {}
    if thisLevel > (s.levelTime[level] or 0) then s.levelTime[level] = math.floor(thisLevel) end
  end
end)

ns.on("PLAYER_LOGOUT", tick)
ns.every(60, "stats", tick)

-- Lines for the "My stats" window.
function ns.statsLines()
  local s = ns.stats()
  if not s then return { "Not loaded yet." } end
  tick()
  local lines = {
    "|cff999999Only on this PC, never sent to the guild or Discord.|r",
    string.format("Since %s", date and date("%Y-%m-%d", s.since or 0) or tostring(s.since)),
    string.format("Dungeon runs: %d   Bosses killed: %d", s.dungeons or 0, s.bosses or 0),
    string.format("Deaths: %d", s.deaths or 0),
    string.format("Gold earned: %s", L.formatMoney(s.goldEarned or 0)),
    string.format("Gold spent: %s", L.formatMoney(s.goldSpent or 0)),
    "",
    "Time per level (played while the addon was on, or from /played):",
  }
  local levels = {}
  for lvl in pairs(s.levelTime or {}) do table.insert(levels, lvl) end
  table.sort(levels, function(a, b) return a > b end)
  for _, lvl in ipairs(levels) do
    table.insert(lines, string.format("    Level %d: %s", lvl, L.formatDuration(s.levelTime[lvl])))
  end
  if #levels == 0 then table.insert(lines, "    nothing yet") end
  return lines
end

ns.commands["stats"] = function() if ns.toggleStats then ns.toggleStats() end end
