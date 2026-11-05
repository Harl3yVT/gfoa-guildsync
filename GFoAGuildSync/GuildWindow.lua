-- GFoA Guild Sync: guild window (/gf guild). The last roster scan with class colours, filters and sorting, plus
-- a check mark for members registered on Discord and "alt of" from the guild's Discord data, a role filter and
-- an optional "group alts under their main" view. Display only.
local _, ns = ...
local L = ns.logic

local ROWS, ROW_H = 20, 16
local COLUMNS = {
  { key = "name", title = "Name", width = 150 },
  { key = "level", title = "Lvl", width = 34 },
  { key = "class", title = "Class", width = 66 },
  { key = "rank", title = "Rank", width = 92 },
  { key = "zone", title = "Zone", width = 140 },
  { key = "main", title = "Alt of", width = 92 },
  { key = "seen", title = "Seen", width = 62 },
}
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local frame, rows, slider, countText, classButton, roleButton
local ROLES = { "Tank", "Healer", "DPS" }
local indent = {}
local filter = { onlineOnly = false, class = nil, role = nil, minLevel = nil, maxLevel = nil, search = "" }
local sortKey, sortDesc = "seen", false
local shown = {}
local offset = 0

local function seenText(m)
  if m.online then return ns.ui.GOOD .. "online|r" end
  local d = m.lastOnlineDays
  if type(d) ~= "number" then return "?" end
  if d < 1 then return math.floor(d * 24 + 0.5) .. "h" end
  return math.floor(d + 0.5) .. "d"
end

