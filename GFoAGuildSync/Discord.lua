-- GFoA Guild Sync: shows data from the guild Discord (GFoAGuildSyncBotData, read only).
--   * item tooltips: "Guild can craft: Testy (Tailoring 285)", "Guild already knows it" on recipes, "Reagent for:"
--   * unit tooltips: Discord check mark, role, "Altname is Thrall's alt", "Alts: ...", and your duel / deathroll
--     record against them from Sephya's GayFurriesLeaderboard (when it's loaded)
--   * Alt+right-click an item: menu with "Ask guild crafters" (sent only after that click)
--   * guild / party / raid chat: " (Thrall's alt)" after lines from alts (a display filter, nothing is sent)
--   * Blizzard guild list: check mark after members registered on Discord
-- Taint safety: only HookScript / hooksecurefunc / TooltipDataProcessor post-calls and chat display filters; no
-- secure frame is created or changed and nothing protected is called. Every hook body runs inside pcall.
local _, ns = ...
local L = ns.logic

function ns.altOf(name) return L.altOf(ns.discordData(), name) end
function ns.isRegistered(name) return L.isRegistered(ns.discordData(), name) end

-- ---------------------------------------------------------------------------
-- Tooltips
-- ---------------------------------------------------------------------------

local added = setmetatable({}, { __mode = "k" })         -- tooltip -> text already added since the last clear
local clearHooked = setmetatable({}, { __mode = "k" })   -- tooltips whose OnTooltipCleared resets `added`

