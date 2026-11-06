-- GFoA Guild Sync: own-character sheet, recipes, cooldowns, attunements.
local _, ns = ...

local function me()
  local db = ns.db
  local name = ns.call("UnitName", "player")
  if not db or not name or name == "" or name == UNKNOWNOBJECT then return nil end
  local c = db.characters[name]
  if type(c) ~= "table" then
    c = {}
    db.characters[name] = c
  end
  return c
end
ns.myChar = me

-- ---------------------------------------------------------------------------
-- Talents: { { name = tree, points = n }, ... }
-- ---------------------------------------------------------------------------

local function treePoints(tab)
  local numTalents = ns.call("GetNumTalents", tab)
  if not numTalents then return nil end
  local sum = 0
  for i = 1, numTalents do
    local _, _, _, _, rank = ns.call("GetTalentInfo", tab, i)
    if type(rank) == "number" then sum = sum + rank end
  end
  return sum
end

local function readTalents()
  local tabs = ns.call("GetNumTalentTabs")
  if not tabs or tabs == 0 then return nil end
  local out = {}
  for tab = 1, tabs do
    local r = { ns.call("GetTalentTabInfo", tab) }
    local name, points
    if type(r[1]) == "number" then
      -- Wrath+/Cata-style: id, name, description, icon, pointsSpent, ...
      name, points = r[2], r[5]
    else
      -- Classic Era: name, icon, pointsSpent, fileName
      name, points = r[1], r[3]
    end
    if type(points) ~= "number" then points = treePoints(tab) end
    if name then table.insert(out, { name = name, points = points or 0 }) end
  end
  if #out == 0 then return nil end
  return out
end

-- ---------------------------------------------------------------------------
-- Professions: { { name, skill, max }, ... }
-- ---------------------------------------------------------------------------

local PROFESSION_HEADERS = {
  ["Professions"] = true,
  ["Secondary Skills"] = true,
}

local function readProfessions()
  if TRADE_SKILLS then PROFESSION_HEADERS[TRADE_SKILLS] = true end
  if SECONDARY_SKILLS then PROFESSION_HEADERS[SECONDARY_SKILLS] = true end
  local out = {}
  local n = ns.call("GetNumSkillLines")
  if n and n > 0 then
    local inProfessions = false
    for i = 1, n do
      local name, isHeader, isExpanded, rank, _, _, maxRank = ns.call("GetSkillLineInfo", i)
      if isHeader then
        inProfessions = PROFESSION_HEADERS[name or ""] or false
        -- A collapsed professions header hides its skills: keep the previous list instead.
        if inProfessions and not isExpanded then return nil end
      elseif inProfessions and name then
        table.insert(out, { name = name, skill = rank or 0, max = maxRank or 0 })
      end
    end
    return out
  end
  -- Retail-style fallback.
  if ns.api("GetProfessions") and ns.api("GetProfessionInfo") then
    local list = { ns.call("GetProfessions") }
    for i = 1, 6 do
      local idx = list[i]
      if idx then
        local name, _, skill, max = ns.call("GetProfessionInfo", idx)
        if name then table.insert(out, { name = name, skill = skill or 0, max = max or 0 }) end
      end
    end
    return out
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Gear, attunements
-- ---------------------------------------------------------------------------

local function readGear()
  local gear = {}
  local any = false
  for slot = 1, 19 do
    local id = ns.call("GetInventoryItemID", "player", slot)
    if type(id) == "number" then
      gear[slot] = id
      any = true
    end
  end
  if any then return gear end
  return nil
end

-- true / false, or nil when no quest flag API exists.
function ns.questDone(id)
  if ns.api("C_QuestLog.IsQuestFlaggedCompleted") then
    return ns.call("C_QuestLog.IsQuestFlaggedCompleted", id) and true or false
  end
  if ns.api("IsQuestFlaggedCompleted") then
    return ns.call("IsQuestFlaggedCompleted", id) and true or false
  end
  return nil
end

local function readAttunements()
  local out = {}
  local any = false
  for _, a in ipairs(ns.config.attunements or {}) do
    for _, q in ipairs(ns.logic.attunementPending(a) and {} or a.quests) do
      local done = ns.questDone(q)
      if done == nil then return nil end
      if done then
        out[a.name] = true
        any = true
        break
      end
    end
  end
  if any then return out end
  return {}
end

-- ---------------------------------------------------------------------------
-- Character sheet
-- ---------------------------------------------------------------------------

