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
    for _, q in ipairs(a.quests or {}) do
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
  c.level = levelOverride or ns.call("UnitLevel", "player") or c.level
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
  local xp, xpMax = ns.call("UnitXP", "player"), ns.call("UnitXPMax", "player")
  if type(xp) == "number" and type(xpMax) == "number" then
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
  if type(money) == "number" then c.money = money end
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
local function mergeRecipes(prof, names, cooldowns)
  local c = me()
  if not c or not prof or prof == "" or prof == "UNKNOWN" then return end
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
  mergeRecipes(prof, names, cds)
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
  mergeRecipes(prof, names, cds)
  return true
end

local function readCraft()
  local n = ns.call("GetNumCrafts")
  if not n or n == 0 then return end
  local prof = ns.call("GetCraftDisplaySkillLine") or ns.call("GetCraftSkillLine", 1) or ns.call("GetCraftName")
  if type(prof) ~= "string" then return end
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
  mergeRecipes(prof, names, {})
end

local function readTradeSkill()
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
