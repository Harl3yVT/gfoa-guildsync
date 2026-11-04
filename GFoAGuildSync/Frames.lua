-- GFoA Guild Sync: small info windows. All are opt-in (opened by the player from the minimap menu, status window,
-- options page or a /gfoa command) and only show information; nothing pops up by itself.
--   Profession cooldowns (yours + guildmates who share theirs), Attunements + pre-raid checklist, Dungeon runs,
--   Levelling (levelling buddy + guild race to 60), Guildie finder, My stats (private), My characters (Discord link).
local _, ns = ...
local L = ns.logic

local function sortedCharacters()
  local names = {}
  for name, c in pairs(ns.db and ns.db.characters or {}) do
    if type(c) == "table" then table.insert(names, name) end
  end
  table.sort(names)
  return names
end

local function charLabel(name, c)
  return ns.ui.classColor(c.class) .. name .. "|r |cffaaaaaa" .. tostring(c.level or "?") .. "|r"
end

-- One window = title + scrolling text list + a function that builds its lines.
-- setup(frame, win) may add buttons along the top and returns how many pixels they take (the list starts below).
-- onOpen() runs each time the player opens the window.
local function makeListWindow(name, title, width, rows, posKey, build, tick, setup, onOpen)
  local win = { frame = nil }
  function win.refresh()
    if not win.frame or not win.frame:IsShown() then return end
    local ok, lines = pcall(build)
    win.list:SetLines(ok and lines or { "|cffff6666" .. tostring(lines) .. "|r" })
  end
  function win.toggle(show)
    if not win.frame then
      local top = 0
      local f = ns.ui.window(name, title, width, 44 + rows * 14 + (setup and 26 or 0), posKey)
      win.frame = f
      if setup then top = setup(f, win) or 26 end
      local list = ns.ui.textList(f, rows, 14)
      list:SetPoint("TOPLEFT", 12, -30 - top)
      list:SetPoint("BOTTOMRIGHT", -12, 10)
      win.list = list
      f:SetScript("OnShow", win.refresh)
      if tick then
        local acc = 0
        f:SetScript("OnUpdate", function(_, elapsed)
          acc = acc + (elapsed or 0)
          if acc >= tick then
            acc = 0
            win.refresh()
          end
        end)
      end
    end
    if show == nil then show = not win.frame:IsShown() end
    if show then
      win.frame:Show()
      if onOpen then ns.safe("windowOpen", onOpen) end
      win.refresh()
    else
      win.frame:Hide()
    end
  end
  return win
end

local function cdText(readyAt, t)
  local left = (type(readyAt) == "number") and (readyAt - t) or 0
  return left > 0 and ("|cffffcc00" .. L.formatDuration(left) .. "|r") or "|cff44ff44ready|r"
end

-- ---------------------------------------------------------------------------
-- Profession cooldowns: your characters, then guildmates whose addons shared theirs (logged-in character only)
-- ---------------------------------------------------------------------------