-- Some clients announce the same item twice for one tooltip (post-call and script), so a line is added once per
-- clear. TooltipDataProcessor also reaches tooltips we never hooked (other addons' tooltips): hook their clear on
-- first sight, and when a tooltip can't tell us it was cleared, don't dedupe it at all.
local function addOnce(tt, key, fn)
  if not clearHooked[tt] and tt.HasScript and tt.HookScript and tt:HasScript("OnTooltipCleared") then
    tt:HookScript("OnTooltipCleared", function(self) added[self] = nil end)
    clearHooked[tt] = true
  end
  if clearHooked[tt] then
    if added[tt] == key then return end
    added[tt] = key
  end
  fn()
  if tt.Show then tt:Show() end   -- resize to fit the new line
end

-- Forbidden tooltips (Blizzard-only frames) error on any method call; leave them alone.
local function usable(tt)
  if not tt then return false end
  if tt.IsForbidden and tt:IsForbidden() then return false end
  return true
end

-- Crafter indexes (own characters, and officer-mode guild sync payloads), rebuilt only when their data changes.
local ownIdx, ownSig, syncIdx, syncSig

local function ownIndex()
  local chars = ns.db and ns.db.characters or {}
  local sig = 0
  for _, c in pairs(chars) do
    if type(c) == "table" and type(c.recipes) == "table" then
      for _, list in pairs(c.recipes) do sig = sig + (type(list) == "table" and #list or 0) end
    end
  end
  if sig ~= ownSig then ownIdx, ownSig = L.crafterIndexFromOwn(chars), sig end
  return ownIdx
end

local function syncIndex()
  local gs = ns.db and ns.db.guildSync
  if type(gs) ~= "table" then return nil end
  local n, latest = 0, 0
  for _, e in pairs(gs) do
    n = n + 1
    if type(e) == "table" and (e.t or 0) > latest then latest = e.t end
  end
  local sig = n .. ":" .. latest
  if sig ~= syncSig then
    local idx = {}
    for _, e in pairs(gs) do
      local payload = type(e) == "table" and L.decodeExport(e.data)
      if payload then L.crafterIndexFromSync(payload.chars, idx) end
    end
    syncIdx, syncSig = idx, sig
  end
  return syncIdx
end

-- { { name, prof, skill } } of everyone the addon knows can craft itemName.
function ns.guildCrafters(itemName)
  return L.guildCrafters(itemName, ns.discordData(), ownIndex(), syncIndex())
end

local function itemIdOf(link)
  return type(link) == "string" and tonumber(string.match(link, "item:(%d+)")) or nil
end

local function itemTooltip(tt)
  if not usable(tt) or not tt.GetItem then return end
  local name, link = tt:GetItem()
  if type(name) ~= "string" or name == "" or ns.isSecret(name) then return end
  local lines = {}
  -- 1.7.0 crafter lookup: holding Shift, or a clicked chat link (ItemRefTooltip), lists every crafter, online first.
  local lookup = ns.opt("crafterLookup", true) and ns.crafterLookupLines
    and (ns.call("IsShiftKeyDown") or tt == _G.ItemRefTooltip)
  if ns.opt("tooltipCrafters", true) or lookup then
    local list = ns.guildCrafters(name)
    if lookup and #list > 0 then
      for _, l in ipairs(ns.crafterLookupLines(name, 8)) do table.insert(lines, l) end
    elseif #list > 0 then
      table.insert(lines, { "Guild can craft: " .. L.formatCrafters(list, 5, ns.displayName)
        .. (ns.opt("crafterLookup", true) and "  |cffa79db3(Shift: all, online first)|r" or ""), 0.83, 0.55, 1 })
    end
    local target = L.recipeTarget(name)
    if target then
      local known = ns.guildCrafters(target)
      if #known > 0 then
        table.insert(lines, { "Guild already knows it: " .. L.formatCrafters(known, 5, ns.displayName), 0.83, 0.55, 1 })
      end
    end
  end
  if ns.opt("tooltipReagents", true) then
    local uses = L.reagentFor(ns.cache and ns.cache.reagents, name)
    if uses then
      local shown = {}
      for i = 1, math.min(4, #uses) do shown[i] = uses[i] end
      table.insert(lines, { "Reagent for: " .. table.concat(shown, ", ") .. (#uses > 4 and (" +" .. (#uses - 4)) or ""),
        0.7, 0.7, 0.9 })
    end
  end
  local itemId = itemIdOf(link)
  local ask = itemId and ns.askState and ns.askState(itemId)
  if ask then
    table.insert(lines, { "Asked guild crafters " .. ns.ago(ask.t)
      .. (ask.acked and " (an officer's addon got it)" or " (waiting for an officer to come online)"), 0.6, 0.8, 0.6 })
  end
  if #lines == 0 then return end
  addOnce(tt, "item:" .. name .. (lookup and ":all" or ""), function()
    for _, l in ipairs(lines) do tt:AddLine(l[1], l[2], l[3], l[4], true) end
  end)
end

-- "You vs them: duels 3-1 · deathrolls 2-0" from Sephya's GayFurriesLeaderboard records (read only), or nil
-- when that addon isn't loaded, it's you, or there are no records between you.
local function headToHeadLine(name, surname)
  local db = _G.GayFurriesLeaderboardDB
  if type(db) ~= "table" then return nil end
  local myFirst, mySurname = ns.unitName("player")
  local me, other = L.fullName(myFirst, mySurname), L.fullName(name, surname)
  if not me or not other or me == other then return nil end
  local dw, dl = L.headToHead(db.duels, me, other)
  local rw, rl = L.headToHead(db.rolls, me, other)
  return L.headToHeadLine(dw, dl, rw, rl)
end

local function unitTooltip(tt)
  if not ns.opt("tooltipUnit", true) or not usable(tt) or not tt.GetUnit then return end
  local _, unit = tt:GetUnit()
  if not unit or ns.isSecret(unit) or not ns.call("UnitIsPlayer", unit) then return end
  local name, surname, realm = ns.unitName(unit)   -- on Forever the second value is a surname, not a realm
  if type(name) ~= "string" or ns.isSecret(name) then return end
  if type(realm) == "string" and realm ~= "" and realm ~= ns.realmKey() then return end   -- discord names have no realm
  local h2h = headToHeadLine(name, surname)
  local discord = ns.discordData()
  local full = L.fullName(name, surname)   -- "First Surname": also finds a registered "Firstsurname"
  local e = discord and L.memberEntry(discord, full)
  local parts, altLine, alts = {}, nil, {}
  if e then
    if e.registered then table.insert(parts, ns.CHECK .. " Discord") end
    if type(e.role) == "string" and e.role ~= "" then
      table.insert(parts, e.role .. ((type(e.spec) == "string" and e.spec ~= "") and (" (" .. e.spec .. ")") or ""))
    end
    -- The unit's own surname comes from UnitName; everyone else's from the roster / own characters.
    local function disp(n)
      if n == name then return L.fullName(name, surname) or n end
      return ns.displayName(n)
    end
    altLine = L.altLine(discord, full, disp)
    alts = L.altsOf(discord, full)
    for i, a in ipairs(alts) do alts[i] = ns.displayName(a) end
  end
  if #parts == 0 and not altLine and #alts == 0 and not h2h then return end
  addOnce(tt, "unit:" .. name, function()
    if #parts > 0 then tt:AddLine("GFoA: " .. table.concat(parts, "  "), 0.83, 0.55, 1) end
    if altLine then tt:AddLine(altLine, 0.83, 0.55, 1) end
    if #alts > 0 then tt:AddLine("Alts: " .. table.concat(alts, ", "), 0.7, 0.7, 0.9, true) end
    if h2h then tt:AddLine(h2h, 0.65, 0.62, 0.70) end
  end)
end

local function safeHook(label, fn)
  return function(tt) ns.safe(label, fn, tt) end
end

local function hookTooltips()
  local itemFn, unitFn = safeHook("tooltipItem", itemTooltip), safeHook("tooltipUnit", unitTooltip)
  ns.tooltipMode = "none"
  -- Modern client API (retail 10.0.2+, and possibly Forever).
  if type(TooltipDataProcessor) == "table" and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
      and type(Enum) == "table" and type(Enum.TooltipDataType) == "table" then
    local ok = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, itemFn)
    pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, unitFn)
    if ok then ns.tooltipMode = "TooltipDataProcessor" end
  end
  -- Classic-style scripts too, wherever the tooltip still has them: some classic clients expose
  -- TooltipDataProcessor while their own tooltips only fire these (Questie checks for the same thing). addOnce
  -- keeps it to one line when both fire.
  local scripts = false
  for _, tname in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2" }) do
    local tt = _G[tname]
    if tt and tt.HasScript and tt.HookScript then
      if tt:HasScript("OnTooltipSetItem") then
        tt:HookScript("OnTooltipSetItem", itemFn)
        scripts = true
      end
      if tt:HasScript("OnTooltipSetUnit") then tt:HookScript("OnTooltipSetUnit", unitFn) end
      -- Forget what we added when a tooltip is cleared, so the next item gets its line again.
      if tt:HasScript("OnTooltipCleared") and not clearHooked[tt] then
        tt:HookScript("OnTooltipCleared", function(self) added[self] = nil end)
        clearHooked[tt] = true
      end
    end
  end
  if scripts then
    ns.tooltipMode = (ns.tooltipMode == "none") and "OnTooltipSetItem" or (ns.tooltipMode .. "+OnTooltipSetItem")
  end
end

-- ---------------------------------------------------------------------------
-- Chat: " (Thrall's alt)" after lines by alts (display only)
-- ---------------------------------------------------------------------------

local CHAT_EVENTS = {
  "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
  "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
}

local function suffixFor(msg, author)
  if ns.isSecret(msg) or ns.isSecret(author) then return nil end
  if type(msg) ~= "string" or type(author) ~= "string" then return nil end
  return L.altSuffix(ns.discordData(), author, msg, ns.displayName)
end

-- Each chat frame calls the filter with the original message, so the suffix appears once per line per frame.
local function chatFilter(_, _, msg, author, ...)
  if not ns.opt("chatAltSuffix", true) then return false end
  local ok, suffix = pcall(suffixFor, msg, author)
  if ok and suffix then return false, msg .. suffix, author, ... end
  return false
end

local function hookChat()
  if type(ChatFrame_AddMessageEventFilter) ~= "function" then return end
  for _, event in ipairs(CHAT_EVENTS) do pcall(ChatFrame_AddMessageEventFilter, event, chatFilter) end
end

-- ---------------------------------------------------------------------------
-- "Ask guild crafters": Alt+right-click an item (bags, chat links, ...) opens a small menu; nothing is sent until
-- the player clicks "Ask guild crafters". The request goes only to officers' addons (hidden addon message).
-- ---------------------------------------------------------------------------

local cursorAnchor

local function openAskMenu(link)
  local itemId = itemIdOf(link)
  local name = type(link) == "string" and string.match(link, "%[(.-)%]")
  if not itemId or not name then return end
  if not cursorAnchor then
    cursorAnchor = CreateFrame("Frame", nil, UIParent)
    cursorAnchor:SetSize(1, 1)
  end
  local x, y = GetCursorPosition()
  local scale = UIParent:GetEffectiveScale()
  cursorAnchor:ClearAllPoints()
  cursorAnchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (x or 0) / scale, (y or 0) / scale)
  local list = ns.guildCrafters(name)
  local items = {
    { text = "Ask guild crafters: " .. name, func = function() ns.askCrafters(itemId, name) end },
  }
  if #list > 0 then
    table.insert(items, { text = "|cff999999Can craft: " .. L.formatCrafters(list, 3, ns.displayName) .. "|r", func = function() end })
  end
  table.insert(items, { text = "Cancel", func = function() end })
  ns.ui.popup(cursorAnchor, items, true)   -- another Alt+right-click shows the new item instead of just closing
end

local function onModifiedClick(link)
  if not ns.opt("askAltClick", true) or type(link) ~= "string" or not string.find(link, "item:", 1, true) then return end
  -- Plain Alt only: RXPGuides can toggle junk with Ctrl+Alt+right-click, and Shift/Ctrl clicks are chat links,
  -- stack splitting and the dressing room.
  if not ns.call("IsAltKeyDown") or ns.call("IsShiftKeyDown") or ns.call("IsControlKeyDown") then return end
  local button = ns.call("GetMouseButtonClicked")
  if button and button ~= "RightButton" then return end
  -- At the auction house Auctionator can be set to pick bag items with Alt+right-click: leave that click to it.
  for _, fname in ipairs({ "AuctionFrame", "AuctionHouseFrame" }) do
    local f = _G[fname]
    if f and f.IsShown and f:IsShown() then return end
  end
  if not ns.call("IsInGuild") then return end
  openAskMenu(link)
end

local function hookAsk()
  if type(hooksecurefunc) == "function" and type(HandleModifiedItemClick) == "function" then
    hooksecurefunc("HandleModifiedItemClick", function(link) ns.safe("askClick", onModifiedClick, link) end)
  end
end

-- /gf ask <shift-clicked item link>
ns.commands["ask"] = function(arg)
  local itemId = itemIdOf(arg)
  local name = type(arg) == "string" and string.match(arg, "%[(.-)%]")
  if not itemId or not name then
    ns.print("usage: /gf ask <shift-click an item into the chat box>, or Alt+right-click the item")
    return
  end
  local ok, reason = ns.askCrafters(itemId, name)
  if ok then
    ns.print("asked guild crafters for " .. name .. " (officers' addons pass it to the Discord crafting channel)")
  else
    ns.print("not sent: " .. tostring(reason))
  end
end

ns.commands["alts"] = function()
  ns.setOpt("chatAltSuffix", not ns.opt("chatAltSuffix", true))
  ns.print("alt names in chat " .. (ns.opt("chatAltSuffix", true) and "on" or "off"))
end

-- ---------------------------------------------------------------------------
-- Blizzard guild list (Classic FriendsFrame guild tab): check mark after registered members
-- ---------------------------------------------------------------------------

local GUILD_BUTTONS = { "GuildFrameButton", "GuildFrameGuildStatusButton" }

local function decorateGuildList()
  if not ns.opt("guildCheck", true) then return end
  local discord = ns.discordData()
  if not discord then return end
  for i = 1, (tonumber(GUILDMEMBERS_TO_DISPLAY) or 13) do
    for _, prefix in ipairs(GUILD_BUTTONS) do
      local fs = _G[prefix .. i .. "Name"]
      if fs and fs.GetText and fs.SetText and fs.IsVisible and fs:IsVisible() then
        local text = fs:GetText()
        if type(text) == "string" and not ns.isSecret(text) and not string.find(text, "|T", 1, true)
            and L.isRegistered(discord, text) then
          fs:SetText(text .. " " .. ns.CHECK)
        end
      end
    end
  end
end

local guildHooked = false
local function hookGuildFrame()
  if guildHooked or type(hooksecurefunc) ~= "function" then return end
  if type(GuildStatus_Update) == "function" then
    hooksecurefunc("GuildStatus_Update", function() ns.safe("guildList", decorateGuildList) end)
    guildHooked = true
  end
end

ns.on("ADDON_LOADED", function(_, name)
  if name == "Blizzard_GuildUI" or name == "Blizzard_Communities" then hookGuildFrame() end
end)

ns.on("PLAYER_LOGIN", function()
  ns.safe("hookTooltips", hookTooltips)
  ns.safe("hookChat", hookChat)
  ns.safe("hookGuild", hookGuildFrame)
  ns.safe("hookAsk", hookAsk)
end)
