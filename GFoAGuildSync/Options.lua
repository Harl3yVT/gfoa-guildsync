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

  -- Everything below the header scrolls: the page is taller than the Settings window on small screens.
  local scroll = CreateFrame("ScrollFrame", "GFoAGuildSyncOptionsScroll", panel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -66)
  scroll:SetPoint("BOTTOMRIGHT", -28, 6)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(560, 1)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(self, w) if w and w > 0 then content:SetWidth(w) end end)

  -- Layout: a running y cursor, pink section headers, 24 px per checkbox.
  local y = -6
  local function section(text)
    y = y - 6
    local h = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
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
    return place(W.check(content, label, function() return ns.opt(key, default) end, function(v)
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
  check("Hold Shift over an item to list every guild crafter, online first", "crafterLookup", true)
  check("One chat line at login about craft requests my characters can make (off by default)", "craftNotes", false)

  section("Sharing and windows")
  check("Send my character to officers' addons (guild sync)", "guildSync", true)
  check("Share my profession cooldowns with guildmates' addons", "shareCooldowns", true)
  check("Get Discord info from guild officers' addons (and share it if this PC has the file)", "botDataRelay", true,
    function() if ns.updateUI then ns.updateUI() end end)
  check("Share my stats totals for guild Discord leaderboards (no gold; off by default)", "statsShare", false,
    function(v) if ns.setStatsSharing then ns.setStatsSharing(v) end end)
  check("Guild event reminders in chat 30 and 5 minutes before (off by default)", "eventReminders", false)
  check("Next guild event countdown under the minimap button", "minimapCountdown", true,
    function() if ns.updateMinimapCountdown then ns.updateMinimapCountdown() end end)
  check("Toasts: my leaderboard moves and guildies reaching 60 (off by default)", "toasts", false)
  -- These two keep their old setting names (minimapHidden / frameShown).
  place(W.check(content, "Show minimap button", function() return not ns.settings.minimapHidden end,
    function(v) ns.toggleMinimap(v) end))
  place(W.check(content, "Show status window", function() return ns.settings.frameShown end,
    function(v) ns.toggleFrame(v) end))
  check("Share my minigame best scores with guildmates' addons", "shareGameScores", true)
  check("Open Paw Drop by itself on flight paths and when AFK (never in combat)", "gamesAutoOpen", false)
  check("Hide the Leaderboard minimap button (open it from this menu instead)", "leaderboardMinimapHidden", false,
    function() ns.applyLeaderboardMinimap() end)

  section("Raids and officers")
  -- Loot minimum quality (raids)
  local lootLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  lootLabel:SetPoint("TOPLEFT", 74, y - 3)
  local function refreshLoot() lootLabel:SetText("Record raid loot of quality: " .. qualityText(ns.lootMin()) .. " and up") end
  local minus = W.button(content, "-", 24, 20, function()
    ns.settings.lootMin = math.max(0, ns.lootMin() - 1)
    refreshLoot()
  end)
  minus:SetPoint("TOPLEFT", 20, y)
  local plus = W.button(content, "+", 24, 20, function()
    ns.settings.lootMin = math.min(5, ns.lootMin() + 1)
    refreshLoot()
  end)
  plus:SetPoint("LEFT", minus, "RIGHT", 4, 0)
  y = y - 26

  -- Officer mode
  local offBtn
  local offLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  offLabel:SetPoint("TOPLEFT", 100, y - 3)
  local function refreshOfficer()
    local v = ns.settings.officerMode
    local mode = (v == true and "on") or (v == false and "off") or "auto"
    offLabel:SetText("Officer mode (store members' guild sync data): " .. W.PINK .. mode .. "|r"
      .. (ns.officerMode and (ns.officerMode() and (W.GOOD .. " - active|r") or (W.MUTED .. " - inactive|r")) or ""))
  end
  offBtn = W.button(content, "Change", 72, 20, function()
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
  local linkLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  linkLabel:SetPoint("TOPLEFT", 20, y)
  local function refreshLink()
    local me = ns.call("UnitName", "player") or "?"
    local status, main = ns.logic.linkStatus(ns.discordData(), ns.logic.fullName(ns.unitName("player")) or me)
    local text = ({ main = ns.CHECK .. " linked on Discord (main)", unlinked = ns.CROSS .. " not linked on Discord yet",
      unknown = W.MUTED .. "no Discord data on this PC yet|r" })[status]
      or (ns.CHECK .. " linked on Discord (" .. tostring(ns.displayName(main)) .. "'s alt)")
    linkLabel:SetText(ns.displayName(me) .. ": " .. text)
  end
  y = y - 22

  -- Link code (account-wide): typed once, then every character registers itself through guild sync.
  local codeLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  codeLabel:SetPoint("TOPLEFT", 20, y - 3)
  codeLabel:SetText("Link code:")
  local codeBox = W.editBox(content, 80)
  if codeBox.SetMaxLetters then codeBox:SetMaxLetters(16) end
  codeBox:SetPoint("LEFT", codeLabel, "RIGHT", 10, 0)
  local codeStatus = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  local function refreshCode(err)
    if err then
      codeStatus:SetText(ns.CROSS .. " " .. W.WAIT .. err .. "|r")
    elseif ns.db and ns.db.link then
      codeStatus:SetText(ns.CHECK .. " " .. ns.linkLine())
    else
      codeStatus:SetText(W.MUTED .. ns.linkLine() .. "|r")
    end
  end
  local saveCode = W.button(content, "Save", 60, 20, function()
    local ok, err = ns.setLink(codeBox:GetText() or "")
    if ok then
      codeBox:SetText("")
      codeBox:ClearFocus()
    end
    refreshCode(not ok and err or nil)
  end)
  saveCode:SetPoint("LEFT", codeBox, "RIGHT", 6, 0)
  codeBox:SetScript("OnEnterPressed", function() saveCode:Click() end)
  local mainBtn = W.button(content, "This is my main", 120, 20, function()
    local ok, err = ns.setMain()
    refreshCode(not ok and err or nil)
  end)
  mainBtn:SetPoint("LEFT", saveCode, "RIGHT", 8, 0)
  y = y - 24
  codeStatus:SetPoint("TOPLEFT", 20, y)
  codeStatus:SetPoint("RIGHT", content, "RIGHT", -16, 0)
  codeStatus:SetJustifyH("LEFT")
  y = y - 20

  local export = W.button(content, "Show import code", 160, 22, function() ns.showExport() end)
  export:SetPoint("TOPLEFT", 20, y)
  local guild = W.button(content, "Guild window", 110, 22, function() ns.toggleGuildWindow(true) end)
  guild:SetPoint("LEFT", export, "RIGHT", 8, 0)
  local charsBtn = W.button(content, "My characters", 110, 22, function() ns.toggleCharacters(true) end)
  charsBtn:SetPoint("LEFT", guild, "RIGHT", 8, 0)

  content:SetHeight(-y + 30)

  panel:SetScript("OnShow", function()
    for _, c in ipairs(checks) do c.refresh() end
    refreshLoot()
    refreshOfficer()
    refreshLink()
    refreshCode()
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
  ns.print("options page not available in this client; use /gf commands")
end

ns.commands["options"] = function() ns.openOptions() end
ns.commands["config"] = ns.commands["options"]

ns.on("PLAYER_LOGIN", function() ns.safe("options", register) end)