function ns.refreshCharacter(levelOverride)
  local c = me()
  if not c then return end
  c.updated = ns.now()
  local _, surname = ns.unitName("player")
  if surname and c.surname ~= surname then   -- WoW: Forever last name
    c.surname = surname
    if ns.resetDisplayNames then ns.resetDisplayNames() end
  end
  local xp, xpMax = ns.call("UnitXP", "player"), ns.call("UnitXPMax", "player")
  -- During logout / reload teardown the game answers level 1, XP 0 / 0 and money 0: keep the last good values.
  local glitch = not levelOverride and ns.logic.logoutGlitch(ns.call("UnitLevel", "player"), xpMax)
  if not glitch then c.level = levelOverride or ns.call("UnitLevel", "player") or c.level end
  local _, classFile = ns.call("UnitClass", "player")
  c.class = classFile or c.class
  c.race = ns.call("UnitRace", "player") or c.race
  c.faction = ns.call("UnitFactionGroup", "player") or c.faction
  local guildName, guildRank = ns.call("GetGuildInfo", "player")
  if guildName then
    c.guild = guildName
    c.guildRank = guildRank
  elseif ns.call("IsInGuild") == false then
    c.guild = nil
    c.guildRank = nil
  end
  if not glitch and type(xp) == "number" and type(xpMax) == "number" then
    c.xp = xp
    c.xpMax = xpMax
  end
  c.talents = readTalents() or c.talents
  local profs = readProfessions()
  if profs then
    c.professions = profs
    -- Forget recipes and cooldowns of professions this character dropped.
    if type(c.recipes) == "table" and #profs > 0 then
      local have = {}
      for _, p in ipairs(profs) do have[p.name] = true end
      for prof in pairs(c.recipes) do
        if not have[prof] then c.recipes[prof] = nil end
      end
    end
  end
  c.gear = readGear() or c.gear
  c.attunements = readAttunements() or c.attunements
  local money = ns.call("GetMoney")
  if not glitch and type(money) == "number" then c.money = money end
  -- Drop cooldowns that are already ready.
  if type(c.cooldowns) == "table" then
    local t = ns.now()
    for k, v in pairs(c.cooldowns) do
      if type(v) ~= "number" or v <= t then c.cooldowns[k] = nil end
    end
  end
  if ns.updateUI then ns.updateUI() end
end

local function refreshSoon()
  ns.after(2, "character", function() ns.refreshCharacter() end)
end

ns.on("PLAYER_LOGIN", function() ns.after(5, "character", function() ns.refreshCharacter() end) end)
ns.on("PLAYER_LEVEL_UP", function(_, level) ns.refreshCharacter(tonumber(level)) end)
ns.on("PLAYER_MONEY", refreshSoon)
ns.on("PLAYER_EQUIPMENT_CHANGED", refreshSoon)
ns.on("CHARACTER_POINTS_CHANGED", refreshSoon)
ns.on("PLAYER_TALENT_UPDATE", refreshSoon)
ns.on("SKILL_LINES_CHANGED", refreshSoon)
ns.on("PLAYER_GUILD_UPDATE", refreshSoon)
ns.on("QUEST_TURNED_IN", refreshSoon)
ns.on("PLAYER_LOGOUT", function() ns.refreshCharacter() end)
ns.on("PLAYER_XP_UPDATE", refreshSoon)

-- Played time only arrives when the player types /played; the addon never requests it.
ns.on("TIME_PLAYED_MSG", function(_, total)
  local c = me()
  if c and type(total) == "number" then c.played = math.floor(total) end
end)

-- ---------------------------------------------------------------------------
-- Recipes and cooldowns from the trade skill / craft windows
-- ---------------------------------------------------------------------------