local function render()
  if not frame or not frame:IsShown() then return end
  local W = ns.ui
  local discord = ns.discordData()
  local maxOff = math.max(0, #shown - ROWS)
  if offset > maxOff then offset = maxOff end
  if offset < 0 then offset = 0 end
  for i = 1, ROWS do
    local row = rows[i]
    local m = shown[offset + i]
    row.member = m
    if m then
      local name = (indent[m] and (W.MUTED .. "- |r") or "") .. W.classColor(m.class) .. (m.name or "?") .. "|r"
      if ns.opt("guildCheck", true) and L.isRegistered(discord, m.name) then name = name .. " " .. ns.CHECK end
      local dim = m.online and "" or W.MUTED
      row.cols.name:SetText(name)
      row.cols.level:SetText(dim .. tostring(m.level or "?"))
      row.cols.class:SetText(W.classColor(m.class) .. W.className(m.class) .. "|r")
      row.cols.rank:SetText(dim .. (m.rank or ""))
      row.cols.zone:SetText(dim .. (m.zone or ""))
      row.cols.main:SetText(dim .. (L.altOf(discord, m.name) or ""))
      row.cols.seen:SetText(seenText(m))
      row:Show()
    else
      row:Hide()
    end
  end
  if frame.empty then
    local e = frame.emptyState
    frame.empty:SetShown(e ~= nil)
    if e then
      frame.empty.title:SetText(e[1])
      frame.empty.hint:SetText(e[2])
    end
  end
  if slider then
    slider:SetMinMaxValues(0, maxOff)
    slider.updating = true
    slider:SetValue(offset)
    slider.updating = false
    if maxOff > 0 then slider:Show() else slider:Hide() end
  end
end

local function refresh()
  if not frame or not frame:IsShown() then return end
  local g = ns.db and ns.db.guild
  local members = g and g.members or {}
  local discord = ns.discordData()
  shown = L.sortRoster(L.filterRoster(members, filter, discord), sortKey, sortDesc, discord)
  indent = {}
  if ns.opt("guildGroupAlts", false) then shown, indent = L.groupAlts(shown, discord) end
  local online = 0
  for _, m in ipairs(members) do if m.online then online = online + 1 end end
  countText:SetText(string.format("%d shown / %d members (%d online), scanned %s", #shown, #members, online,
    ns.ago(g and g.updated)))
  if #members == 0 then
    frame.emptyState = { "No roster scan yet", "It fills in a few seconds after login. Press Rescan to scan now." }
  elseif #shown == 0 then
    frame.emptyState = { "Nobody matches these filters", "Clear the search, or set Class and Role back to all." }
  else
    frame.emptyState = nil
  end
  local pink = ns.ui.C.pink
  for _, h in ipairs(frame.headers) do
    local active = h.key == sortKey
    h.text:SetText(h.title .. (active and (sortDesc and " v" or " ^") or ""))
    if active then h.text:SetTextColor(pink[1], pink[2], pink[3]) else h.text:SetTextColor(0.65, 0.62, 0.70) end
  end
  render()
end
ns.refreshGuildWindow = refresh

local function rowTooltip(row)
  local m = row.member
  if not m or not GameTooltip then return end
  local discord = ns.discordData()
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(ns.ui.classColor(m.class) .. (m.name or "?") .. "|r")
  GameTooltip:AddLine(string.format("Level %s %s, %s", tostring(m.level or "?"), ns.ui.className(m.class),
    m.rank or ""), 1, 1, 1)
  if m.zone and m.zone ~= "" then GameTooltip:AddLine(m.zone, 0.8, 0.8, 0.8) end
  if m.note and m.note ~= "" then GameTooltip:AddLine("Note: " .. m.note, 1, 1, 1, true) end
  if m.officerNote and m.officerNote ~= "" then GameTooltip:AddLine("Officer note: " .. m.officerNote, 1, 0.8, 0.5, true) end
  local e = L.memberEntry(discord, m.name)
  if e then
    if e.registered then GameTooltip:AddLine(ns.CHECK .. " registered on Discord", 0.74, 0.89, 0.64) end
    local altLine = L.altLine(discord, m.name)
    if altLine then GameTooltip:AddLine(altLine, 0.83, 0.55, 1) end
    local alts = L.altsOf(discord, m.name)
    if #alts > 0 then GameTooltip:AddLine("Alts: " .. table.concat(alts, ", "), 0.7, 0.7, 0.9, true) end
    if type(e.role) == "string" and e.role ~= "" then
      GameTooltip:AddLine(e.role .. ((type(e.spec) == "string" and e.spec ~= "") and (" - " .. e.spec) or ""), 0.8, 0.8, 1)
    end
  end
  GameTooltip:Show()
end

local function classMenu()
  local items = { { text = "All classes", func = function()
    filter.class = nil
    classButton:SetText("Class: all")
    refresh()
  end } }
  for _, cls in ipairs(CLASSES) do
    table.insert(items, { text = ns.ui.classColor(cls) .. ns.ui.className(cls) .. "|r", func = function()
      filter.class = cls
      classButton:SetText(ns.ui.className(cls))
      refresh()
    end })
  end
  ns.ui.popup(classButton, items)
end

local function roleMenu()
  local items = { { text = "All roles", func = function()
    filter.role = nil
    roleButton:SetText("Role: all")
    refresh()
  end } }
  for _, role in ipairs(ROLES) do
    table.insert(items, { text = role, func = function()
      filter.role = role
      roleButton:SetText(role)
      refresh()
    end })
  end
  ns.ui.popup(roleButton, items)
end

local function create()
  if frame then return frame end
  local W = ns.ui
  local width = 24
  for _, c in ipairs(COLUMNS) do width = width + c.width end
  frame = W.window("GFoAGuildSyncGuildFrame", "GFoA Guild", width + 24, 144 + ROWS * ROW_H, "guildPos", "guild")
  local top = frame.top

  -- Filters
  local online = W.check(frame, "Online only", function() return filter.onlineOnly end, function(v)
    filter.onlineOnly = v
    refresh()
  end)
  online:SetPoint("TOPLEFT", 10, -top)

  classButton = W.button(frame, "Class: all", 100, 20, classMenu)
  classButton:SetPoint("TOPLEFT", 110, -top - 2)

  local lvlLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  lvlLabel:SetPoint("TOPLEFT", 222, -top - 6)
  lvlLabel:SetText("Level")
  local minBox = W.editBox(frame, 26, true, function(t)
    filter.minLevel = tonumber(t)
    refresh()
  end)
  minBox:SetPoint("TOPLEFT", 262, -top - 2)
  local dash = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dash:SetPoint("TOPLEFT", 293, -top - 6)
  dash:SetText("-")
  local maxBox = W.editBox(frame, 26, true, function(t)
    filter.maxLevel = tonumber(t)
    refresh()
  end)
  maxBox:SetPoint("TOPLEFT", 306, -top - 2)

  local searchLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  searchLabel:SetPoint("TOPLEFT", 350, -top - 6)
  searchLabel:SetText("Search")
  local search = W.editBox(frame, 160, false, function(t)
    filter.search = t
    refresh()
  end)
  search:SetPoint("TOPLEFT", 398, -top - 2)

  local scan = W.button(frame, "Rescan", 70, 20, function() if ns.refreshRoster then ns.refreshRoster(true) end end)
  scan:SetPoint("TOPRIGHT", -14, -top - 2)

  -- Second row: role (from the guild Discord) and alts grouped under their main
  roleButton = W.button(frame, "Role: all", 100, 20, roleMenu)
  roleButton:SetPoint("TOPLEFT", 12, -top - 26)
  local group = W.check(frame, "Group alts under their main", function() return ns.opt("guildGroupAlts", false) end,
    function(v)
      ns.setOpt("guildGroupAlts", v)
      refresh()
    end)
  group:SetPoint("TOPLEFT", 120, -top - 24)

  -- Column headers (click to sort)
  frame.headers = {}
  local x = 12
  for _, c in ipairs(COLUMNS) do
    local h = CreateFrame("Button", nil, frame)
    h:SetSize(c.width, 18)
    h:SetPoint("TOPLEFT", x, -top - 52)
    local fs = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", 2, 0)
    h.text, h.key, h.title = fs, c.key, c.title
    local hl = h:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.1)
    h:SetScript("OnClick", function()
      if sortKey == c.key then
        sortDesc = not sortDesc
      else
        sortKey, sortDesc = c.key, (c.key == "level")
      end
      refresh()
    end)
    table.insert(frame.headers, h)
    x = x + c.width
  end
  local rule = W.divider(frame)
  rule:SetPoint("TOPLEFT", 12, -top - 70)
  rule:SetPoint("TOPRIGHT", -12, -top - 70)

  -- Rows
  local list = CreateFrame("Frame", nil, frame)
  list:SetPoint("TOPLEFT", 12, -top - 72)
  list:SetSize(width - 12, ROWS * ROW_H)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    offset = offset - delta * 3
    render()
  end)
  rows = {}
  for i = 1, ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
    if i % 2 == 0 then
      local bg = row:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints()
      bg:SetColorTexture(1, 1, 1, 0.035)
    end
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(W.C.pink[1], W.C.pink[2], W.C.pink[3], 0.12)
    row.cols = {}
    local cx = 0
    for _, c in ipairs(COLUMNS) do
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("LEFT", cx + 2, 0)
      fs:SetWidth(c.width - 4)
      fs:SetJustifyH("LEFT")
      if fs.SetWordWrap then fs:SetWordWrap(false) end
      row.cols[c.key] = fs
      cx = cx + c.width
    end
    row:SetScript("OnEnter", function(self) ns.safe("guildTooltip", rowTooltip, self) end)
    row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    rows[i] = row
  end

  -- Scroll bar
  slider = CreateFrame("Slider", nil, frame)
  slider:SetOrientation("VERTICAL")
  slider:SetPoint("TOPRIGHT", -10, -top - 74)
  slider:SetSize(14, ROWS * ROW_H - 4)
  slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
  local track = slider:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(0, 0, 0, 0.4)
  slider:SetMinMaxValues(0, 0)
  slider:SetValueStep(1)
  if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
  slider:SetScript("OnValueChanged", function(self, v)
    if self.updating then return end
    offset = math.floor(v + 0.5)
    render()
  end)

  -- Empty state, centred over the list
  local empty = CreateFrame("Frame", nil, list)
  empty:SetAllPoints()
  local paw = empty:CreateTexture(nil, "ARTWORK")
  paw:SetTexture(W.TEX.paw)
  paw:SetSize(32, 32)
  paw:SetPoint("CENTER", 0, 34)
  paw:SetAlpha(0.8)
  empty.title = empty:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  empty.title:SetPoint("TOP", paw, "BOTTOM", 0, -8)
  empty.title:SetTextColor(W.C.pink[1], W.C.pink[2], W.C.pink[3])
  empty.hint = empty:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  empty.hint:SetPoint("TOP", empty.title, "BOTTOM", 0, -6)
  empty.hint:SetTextColor(0.65, 0.62, 0.70)
  empty:Hide()
  frame.empty = empty

  countText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  countText:SetPoint("BOTTOMLEFT", 12, 12)

  local legend = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  legend:SetPoint("BOTTOMRIGHT", -14, 12)
  legend:SetText(ns.CHECK .. " = on the guild Discord")

  frame:SetScript("OnShow", refresh)
  return frame
end

function ns.toggleGuildWindow(show)
  local f = create()
  if show == nil then show = not f:IsShown() end
  if show then
    f:Show()
    refresh()
  else
    f:Hide()
  end
end

ns.commands["guild"] = function() ns.toggleGuildWindow() end

-- Keep the window current when a new scan lands.
local baseUpdate = ns.updateUI
function ns.updateUI()
  if baseUpdate then baseUpdate() end
  refresh()
end
