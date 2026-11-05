-- GFoA Guild Sync: private personal stats for the logged-in character (dungeon runs, bosses, deaths, time per level,
-- quests and XP by source, gold by source, loot by quality, skill-ups, fishing, travel, sessions). Kept in the
-- per-character settings file (GFoAGuildSyncSettings.stats) and shown only in the "My stats" window.
-- Nothing leaves this PC unless the player turns on sharing (/gf stats share on, off by default): then a small
-- totals block without gold (L.sharedStats) is copied into this character's sheet in GFoAGuildSyncDB for the
-- guild Discord's fun leaderboards (docs/sync-format.md "Shared stats").
-- No combat log: everything comes from chat messages built from the client's own global strings, PLAYER_MONEY with
-- the open window as context, and a few plain events.
local _, ns = ...
local L = ns.logic

local lastMoney, lastTick
local money = { open = {}, closed = {}, at = {} }   -- context for L.moneySource
local xpState = { recent = {} }                      -- quest / exploration XP pairing for L.addXp
local patterns                                       -- built once from global strings

local HEARTHSTONE_SPELLS = { [8690] = true }
local BEST_XPH_MIN_SECONDS = 1800

local function G(name)
  local v = _G[name]
  if type(v) == "string" then return v end
  return nil
end

local function buildPatterns()
  patterns = {
    xp = L.xpPatterns(G),
    loot = L.selfLootPatterns(G),
    skill = L.formatPattern(G("SKILL_RANK_UP")),
  }
end

local function usable(msg)
  return type(msg) == "string" and not ns.isSecret(msg)
end

function ns.stats()
  if not ns.settings then return nil end
  local s = ns.settings.stats
  if type(s) ~= "table" then
    s = { since = ns.now() }
    ns.settings.stats = s
  end
  return s
end

function ns.statsSharing()
  return ns.opt("statsShare", false) and true or false
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

-- Copies the shared totals into this character's sheet (sharing on), or leaves a "sharing off" marker once so the
-- bot drops what it had. Never writes anything for a character that never shared.
function ns.writeSharedStats()
  local s = ns.stats()
  local c = ns.myChar and ns.myChar()
  if not s or not c then return end
  if ns.statsSharing() then
    c.sharedStats = L.sharedStats(s, ns.now(), ns.opt("statsShareGold", false))
  elseif type(c.sharedStats) == "table" and not c.sharedStats.off then
    c.sharedStats = L.sharedStatsOff(ns.now())
  end
end

local function tick()
  local s = ns.stats()
  if not s then return end
  local t = ns.now()
  local level = ns.call("UnitLevel", "player")
  if lastTick and not L.logoutGlitch(level, ns.call("UnitXPMax", "player")) then
    L.addLevelTime(s, level, t - lastTick, 120)
  end
  lastTick = t
  L.sessionTick(s, t)
  if ns.xpSession then
    local secs, _, perHour = ns.xpSession()
    L.bestRate(s, perHour, secs, t, BEST_XPH_MIN_SECONDS)
  end
end

ns.on("PLAYER_LOGIN", function()
  ns.stats()
  lastMoney = ns.call("GetMoney")
  lastTick = ns.now()
  buildPatterns()
  -- Repairs: the merchant window takes the money; this marks it as a repair (observing only, never calling it).
  if type(hooksecurefunc) == "function" and type(RepairAllItems) == "function" then
    pcall(hooksecurefunc, "RepairAllItems", function() money.at.repair = ns.now() end)
  end
end)

ns.on("PLAYER_ENTERING_WORLD", function(_, initial, reload)
  local s = ns.stats()
  if s then L.sessionEnter(s, ns.now(), initial, reload) end
end)

-- Window context for gold: open while shown, and a few seconds after closing (the money event can come late).
local WINDOWS = {
  merchant = { "MERCHANT_SHOW", "MERCHANT_CLOSED" },
  trainer = { "TRAINER_SHOW", "TRAINER_CLOSED" },
  taxi = { "TAXIMAP_OPENED", "TAXIMAP_CLOSED" },
  mail = { "MAIL_SHOW", "MAIL_CLOSED" },
  ah = { "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" },
  loot = { "LOOT_OPENED", "LOOT_CLOSED" },
}
for kind, ev in pairs(WINDOWS) do
  ns.on(ev[1], function()
    money.open[kind] = true
  end)
  ns.on(ev[2], function()
    money.open[kind] = nil
    money.closed[kind] = ns.now()
  end)
end

ns.on("CHAT_MSG_MONEY", function() money.at.loot = ns.now() end)

ns.on("PLAYER_MONEY", function()
  local s = ns.stats()
  local m = ns.call("GetMoney")
  if s and type(m) == "number" then
    money.repairMode = ns.call("InRepairMode") and true or false
    L.addMoneyBySource(s, lastMoney, m, money, ns.now())
    lastMoney = m
  end
end)

ns.on("QUEST_TURNED_IN", function(_, _, xpReward)
  local s = ns.stats()
  if not s then return end
  local t = ns.now()
  money.at.quest = t
  s.quests = (s.quests or 0) + 1
  if type(xpReward) == "number" and not ns.isSecret(xpReward) then L.addXp(s, xpState, "quest", xpReward, t) end
end)