-- Adds names to c.recipes[prof] without removing ones not shown (headers may be collapsed or filtered).
local function mergeRecipes(prof, names, cooldowns, via)
  local c = me()
  if not c or type(prof) ~= "string" or prof == "" or prof == "UNKNOWN" then return end
  -- For /gf: which API the last profession window scan used (WoW: Forever's professions window is unconfirmed).
  ns.lastRecipeScan = { prof = prof, count = #names, via = via, t = ns.now() }
  c.recipes = c.recipes or {}
  local list = c.recipes[prof] or {}
  local seen = {}
  for _, n in ipairs(list) do seen[n] = true end
  for _, n in ipairs(names) do
    if not seen[n] then
      table.insert(list, n)
      seen[n] = true
    end
  end
  table.sort(list)
  c.recipes[prof] = list
  if next(cooldowns) then
    c.cooldowns = c.cooldowns or {}
    local cache = ns.cache
    if cache then cache.cdNames = type(cache.cdNames) == "table" and cache.cdNames or {} end
    for k, v in pairs(cooldowns) do
      c.cooldowns[k] = v
      if cache then cache.cdNames[k] = true end
    end
  end
  if ns.cooldownsChanged then ns.cooldownsChanged() end
end

-- Reagents of recipes your characters know (local cache, for "Reagent for:" in item tooltips).
local function addReagent(reagent, crafted)
  local cache = ns.cache
  if not cache then return end
  cache.reagents = type(cache.reagents) == "table" and cache.reagents or {}
  ns.logic.addReagent(cache.reagents, reagent, crafted)
end

-- Someone else's recipes in the window (linked / guild profession, NPC order): never save them as ours.
local function foreignTradeSkill()
  return ns.logic.foreignTradeSkill(ns.call("C_TradeSkillUI.IsTradeSkillLinked") or ns.call("IsTradeSkillLinked"),
    ns.call("C_TradeSkillUI.IsTradeSkillGuild") or ns.call("IsTradeSkillGuild"),
    ns.call("C_TradeSkillUI.IsNPCCrafting"))
end

local function readModernTradeSkill()
  local prof
  local info = ns.call("C_TradeSkillUI.GetBaseProfessionInfo")
  if type(info) == "table" then prof = info.professionName end
  if not prof then
    local child = ns.call("C_TradeSkillUI.GetChildProfessionInfo")
    if type(child) == "table" then prof = child.parentProfessionName or child.professionName end
  end
  if not prof then
    local a, b = ns.call("C_TradeSkillUI.GetTradeSkillLine")
    if type(a) == "string" then prof = a elseif type(b) == "string" then prof = b end
  end
  local ids = ns.call("C_TradeSkillUI.GetAllRecipeIDs")
  if not prof or type(ids) ~= "table" or #ids == 0 then return false end
  local names, cds = {}, {}
  local t = ns.now()
  for _, id in ipairs(ids) do
    local r = ns.call("C_TradeSkillUI.GetRecipeInfo", id)
    if type(r) == "table" and r.name and r.learned ~= false then
      table.insert(names, r.name)
      local cd = ns.call("C_TradeSkillUI.GetRecipeCooldown", id)
      if type(cd) == "number" and cd > 0 then cds[r.name] = t + math.floor(cd) end
    end
  end
  mergeRecipes(prof, names, cds, "C_TradeSkillUI")
  return true
end

local function readClassicTradeSkill()
  local n = ns.call("GetNumTradeSkills")
  if not n or n == 0 then return false end
  local prof = ns.call("GetTradeSkillLine")
  local names, cds = {}, {}
  local t = ns.now()
  for i = 1, n do
    local name, kind = ns.call("GetTradeSkillInfo", i)
    if name and kind ~= "header" and kind ~= "subheader" then
      table.insert(names, name)
      local cd = ns.call("GetTradeSkillCooldown", i)
      if type(cd) == "number" and cd > 0 then cds[name] = t + math.floor(cd) end
      for r = 1, math.min(8, ns.call("GetTradeSkillNumReagents", i) or 0) do
        local reagent = ns.call("GetTradeSkillReagentInfo", i, r)
        if type(reagent) == "string" then addReagent(reagent, name) end
      end
    end
  end
  mergeRecipes(prof, names, cds, "GetTradeSkillInfo")
  return true
end

local function readCraft()
  local n = ns.call("GetNumCrafts")
  if not n or n == 0 then return end
  if foreignTradeSkill() then return end
  local c = me()
  local prof = ns.logic.craftProfession(ns.call("GetCraftDisplaySkillLine") or ns.call("GetCraftSkillLine", 1),
    ns.call("GetCraftName"), c and c.professions)
  if not prof then return end   -- e.g. hunters' Beast Training, which uses the same window
  local names = {}
  for i = 1, n do
    local name, _, kind = ns.call("GetCraftInfo", i)
    if name and kind ~= "header" then
      table.insert(names, name)
      for r = 1, math.min(8, ns.call("GetCraftNumReagents", i) or 0) do
        local reagent = ns.call("GetCraftReagentInfo", i, r)
        if type(reagent) == "string" then addReagent(reagent, name) end
      end
    end
  end
  mergeRecipes(prof, names, {}, "GetCraftInfo")
end

local function readTradeSkill()
  if foreignTradeSkill() then return end
  if ns.api("C_TradeSkillUI.GetAllRecipeIDs") and readModernTradeSkill() then return end
  readClassicTradeSkill()
end

local function tradeSoon() ns.after(1, "tradeskill", readTradeSkill) end
local function craftSoon() ns.after(1, "craft", readCraft) end

ns.on("TRADE_SKILL_SHOW", tradeSoon)
ns.on("TRADE_SKILL_UPDATE", tradeSoon)
ns.on("TRADE_SKILL_LIST_UPDATE", tradeSoon)
ns.on("TRADE_SKILL_DATA_SOURCE_CHANGED", tradeSoon)
ns.on("CRAFT_SHOW", craftSoon)
ns.on("CRAFT_UPDATE", craftSoon)

-- ---------------------------------------------------------------------------
-- /gf questid: quest ids in your quest log (to fill in Config.lua attunements on WoW: Forever)
-- ---------------------------------------------------------------------------

local function questLogRows()
  if ns.api("C_QuestLog.GetInfo") and ns.api("C_QuestLog.GetNumQuestLogEntries") then
    return ns.logic.questLogRows(ns.call("C_QuestLog.GetNumQuestLogEntries"), function(i)
      local q = ns.call("C_QuestLog.GetInfo", i)
      if type(q) ~= "table" then return nil, true end
      return q.title, q.isHeader, q.questID
    end)
  end
  return ns.logic.questLogRows(ns.call("GetNumQuestLogEntries"), function(i)
    local title, _, _, isHeader, _, _, _, id = ns.call("GetQuestLogTitle", i)
    return title, isHeader, id
  end)
end

ns.commands["questid"] = function()
  local rows = questLogRows()
  if #rows == 0 then
    ns.print("no quest ids found (empty quest log, collapsed headers, or this client doesn't give ids)")
    return
  end
  for _, r in ipairs(rows) do ns.print(r.id .. "  " .. r.title) end
  ns.print("attunement ids go in Config.lua (attunements); /gf quest <id> checks one after you finish it")
end
ns.commands["questids"] = ns.commands["questid"]

-- /gf api: which game APIs and events this client has (for checking WoW: Forever; report the output if data is missing).
ns.commands["api"] = function()
  local function yes(b) return b and "yes" or "no" end
  local apis = {
    "C_TradeSkillUI.GetAllRecipeIDs", "GetNumTradeSkills", "GetTradeSkillInfo", "GetNumCrafts", "GetCraftInfo",
    "GetInstanceInfo", "IsInInstance", "GetRaidRosterInfo", "C_QuestLog.IsQuestFlaggedCompleted",
    "IsQuestFlaggedCompleted", "GetQuestLogTitle", "C_QuestLog.GetInfo",
  }
  local parts = {}
  for _, a in ipairs(apis) do table.insert(parts, a .. " " .. yes(ns.api(a))) end
  ns.print("APIs: " .. table.concat(parts, ", "))
  local events = { "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "CRAFT_SHOW",
    "ENCOUNTER_START", "ENCOUNTER_END", "BOSS_KILL", "CHAT_MSG_LOOT", "GROUP_ROSTER_UPDATE", "RAID_ROSTER_UPDATE" }
  parts = {}
  for _, e in ipairs(events) do table.insert(parts, e .. " " .. yes(ns.hasEvent(e))) end
  ns.print("events: " .. table.concat(parts, ", "))
  local kind, zone, maxPlayers, _, difficultyName = ns.instanceInfo()
  local size = ns.logic.raidSize(maxPlayers, difficultyName)
  ns.print(string.format("secret values: %s, combat log: %s, instance: %s %s %s",
    yes(type(issecretvalue) == "function"), ns.combatLogOff and "off (deaths not recorded)" or "on",
    tostring(kind or "none"), tostring(zone or ""), tostring(size or "")))
end

-- One /gf status line: this character's saved recipes and the last profession window scan.
function ns.recipeStatusLine()
  local c = me()
  local s = "recipes: " .. (ns.logic.recipeSummary(c and c.recipes) or "none yet (open each profession window once)")
  local scan = ns.lastRecipeScan
  if scan then
    s = s .. string.format("; last scan %s, %d via %s, %s", scan.prof, scan.count, tostring(scan.via), ns.ago(scan.t))
  end
  return s
end
