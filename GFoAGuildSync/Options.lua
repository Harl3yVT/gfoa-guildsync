-- GFoA Guild Sync: Interface Options page. Uses the Settings API when the client has it, else the old
-- InterfaceOptions_AddCategory. All values are per character in GFoAGuildSyncSettings.
local _, ns = ...

local panel, category

local function qualityText(q)
  local label = _G["ITEM_QUALITY" .. q .. "_DESC"] or ({ "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary" })[q + 1]
  local c = type(ITEM_QUALITY_COLORS) == "table" and ITEM_QUALITY_COLORS[q]
  if c and c.hex then return c.hex .. tostring(label) .. "|r" end
  return tostring(label)
end

local function createPanel()
  if panel then return panel end
  local W = ns.ui
  panel = CreateFrame("Frame", "GFoAGuildSyncOptionsPanel", UIParent)
  panel.name = "GFoA Guild Sync"
  panel:Hide()

  local icon = panel:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(W.TEX.paw)
  icon:SetSize(24, 24)
  icon:SetPoint("TOPLEFT", 14, -12)
  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
  title:SetTextColor(W.C.pink[1], W.C.pink[2], W.C.pink[3])
  title:SetText("GFoA Guild Sync " .. W.MUTED .. ns.ADDON_VERSION .. "|r")
  -- Passive "new version is out" line next to the title (only when a guildmate's addon is newer).
  local notice = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  notice:SetPoint("LEFT", title, "RIGHT", 12, 0)
  notice:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
  notice:SetJustifyH("LEFT")
  local function refreshNotice()
    local text = ns.updateNotice and ns.updateNotice()
    notice:SetText(text and (W.WAIT .. text .. "|r") or "")
  end
  local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", 16, -42)
  sub:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
  sub:SetJustifyH("LEFT")
  sub:SetText("Settings are saved for this character. The addon only reads game data and never acts for you."
    .. " Nothing pops up by itself.")
  local rule = panel:CreateTexture(nil, "ARTWORK")
  rule:SetTexture(W.TEX.rule)
  rule:SetHeight(2)
  rule:SetPoint("TOPLEFT", 16, -60)
  rule:SetPoint("RIGHT", panel, "RIGHT", -16, 0)

  -- Layout: a running y cursor, pink section headers, 24 px per checkbox.
  local y = -72
  local function section(text)
    y = y - 6
    local h = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    h:SetPoint("TOPLEFT", 16, y)
    h:SetTextColor(W.C.pink[1], W.C.pink[2], W.C.pink[3])
    h:SetText(text)
    y = y - 20
  end

  local checks = {}
  local function place(c)
    c:SetPoint("TOPLEFT", 18, y)
    table.insert(checks, c)
    y = y - 24
    return c
  end
  local function check(label, key, default, onChange)
    return place(W.check(panel, label, function() return ns.opt(key, default) end, function(v)
      ns.setOpt(key, v)
      if onChange then onChange(v) end
      if ns.refreshGuildWindow then ns.refreshGuildWindow() end
    end))
  end

  section("Tooltips and chat")
  check("Show \"Guild can craft\" in item and recipe tooltips", "tooltipCrafters", true)
  check("Show \"Reagent for\" in item tooltips (from your profession windows)", "tooltipReagents", true)
  check("Show Discord / alt info in player tooltips", "tooltipUnit", true)
  check("Add \"(Main's alt)\" after guild, party and raid chat lines from alts", "chatAltSuffix", true)
  check("Show " .. ns.CHECK .. " for members on the guild Discord in guild lists", "guildCheck", true)
  check("Alt+right-click an item opens \"Ask guild crafters\" (sent only when you click it)", "askAltClick", true)

  section("Sharing and windows")
  check("Send my character to officers' addons (guild sync)", "guildSync", true)
  check("Share my profession cooldowns with guildmates' addons", "shareCooldowns", true)
  -- These two keep their old setting names (minimapHidden / frameShown).
  place(W.check(panel, "Show minimap button", function() return not ns.settings.minimapHidden end,
    function(v) ns.toggleMinimap(v) end))
  place(W.check(panel, "Show status window", function() return ns.settings.frameShown end,
    function(v) ns.toggleFrame(v) end))

  section("Raids and officers")
  -- Loot minimum quality (raids)
  local lootLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  lootLabel:SetPoint("TOPLEFT", 74, y - 3)
  local function refreshLoot() lootLabel:SetText("Record raid loot of quality: " .. qualityText(ns.lootMin()) .. " and up") end
  local minus = W.button(panel, "-", 24, 20, function()
    ns.settings.lootMin = math.max(0, ns.lootMin() - 1)
    refreshLoot()
  end)
  minus:SetPoint("TOPLEFT", 20, y)
  local plus = W.button(panel, "+", 24, 20, function()
    ns.settings.lootMin = math.min(5, ns.lootMin() + 1)
    refreshLoot()
  end)
  plus:SetPoint("LEFT", minus, "RIGHT", 4, 0)
  y = y - 26

  -- Officer mode
  local offBtn
  local offLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  offLabel:SetPoint("TOPLEFT", 100, y - 3)
  local function refreshOfficer()
    local v = ns.settings.officerMode
    local mode = (v == true and "on") or (v == false and "off") or "auto"
    offLabel:SetText("Officer mode (store members' guild sync data): " .. W.PINK .. mode .. "|r"
      .. (ns.officerMode and (ns.officerMode() and (W.GOOD .. " - active|r") or (W.MUTED .. " - inactive|r")) or ""))
  end
  offBtn = W.button(panel, "Change", 72, 20, function()
    local v = ns.settings.officerMode
    if v == nil then ns.settings.officerMode = true
    elseif v == true then ns.settings.officerMode = false
    else ns.settings.officerMode = nil end
    refreshOfficer()
  end)
  offBtn:SetPoint("TOPLEFT", 20, y)
  y = y - 26

  section("Discord")
  -- Discord link status of this character
  local linkLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  linkLabel:SetPoint("TOPLEFT", 20, y)
  local function refreshLink()
    local me = ns.call("UnitName", "player") or "?"
    local status, main = ns.logic.linkStatus(ns.discordData(), me)
    local text = ({ main = ns.CHECK .. " linked on Discord (main)", unlinked = ns.CROSS .. " not linked on Discord yet",
      unknown = W.MUTED .. "no Discord data on this PC yet|r" })[status]
      or (ns.CHECK .. " linked on Discord (" .. tostring(main) .. "'s alt)")
    linkLabel:SetText(me .. ": " .. text)
  end
  y = y - 22

  local export = W.button(panel, "Show import code", 160, 22, function() ns.showExport() end)
  export:SetPoint("TOPLEFT", 20, y)
  local guild = W.button(panel, "Guild window", 110, 22, function() ns.toggleGuildWindow(true) end)
  guild:SetPoint("LEFT", export, "RIGHT", 8, 0)
  local charsBtn = W.button(panel, "My characters", 110, 22, function() ns.toggleCharacters(true) end)
  charsBtn:SetPoint("LEFT", guild, "RIGHT", 8, 0)

  panel:SetScript("OnShow", function()
    for _, c in ipairs(checks) do c.refresh() end
    refreshLoot()
    refreshOfficer()
    refreshLink()
    refreshNotice()
  end)
  return panel
end

local function register()
  local p = createPanel()
  if type(Settings) == "table" and type(Settings.RegisterCanvasLayoutCategory) == "function" then
    category = Settings.RegisterCanvasLayoutCategory(p, p.name)
    if category and type(Settings.RegisterAddOnCategory) == "function" then Settings.RegisterAddOnCategory(category) end
  elseif type(InterfaceOptions_AddCategory) == "function" then
    InterfaceOptions_AddCategory(p)
  end
end

function ns.openOptions()
  if ns.call("InCombatLockdown") then
    ns.print("options can't open in combat")
    return
  end
  if category and type(Settings) == "table" and type(Settings.OpenToCategory) == "function" then
    local id = (category.GetID and category:GetID()) or category.ID
    if pcall(Settings.OpenToCategory, id) then return end
  end
  if panel and type(InterfaceOptionsFrame_OpenToCategory) == "function" then
    -- Called twice: the first call sometimes only opens the frame.
    pcall(InterfaceOptionsFrame_OpenToCategory, panel)
    pcall(InterfaceOptionsFrame_OpenToCategory, panel)
    return
  end
  ns.print("options page not available in this client; use /gfoa commands")
end

ns.commands["options"] = function() ns.openOptions() end
ns.commands["config"] = ns.commands["options"]

ns.on("PLAYER_LOGIN", function() ns.safe("options", register) end)