ns.on("CHAT_MSG_COMBAT_XP_GAIN", function(_, msg)
  local s = ns.stats()
  if not s or not usable(msg) then return end
  if not patterns then buildPatterns() end
  local kind, amount = L.classifyXp(patterns.xp, msg)
  if kind then L.addXp(s, xpState, kind, amount, ns.now()) end
end)

ns.on("CHAT_MSG_SYSTEM", function(_, msg)
  local s = ns.stats()
  if not s or not usable(msg) then return end
  if not patterns then buildPatterns() end
  local amount = L.exploreXp(patterns.xp, msg)
  if amount then L.addXp(s, xpState, "explore", amount, ns.now()) end
end)

local function quality(link)
  local q
  if ns.api("C_Item.GetItemInfo") then q = select(3, ns.call("C_Item.GetItemInfo", link)) end
  if type(q) ~= "number" then q = select(3, ns.call("GetItemInfo", link)) end
  if type(q) == "number" then return q end
  return L.qualityFromLink(link)
end

ns.on("CHAT_MSG_LOOT", function(_, msg)
  local s = ns.stats()
  if not s or not usable(msg) then return end
  if not patterns then buildPatterns() end
  local link, count = L.parseSelfLoot(patterns.loot, msg)
  if not link then return end
  local item = L.itemName(link)
  local first = L.addLoot(s, quality(link), count, item, tonumber(string.match(link, "|Hitem:(%d+)")),
    ns.now(), ns.call("UnitLevel", "player"))
  if first then ns.print("first epic for this character: " .. tostring(item) .. "! (saved in /gf stats)") end
end)

ns.on("LOOT_OPENED", function()
  local s = ns.stats()
  if s and ns.call("IsFishingLoot") then s.fish = (s.fish or 0) + 1 end
end)

ns.on("CHAT_MSG_SKILL", function(_, msg)
  local s = ns.stats()
  if not s or not usable(msg) then return end
  if not patterns then buildPatterns() end
  local prof = L.parseSkillUp(patterns.skill, msg)
  if prof then L.addSkillUp(s, prof) end
end)

ns.on("PLAYER_DEAD", function()
  local s = ns.stats()
  if s then
    L.addDeath(s, ns.call("GetRealZoneText") or ns.call("GetZoneText"), ns.call("UnitLevel", "player"))
  end
end)

