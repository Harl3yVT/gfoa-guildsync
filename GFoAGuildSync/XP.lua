-- GFoA Guild Sync: XP/hour over the play session and the estimated time to level 60.
-- Writes xpPerHour, xpSessionSeconds and restedXp to the character sheet.
local _, ns = ...
local L = ns.logic

local session   -- { start, gained, lastSeen, level, xp, max } (kept in settings so a /reload continues it)

local function readXP()
  local level = ns.call("UnitLevel", "player")
  local xp, max = ns.call("UnitXP", "player"), ns.call("UnitXPMax", "player")
  if type(level) ~= "number" or type(xp) ~= "number" or type(max) ~= "number" then return nil end
  return level, xp, max
end

local function startSession()
  local t = ns.now()
  local saved = ns.settings.xpSession
  if type(saved) == "table" and type(saved.start) == "number" and type(saved.lastSeen) == "number"
      and t - saved.lastSeen <= ns.config.xpSessionResume and t >= saved.start then
    session = saved
  else
    session = { start = t, gained = 0, lastSeen = t }
    ns.settings.xpSession = session
  end
end

-- Seconds, gained XP and XP/hour (nil before the minimum sample length) of this session.
function ns.xpSession()
  if not session then return nil end
  local secs = ns.now() - session.start
  return secs, session.gained or 0, L.xpPerHour(session.gained or 0, secs, ns.config.xpMinSessionSeconds)
end

local function write()
  if not session then return end
  local c = ns.myChar and ns.myChar()
  if not c then return end
  local rested = ns.call("GetXPExhaustion")
  c.restedXp = type(rested) == "number" and math.floor(rested) or 0
  local level = ns.call("UnitLevel", "player")
  if type(level) == "number" and level >= L.MAX_LEVEL then
    c.xpPerHour, c.xpSessionSeconds = nil, nil
    return
  end
  local secs, _, perHour = ns.xpSession()
  if perHour then
    c.xpPerHour = perHour
    c.xpSessionSeconds = secs
  end
end

local function sample()
  if not session then startSession() end
  local level, xp, max = readXP()
  if not level then return end
  if session.level then
    local g = L.xpGained(session.level, session.xp, session.max, level, xp)
    if g > 0 then session.gained = (session.gained or 0) + g end
  end
  session.level, session.xp, session.max = level, xp, max
  session.lastSeen = ns.now()
  write()
  if ns.updateUI then ns.updateUI() end
end

-- One line for /gfoa and the status window.
function ns.xpStatusLine()
  if not session then return "XP/hour: starting" end
  local level, xp, max = readXP()
  if level and level >= L.MAX_LEVEL then return "XP: level " .. L.MAX_LEVEL end
  local secs, gained, perHour = ns.xpSession()
  local rested = ns.call("GetXPExhaustion")
  local restedText = (type(rested) == "number" and rested > 0) and ("  rested " .. L.shortNumber(rested)) or ""
  if not perHour then
    return string.format("XP/hour: measuring (%d/%d min, +%s)%s", math.floor(secs / 60),
      math.floor(ns.config.xpMinSessionSeconds / 60), L.shortNumber(gained), restedText)
  end
  local eta = L.etaSeconds(level, xp, max, perHour)
  local nextEta = L.etaNextLevel(level, xp, max, perHour)
  return string.format("XP/hour: %s (%s)  next level in %s  60 in %s%s", L.shortNumber(perHour),
    L.formatDuration(secs), nextEta and L.formatDuration(nextEta) or "?", eta and L.formatDuration(eta) or "?",
    restedText)
end

-- Levelling buddy lines (Levelling window): this character's progress, rates and rested XP.
function ns.levellingLines()
  local level, xp, max = readXP()
  if not level then return { "Level data not available yet." } end
  if level >= L.MAX_LEVEL then return { "Level " .. L.MAX_LEVEL .. ": nothing left to level. Nice!" } end
  local lines = {
    string.format("Level %d  %s / %s XP (%.1f%%)", level, L.shortNumber(xp), L.shortNumber(max),
      max > 0 and xp * 100 / max or 0),
  }
  local secs, gained, perHour = ns.xpSession()
  if perHour then
    local nextEta = L.etaNextLevel(level, xp, max, perHour)
    local eta = L.etaSeconds(level, xp, max, perHour)
    table.insert(lines, string.format("XP/hour: %s  (this session: +%s in %s)", L.shortNumber(perHour),
      L.shortNumber(gained), L.formatDuration(secs)))
    table.insert(lines, "Next level in: " .. (nextEta and L.formatDuration(nextEta) or "?"))
    table.insert(lines, "Level 60 in: " .. (eta and L.formatDuration(eta) or "?") .. " of play at this rate")
  else
    table.insert(lines, string.format("XP/hour: measuring (%d of %d min, +%s so far)", math.floor((secs or 0) / 60),
      math.floor(ns.config.xpMinSessionSeconds / 60), L.shortNumber(gained or 0)))
  end
  local rested = ns.call("GetXPExhaustion")
  if type(rested) == "number" and rested > 0 then
    table.insert(lines, string.format("Rested: %s XP (%d%% of this level)", L.shortNumber(rested),
      L.restedPercent(rested, max)))
  else
    table.insert(lines, "Rested: none (log out in an inn or city to build it up)")
  end
  table.insert(lines, string.format("XP to 60: %s", L.shortNumber(L.xpToMax(level, xp, max))))
  return lines
end

ns.commands["xp"] = function() ns.print(ns.xpStatusLine()) end

ns.on("PLAYER_LOGIN", function()
  startSession()
  ns.after(6, "xpFirst", sample)
end)
ns.on("PLAYER_XP_UPDATE", function() sample() end)
-- UnitLevel may still be the old level when PLAYER_LEVEL_UP fires: sample a moment later.
ns.on("PLAYER_LEVEL_UP", function() ns.after(1, "xpLevel", sample) end)
ns.on("UPDATE_EXHAUSTION", function() write() end)
ns.on("PLAYER_LOGOUT", function() sample() end)
ns.every(60, "xp", sample)