local cooldowns = makeListWindow("GFoAGuildSyncCooldownFrame", "Profession cooldowns", 360, 18, "cooldownPos",
  function()
    local lines, t = {}, ns.now()
    local known = ns.cache and ns.cache.cdNames
    table.insert(lines, "|cffd38cffYour characters|r")
    local any = false
    for _, name in ipairs(sortedCharacters()) do
      local c = ns.db.characters[name]
      local state = L.cooldownState(c, t, known)
      if #state > 0 then
        any = true
        table.insert(lines, charLabel(name, c))
        for _, e in ipairs(state) do table.insert(lines, "    " .. e.name .. ": " .. cdText(e.readyAt, t)) end
      end
    end
    if not any then
      table.insert(lines, "    None saved. Open a profession window on each crafter (e.g. Tailoring for Mooncloth).")
    end
    table.insert(lines, "")
    table.insert(lines, "|cffd38cffGuild: ready now first|r")
    local ready, waiting = {}, {}
    for _, peer in ipairs(ns.peerCooldowns and ns.peerCooldowns() or {}) do
      for _, e in ipairs(peer.list) do
        local row = { who = peer.name, name = e.name, readyAt = e.readyAt, heard = peer.t }
        if (e.readyAt or 0) <= t then table.insert(ready, row) else table.insert(waiting, row) end
      end
    end
    table.sort(ready, function(a, b) return a.name .. a.who < b.name .. b.who end)
    table.sort(waiting, function(a, b) return (a.readyAt or 0) < (b.readyAt or 0) end)
    for _, list in ipairs({ ready, waiting }) do
      for _, r in ipairs(list) do
        table.insert(lines, string.format("    %s: %s  %s  |cff777777(heard %s)|r", r.who, r.name, cdText(r.readyAt, t),
          ns.ago(r.heard)))
      end
    end
    if #ready + #waiting == 0 then
      table.insert(lines, "    Nobody has shared cooldowns yet (guildmates need this addon and to be online).")
    end
    return lines
  end, 1, nil, function() if ns.queryCooldowns then ns.queryCooldowns() end end)

function ns.toggleCooldowns(show) cooldowns.toggle(show) end
function ns.refreshCooldowns() cooldowns.refresh() end

-- ---------------------------------------------------------------------------
-- Attunements (configured quest flags) + pre-raid checklist for this character. Item counts are read only while
-- the window is open.
-- ---------------------------------------------------------------------------

local function itemCount(id)
  if not ns.api("GetItemCount") then return nil end
  local n = ns.call("GetItemCount", id, true)
  if type(n) == "number" then return n end
  return nil
end

local attunements = makeListWindow("GFoAGuildSyncAttuneFrame", "Attunements and pre-raid checklist", 420, 20,
  "attunePos", function()
    local lines = {}
    for _, name in ipairs(sortedCharacters()) do
      local c = ns.db.characters[name]
      local parts = {}
      for _, a in ipairs(ns.config.attunements or {}) do
        local done = type(c.attunements) == "table" and c.attunements[a.name]
        table.insert(parts, (done and ns.CHECK or ns.CROSS) .. " " .. a.name)
      end
      table.insert(lines, charLabel(name, c) .. "  " .. table.concat(parts, "  "))
    end
    if #lines == 0 then lines = { "No characters saved yet." } end
    table.insert(lines, "|cff999999Attunements update when each character logs in.|r")
    table.insert(lines, "")
    local c = ns.myChar and ns.myChar()
    local me = ns.call("UnitName", "player") or "this character"
    table.insert(lines, "|cffd38cffPre-raid checklist: " .. me .. "|r")
    for _, row in ipairs(L.checklist(c, ns.config, itemCount)) do
      local mark = row.unknown and "|cff999999?|r" or (row.done and ns.CHECK or ns.CROSS)
      table.insert(lines, "    " .. mark .. " " .. row.text)
    end
    table.insert(lines, "|cff999999Items count in your bags and bank (open the bank once).|r")
    return lines
  end, 5)

function ns.toggleAttunements(show) attunements.toggle(show) end

-- ---------------------------------------------------------------------------
-- Dungeon runs (db.dungeons, newest first)
-- ---------------------------------------------------------------------------