local hearthName
ns.on("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellId)
  if unit ~= "player" or ns.isSecret(spellId) then return end
  local s = ns.stats()
  if not s then return end
  local hit = HEARTHSTONE_SPELLS[spellId]
  if not hit and type(spellId) == "number" then
    hearthName = hearthName or ns.call("C_Spell.GetSpellName", 8690) or ns.call("GetSpellInfo", 8690)
    local name = ns.call("C_Spell.GetSpellName", spellId) or ns.call("GetSpellInfo", spellId)
    hit = hearthName ~= nil and name == hearthName
  end
  if hit then s.hearths = (s.hearths or 0) + 1 end
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

ns.on("PLAYER_LOGOUT", function()
  tick()
  ns.writeSharedStats()
end)
ns.every(60, "stats", function()
  tick()
  ns.writeSharedStats()
end)

-- ---------------------------------------------------------------------------
-- "My stats" window
-- ---------------------------------------------------------------------------

local QUALITY_FALLBACK = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom" }

local function qualityLabel(q)
  local label = _G["ITEM_QUALITY" .. q .. "_DESC"] or QUALITY_FALLBACK[q] or tostring(q)
  local c = type(ITEM_QUALITY_COLORS) == "table" and ITEM_QUALITY_COLORS[q]
  if type(c) == "table" and c.hex then return c.hex .. tostring(label) .. "|r" end
  return tostring(label)
end

local function n(v) return math.floor(tonumber(v) or 0) end

local function header(text, extra)
  if ns.ui and ns.ui.headerLine then return ns.ui.headerLine(text, extra) end
  return text .. (extra and (" " .. extra) or "")
end

local function muted(text)
  return ((ns.ui and ns.ui.MUTED) or "") .. text .. ((ns.ui and ns.ui.MUTED) and "|r" or "")
end

local function moneyBreakdown(lines, map, keys)
  local parts = {}
  for _, k in ipairs(keys) do
    if (map and map[k] or 0) > 0 then
      table.insert(parts, L.MONEY_LABELS[k] .. " " .. L.formatMoney(map[k]))
    end
  end
  if #parts == 0 then return end
  -- Two per line keeps the 380 px window readable.
  for i = 1, #parts, 2 do
    table.insert(lines, "    " .. parts[i] .. (parts[i + 1] and ("   " .. parts[i + 1]) or ""))
  end
end

function ns.statsLines()
  local s = ns.stats()
  if not s then return { "Not loaded yet." } end
  tick()
  local lines = {}
  local function add(text) table.insert(lines, text) end
  add(muted(L.shareStatusText(ns.statsSharing(), ns.opt("statsShareGold", false))))
  add(string.format("Since %s   Sessions: %d   Longest: %s",
    date and date("%Y-%m-%d", s.since or 0) or tostring(s.since), n(s.sessions),
    L.formatDuration(n(s.longestSession))))

  add("")
  add(header("Questing and XP"))
  local xp = s.xp or {}
  add(string.format("    Quests turned in: %d   Mobs killed (gave XP): %d", n(s.quests), n(s.kills)))
  add(string.format("    XP from quests %s, kills %s", L.shortNumber(n(xp.quest)), L.shortNumber(n(xp.kill))))
  add(string.format("    XP from exploring %s, other %s", L.shortNumber(n(xp.explore)), L.shortNumber(n(xp.other))))
  if type(s.bestXph) == "table" then
    add(string.format("    Best session: %s XP/hour over %s%s", L.shortNumber(n(s.bestXph.rate)),
      L.formatDuration(n(s.bestXph.secs)), (date and s.bestXph.t) and (" (" .. date("%Y-%m-%d", s.bestXph.t) .. ")") or ""))
  end

  add("")
  add(header("Gold"))
  add("    Earned: " .. L.formatMoney(s.goldEarned or 0))
  moneyBreakdown(lines, s.income, L.INCOME_SOURCES)
  add("    Spent: " .. L.formatMoney(s.goldSpent or 0))
  moneyBreakdown(lines, s.spend, L.SPEND_SOURCES)

  add("")
  add(header("Loot and professions"))
  local loot = {}
  for q = 0, 7 do
    if n(s.loot and s.loot[q]) > 0 then table.insert(loot, qualityLabel(q) .. " " .. n(s.loot[q])) end
  end
  add("    Looted: " .. (#loot > 0 and table.concat(loot, ", ") or "nothing yet"))
  if type(s.firstEpic) == "table" then
    add(string.format("    First epic: %s%s", tostring(s.firstEpic.item or "?"),
      (date and s.firstEpic.t) and (" (" .. date("%Y-%m-%d", s.firstEpic.t) .. ")") or ""))
  end
  local skills = L.topCounts(s.skillUps, 6)
  if #skills > 0 then
    local parts = {}
    for _, e in ipairs(skills) do table.insert(parts, e.key .. " " .. e.n) end
    add("    Skill-ups: " .. table.concat(parts, ", "))
  end
  add(string.format("    Fish caught: %d", n(s.fish)))

  add("")
  add(header("Dungeons, deaths and travel"))
  add(string.format("    Dungeon runs: %d   Bosses killed: %d", n(s.dungeons), n(s.bosses)))
  add(string.format("    Deaths: %d   Flights: %d   Hearthstones: %d", n(s.deaths), n(s.flights), n(s.hearths)))
  local zones = L.topCounts(s.deathsByZone, 4)
  for _, e in ipairs(zones) do add(string.format("        %s: %d", tostring(e.key), e.n)) end
  local byLevel = L.topCounts(s.deathsByLevel, 3)
  if #byLevel > 0 then
    local parts = {}
    for _, e in ipairs(byLevel) do table.insert(parts, "level " .. tostring(e.key) .. " x" .. e.n) end
    add("        Worst levels: " .. table.concat(parts, ", "))
  end

  add("")
  add(header("Time per level", "(played with the addon on, or from /played)"))
  local levels = {}
  for lvl in pairs(s.levelTime or {}) do table.insert(levels, lvl) end
  table.sort(levels, function(a, b) return a > b end)
  for _, lvl in ipairs(levels) do
    add(string.format("    Level %d: %s", lvl, L.formatDuration(s.levelTime[lvl])))
  end
  if #levels == 0 then add("    nothing yet") end
  return lines
end

-- /gf stats [share on|off | share gold on|off]
local function shareCommand(rest)
  rest = string.lower(rest or "")
  local gold, val = string.match(rest, "^(gold)%s*(%a*)$")
  if gold then
    if val == "on" or val == "off" then ns.setOpt("statsShareGold", val == "on") end
    ns.print("shared stats include gold earned: " .. (ns.opt("statsShareGold", false) and "on" or "off")
      .. " (usage: /gf stats share gold on|off)")
  elseif rest == "on" or rest == "off" then
    ns.setStatsSharing(rest == "on")
  end
  ns.print("stats sharing: " .. (ns.statsSharing() and "on" or "off")
    .. ". When on, your totals (quests, deaths, dungeons, flights, first epic...; no gold) go to the guild Discord"
    .. " for fun leaderboards after your next logout. Usage: /gf stats share on|off")
end

-- Turns sharing on or off for this character (also used by the Options checkbox).
function ns.setStatsSharing(on)
  ns.setOpt("statsShare", on and true or false)
  ns.writeSharedStats()
  if ns.sendSync then ns.sendSync("stats") end
end

ns.commands["stats"] = function(arg)
  local cmd, rest = string.match(arg or "", "^(%S*)%s*(.-)$")
  if string.lower(cmd or "") == "share" then
    shareCommand(rest)
  elseif ns.toggleStats then
    ns.toggleStats()
  end
end