local dungeons = makeListWindow("GFoAGuildSyncDungeonFrame", "Dungeon runs (21 days)", 420, 16, "dungeonPos",
  function()
    local lines = {}
    local runs = ns.db.dungeons or {}
    for i = #runs, 1, -1 do
      local r = runs[i]
      if type(r) == "table" then
        local when = date and date("%m-%d %H:%M", r.start or 0) or tostring(r.start)
        table.insert(lines, string.format("%s  %s  |cffaaaaaa%s %s|r  %d boss%s  %s  %d in group", when,
          tostring(r.zone), tostring(r.character), tostring(r.levelAtStart or "?"), r.bossesKilled or 0,
          (r.bossesKilled == 1) and "" or "es", L.formatDuration((r.last or r.start or 0) - (r.start or 0)),
          type(r.members) == "table" and #r.members or 0))
      end
    end
    if #lines == 0 then lines = { "No dungeon runs saved yet." } end
    return lines
  end, 5)

function ns.toggleDungeons(show) dungeons.toggle(show) end
function ns.updateDungeonList() dungeons.refresh() end

-- ---------------------------------------------------------------------------
-- Levelling: levelling buddy for this character + the guild's race to 60 (from the roster scans on this PC)
-- ---------------------------------------------------------------------------

local levelling = makeListWindow("GFoAGuildSyncLevelFrame", "Levelling", 400, 24, "levelPos", function()
  local lines = {}
  for _, l in ipairs(ns.levellingLines and ns.levellingLines() or {}) do table.insert(lines, l) end
  table.insert(lines, "")
  table.insert(lines, "|cffd38cffGuild race to 60|r |cff999999(+N = levels in the last 7 days)|r")
  local g = ns.db and ns.db.guild
  local race = L.raceTo60(g and g.members or {}, ns.cache and ns.cache.levelHistory, math.floor(ns.now() / 86400), 15)
  local discord = ns.discordData()
  for i, r in ipairs(race) do
    local m = r.member
    local alt = L.altOf(discord, m.name)
    table.insert(lines, string.format("%2d. %s%s|r %d%s%s%s", i, ns.ui.classColor(m.class), m.name or "?", m.level,
      r.gain > 0 and ("  |cff44ff44+" .. r.gain .. "|r") or "", m.online and "  |cff44ff44online|r" or "",
      alt and ("  |cff999999" .. alt .. "'s alt|r") or ""))
  end
  if #race == 0 then table.insert(lines, "    No roster scan yet (open the guild window or wait a minute).") end
  return lines
end, 5)

function ns.toggleLevelling(show) levelling.toggle(show) end

-- ---------------------------------------------------------------------------
-- Guildie finder: online guild members within +-3 levels, filter by class / role
-- ---------------------------------------------------------------------------

local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local ROLES = { "Tank", "Healer", "DPS" }
local finderFilter = {}

local finder
finder = makeListWindow("GFoAGuildSyncFinderFrame", "Guildie finder", 400, 18, "finderPos", function()
  local myLevel = ns.call("UnitLevel", "player")
  local range = ns.config.finderRange or 3
  local g = ns.db and ns.db.guild
  local discord = ns.discordData()
  local list = L.finder(g and g.members or {}, myLevel, range, finderFilter, discord, ns.call("UnitName", "player"))
  local lines = { string.format("|cff999999Online now, level %s +-%d, from the last roster scan (%s).|r",
    tostring(myLevel or "?"), range, ns.ago(g and g.updated)) }
  for _, m in ipairs(list) do
    local role = L.roleOf(discord, m.name)
    table.insert(lines, string.format("%s%s|r %d %s%s  |cffaaaaaa%s|r", ns.ui.classColor(m.class), m.name or "?",
      m.level, ns.ui.className(m.class), role and (" - " .. role) or "", m.zone or ""))
  end
  if #list == 0 then table.insert(lines, "Nobody in range right now.") end
  return lines
end, 10, function(f, win)
  local W = ns.ui
  local classBtn, roleBtn
  classBtn = W.button(f, "Class: all", 100, 20, function()
    local items = { { text = "All classes", func = function()
      finderFilter.class = nil
      classBtn:SetText("Class: all")
      win.refresh()
    end } }
    for _, cls in ipairs(CLASSES) do
      table.insert(items, { text = W.classColor(cls) .. W.className(cls) .. "|r", func = function()
        finderFilter.class = cls
        classBtn:SetText(W.className(cls))
        win.refresh()
      end })
    end
    W.popup(classBtn, items)
  end)
  classBtn:SetPoint("TOPLEFT", 12, -28)
  roleBtn = W.button(f, "Role: all", 100, 20, function()
    local items = { { text = "All roles", func = function()
      finderFilter.role = nil
      roleBtn:SetText("Role: all")
      win.refresh()
    end } }
    for _, role in ipairs(ROLES) do
      table.insert(items, { text = role, func = function()
        finderFilter.role = role
        roleBtn:SetText(role)
        win.refresh()
      end })
    end
    W.popup(roleBtn, items)
  end)
  roleBtn:SetPoint("LEFT", classBtn, "RIGHT", 6, 0)
  local rescan = W.button(f, "Rescan", 70, 20, function() if ns.refreshRoster then ns.refreshRoster(true) end end)
  rescan:SetPoint("TOPRIGHT", -30, -28)
  return 26
end)

function ns.toggleFinder(show) finder.toggle(show) end

-- ---------------------------------------------------------------------------
-- My stats (private, this character only)
-- ---------------------------------------------------------------------------

local statsWin = makeListWindow("GFoAGuildSyncStatsFrame", "My stats (private)", 380, 18, "statsPos", function()
  return ns.statsLines and ns.statsLines() or { "Not loaded." }
end, 30)

function ns.toggleStats(show) statsWin.toggle(show) end

-- ---------------------------------------------------------------------------
-- My characters: Discord link status per character, with "Show import code", options and minimap toggles
-- ---------------------------------------------------------------------------

local chars = makeListWindow("GFoAGuildSyncCharsFrame", "My characters", 420, 14, "charsPos", function()
  local discord = ns.discordData()
  local lines = {}
  for _, name in ipairs(sortedCharacters()) do
    local c = ns.db.characters[name]
    local status, main = L.linkStatus(discord, name)
    local text
    if status == "main" then
      text = ns.CHECK .. " linked on Discord (main)"
    elseif status == "alt" then
      text = ns.CHECK .. " linked on Discord (" .. main .. "'s alt)"
    elseif status == "unlinked" then
      text = ns.CROSS .. " not linked yet: Show import code, then paste it in Discord"
    else
      text = "|cff999999? no Discord data on this PC yet|r"
    end
    table.insert(lines, charLabel(name, c) .. "  " .. text)
  end
  if #lines == 0 then lines = { "No characters saved yet." } end
  table.insert(lines, "")
  table.insert(lines, "|cff999999Discord data from " .. (discord and ns.ago(discord.generated) or "never")
    .. ". Link status comes from the guild Discord file; it never changes anything there.|r")
  return lines
end, nil, function(f, win)
  local W = ns.ui
  local code = W.button(f, "Show import code", 120, 20, function() ns.showExport() end)
  code:SetPoint("TOPLEFT", 12, -28)
  local opts = W.button(f, "Options", 70, 20, function() ns.openOptions() end)
  opts:SetPoint("LEFT", code, "RIGHT", 6, 0)
  local mm
  mm = W.button(f, "Minimap button", 110, 20, function()
    ns.toggleMinimap()
    win.refresh()
  end)
  mm:SetPoint("LEFT", opts, "RIGHT", 6, 0)
  return 26
end)

function ns.toggleCharacters(show) chars.toggle(show) end

ns.commands["cd"] = function() ns.toggleCooldowns() end
ns.commands["cooldowns"] = ns.commands["cd"]
ns.commands["attune"] = function() ns.toggleAttunements() end
ns.commands["dungeons"] = function() ns.toggleDungeons() end
ns.commands["level"] = function() ns.toggleLevelling() end
ns.commands["levelling"] = ns.commands["level"]
ns.commands["finder"] = function() ns.toggleFinder() end
ns.commands["chars"] = function() ns.toggleCharacters() end
ns.commands["characters"] = ns.commands["chars"]
