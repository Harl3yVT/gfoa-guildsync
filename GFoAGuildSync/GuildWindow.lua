-- GFoA Guild Sync: guild window (/gf guild). The last roster scan with class colours, filters and sorting, plus
-- a check mark for members registered on Discord and "alt of" from the guild's Discord data, a role filter and
-- an optional "group alts under their main" view. Display only.
-- When Sephya's GayFurriesLeaderboard is loaded, a "Roster | Leaderboards" switch shows its boards in the same list
-- (read only: we never write GayFurriesLeaderboardDB).
local _, ns = ...
local L = ns.logic

local ROWS, ROW_H = 20, 16
local COLUMNS = {
  { key = "name", title = "Name", width = 176 },   -- "First Surname"
  { key = "level", title = "Lvl", width = 34 },
  { key = "class", title = "Class", width = 66 },
  { key = "rank", title = "Rank", width = 92 },
  { key = "zone", title = "Zone", width = 140 },
  { key = "main", title = "Alt of", width = 122 },
  { key = "seen", title = "Seen", width = 62 },
}
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

-- Leaderboards view columns (same row frames, other font strings).
local LB_COLUMNS = {
  { key = "rank", title = "#", width = 44 },
  { key = "name", title = "Name", width = 260 },
  { key = "value", title = "", width = 160 },
  { key = "net", title = "Net gold", width = 160 },
}
local LB_VALUE_TITLE = { gold = "Gold", duels = "Duels won-lost", rolls = "Deathrolls won-lost" }

local frame, rows, slider, countText, classButton, roleButton, boardButton, formerCheck
local view = "roster"   -- or "leaderboards"
-- lbBy: PvP and deaths boards rank by "week" or "total" (both columns are shown; click a header to switch).
local lbBoard, lbSortKey, lbReverse, lbBy = "pvp", "rank", false, "week"
local lbShown, lbMe = {}, nil
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

local function hasLeaderboard()
  return type(_G.GayFurriesLeaderboardDB) == "table"
end

local function lbValueText(r)
  if r.crime then return ns.ui.WAIT .. (L.SHAME_CRIME[r.crime] or r.crime) .. "|r" end
  if r.week then return tostring(r.week) end
  if lbBoard == "duels" or lbBoard == "rolls" then return string.format("%d-%d", r.wins or 0, r.losses or 0) end
  if lbBoard == "gold" then return L.formatMoney(r.value) end
  return tostring(r.value)
end

local function renderLeaderboardRow(row, r)
  local W = ns.ui
  local mine = lbMe ~= nil and string.lower(r.name) == lbMe
  row.mine:SetShown(mine)
  row.lb.rank:SetText((mine and W.PINK or W.MUTED) .. r.rank .. "|r")
  row.lb.name:SetText(W.classColor(r.class ~= "" and r.class or nil) .. r.name .. "|r"
    .. (mine and (" " .. W.PINK .. "(you)|r") or ""))
  row.lb.value:SetText(lbValueText(r))
  if r.quip then
    row.lb.net:SetText(W.MUTED .. r.quip .. "|r")
  elseif r.total then
    row.lb.net:SetText(tostring(r.total))
  elseif lbBoard == "rolls" then
    local c = (r.net or 0) > 0 and W.GOOD or ((r.net or 0) < 0 and W.WAIT or W.MUTED)
    row.lb.net:SetText(c .. L.formatNetMoney(r.net, c) .. "|r")
  else
    row.lb.net:SetText("")
  end
end

local function render()
  if not frame or not frame:IsShown() then return end
  local W = ns.ui
  local discord = ns.discordData()
  local lbView = view == "leaderboards"
  local list = lbView and lbShown or shown
  local maxOff = math.max(0, #list - ROWS)
  if offset > maxOff then offset = maxOff end
  if offset < 0 then offset = 0 end
  for i = 1, ROWS do
    local row = rows[i]
    local m = (not lbView) and shown[offset + i] or nil
    local r = lbView and lbShown[offset + i] or nil
    row.member = m
    for _, fs in pairs(row.cols) do fs:SetShown(not lbView) end
    for _, fs in pairs(row.lb) do fs:SetShown(lbView) end
    if not lbView then row.mine:Hide() end
    if r then
      renderLeaderboardRow(row, r)
      row:Show()
    elseif m then
      local name = (indent[m] and (W.MUTED .. "- |r") or "") .. W.classColor(m.class) .. (ns.displayName(m.name) or "?") .. "|r"
      if ns.opt("guildCheck", true) and L.isRegistered(discord, m.name) then name = name .. " " .. ns.CHECK end
      local dim = m.online and "" or W.MUTED
      row.cols.name:SetText(name)
      row.cols.level:SetText(dim .. tostring(m.level or "?"))
      row.cols.class:SetText(W.classColor(m.class) .. W.className(m.class) .. "|r")
      row.cols.rank:SetText(dim .. (m.rank or ""))
      row.cols.zone:SetText(dim .. (m.zone or ""))
      row.cols.main:SetText(dim .. (ns.displayName(L.altOf(discord, m.name)) or ""))
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

local function refreshLeaderboards()
  local W = ns.ui
  local db = _G.GayFurriesLeaderboardDB
  local now = (type(GetServerTime) == "function" and GetServerTime()) or (ns.now and ns.now()) or 0
  -- Sephya's data never forgets people who left the guild: hide names not in our last roster scan unless the
  -- "Former members" box is ticked (per character, off by default).
  local keep = not ns.opt("lbShowFormer", false) and L.lbRosterFilter(ns.db and ns.db.guild and ns.db.guild.members)
  local roster = ns.db and ns.db.guild and ns.db.guild.members
  local all
  if L.LB_BOARD[lbBoard].game then
    all = ns.gameLeaderboardRows and ns.gameLeaderboardRows(lbBy, keep or nil) or {}
  elseif L.LB_BOARD[lbBoard].shame then
    all = L.shameRows(db, roster, 30)   -- current guildmates only, so "Former members" doesn't apply
  else
    all = L.leaderboardRows(db, lbBoard, now, lbBy, keep or nil)
  end
  lbShown = L.sortLeaderboard(all, lbSortKey, lbReverse)
  local me = L.fullName(ns.unitName("player"))
  lbMe = me and string.lower(me) or nil
  local board = L.LB_BOARD[lbBoard]
  boardButton:SetText("Board: " .. board.text)
  countText:SetText(string.format("%d on %s, from Sephya's Leaderboard", #lbShown, board.text))
  if board.game then
    countText:SetText(string.format("%d on %s, from guildmates' addons (/pawdrop to play)", #lbShown, board.text))
  end
  if board.shame then
    countText:SetText(string.format("%d on the Wall of Shame (gold hidden, or no addon and online in 30 days)",
      #lbShown))
  end
  if #lbShown == 0 then
    if board.game then
      frame.emptyState = { "No " .. board.text .. " scores yet",
        "Play with /pawdrop. Guildmates show up once they've played and are online." }
    elseif board.shame then
      frame.emptyState = { "Nobody to shame", "Everyone shares their gold and has the addon. Suspicious." }
    elseif lbBoard == "duels" or lbBoard == "rolls" then
      frame.emptyState = { "No guild " .. string.lower(board.text) .. " yet",
        "Sephya's Leaderboard records them as guildmates play." }
    else
      frame.emptyState = { "Nobody on this board yet", "Sephya's Leaderboard fills it in from guildmates' addons." }
    end
  else
    frame.emptyState = nil
  end
  local pink = W.C.pink
  local combined = board.total ~= nil   -- PvP / deaths: "This week" and "Total" side by side
  for _, h in ipairs(frame.lbHeaders) do
    local title = h.key == "value" and LB_VALUE_TITLE[lbBoard] or h.title
    local key = (h.key == "value" and (lbBoard == "duels" or lbBoard == "rolls")) and "record" or h.key
    if h.key == "net" then key = "value" end
    if board.shame and (h.key == "value" or h.key == "net") then
      title, key = (h.key == "value" and "Crime" or "Verdict"), "value"
    elseif combined and (h.key == "value" or h.key == "net") then
      local by = h.key == "value" and "week" or "total"
      title, key = (by == "week" and "This week" or (board.game and "Best ever" or "Total")), "by:" .. by
    end
    h.sortKey = key
    h:SetShown(h.key ~= "net" or lbBoard == "rolls" or combined or board.shame)
    local active = (key == lbSortKey and not (combined and key == "rank"))
      or (key == "by:" .. lbBy and lbSortKey == "rank")
    -- natural order: rank and name go up, numbers go down
    local up = (key == "rank" or key == "name") ~= lbReverse
    h.text:SetText(title .. (active and (up and " ^" or " v") or ""))
    if active then h.text:SetTextColor(pink[1], pink[2], pink[3]) else h.text:SetTextColor(0.65, 0.62, 0.70) end
  end
  render()
end

local function refresh()
  if not frame or not frame:IsShown() then return end
  frame.leaderboard:SetShown(_G.GayFurriesLeaderboardFrame ~= nil)
  local lbOk = hasLeaderboard()
  if not lbOk then view = "roster" end
  local lbView = view == "leaderboards"
  for _, c in ipairs(frame.viewChips) do c:SetShown(lbOk and ((c.view == view) ~= c.inactive)) end
  for _, w in ipairs(frame.rosterOnly) do w:SetShown(not lbView) end
  for _, h in ipairs(frame.headers) do h:SetShown(not lbView) end
  for _, h in ipairs(frame.lbHeaders) do h:SetShown(lbView) end
  boardButton:SetShown(lbView)
  formerCheck:SetShown(lbView)
  frame.legend:SetShown(not lbView)
  if lbView then return refreshLeaderboards() end
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
  GameTooltip:AddLine(ns.ui.classColor(m.class) .. (ns.displayName(m.name) or "?") .. "|r")
  GameTooltip:AddLine(string.format("Level %s %s, %s", tostring(m.level or "?"), ns.ui.className(m.class),
    m.rank or ""), 1, 1, 1)
  if m.zone and m.zone ~= "" then GameTooltip:AddLine(m.zone, 0.8, 0.8, 0.8) end
  if m.note and m.note ~= "" then GameTooltip:AddLine("Note: " .. m.note, 1, 1, 1, true) end
  if m.officerNote and m.officerNote ~= "" then GameTooltip:AddLine("Officer note: " .. m.officerNote, 1, 0.8, 0.5, true) end
  local e = L.memberEntry(discord, m.name)
  if e then
    if e.registered then GameTooltip:AddLine(ns.CHECK .. " registered on Discord", 0.74, 0.89, 0.64) end
    local altLine = L.altLine(discord, m.name, ns.displayName)
    if altLine then GameTooltip:AddLine(altLine, 0.83, 0.55, 1) end
    local alts = L.altsOf(discord, m.name)
    for i, a in ipairs(alts) do alts[i] = ns.displayName(a) end
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
  frame.rosterOnly = { online, classButton, lvlLabel, minBox, dash, maxBox, searchLabel, search, scan, roleButton, group }

  -- Sephya's GayFurriesLeaderboard ships in the same download; open its board (its own window and settings).
  frame.leaderboard = W.button(frame, "Sephya's window", 110, 20, function()
    local lb = _G.GayFurriesLeaderboardFrame
    if lb then lb:SetShown(not lb:IsShown()) end
  end)
  frame.leaderboard:SetPoint("TOPRIGHT", -14, -top - 26)

  -- Roster | Leaderboards switch, right end of the tab row (only while Sephya's data is there). Each view has an
  -- active and an inactive chip; refresh() shows the right pair.
  frame.viewChips = {}
  local prev
  for _, v in ipairs({ { "leaderboards", "Leaderboards" }, { "roster", "Roster" } }) do
    local pair = {}
    for _, active in ipairs({ true, false }) do
      local c = W.chip(frame, v[2], active)
      c.view, c.inactive = v[1], not active
      if prev then c:SetPoint("RIGHT", prev, "LEFT", -6, 0) else c:SetPoint("TOPRIGHT", -12, -W.TOP) end
      if not active then
        c:SetScript("OnClick", function()
          view, offset = v[1], 0
          refresh()
        end)
      end
      c:Hide()
      table.insert(frame.viewChips, c)
      table.insert(pair, c)
    end
    prev = pair[1]
  end

  -- Leaderboards view: board picker in place of the filters
  boardButton = W.button(frame, "Board: PvP kills", 150, 20, function()
    local items = {}
    for _, b in ipairs(L.LB_BOARDS) do
      table.insert(items, { text = b.text, func = function()
        lbBoard, lbSortKey, lbReverse, lbBy, offset = b.key, "rank", false, "week", 0
        if b.game and ns.queryGameScores then ns.queryGameScores() end
        refresh()
      end })
    end
    W.popup(boardButton, items)
  end)
  boardButton:SetPoint("TOPLEFT", 12, -top - 2)
  boardButton:Hide()
  formerCheck = W.check(frame, "Former members", function() return ns.opt("lbShowFormer", false) end, function(v)
    ns.setOpt("lbShowFormer", v)
    offset = 0
    refresh()
  end)
  formerCheck:SetPoint("TOPLEFT", 172, -top)
  formerCheck:Hide()

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
  frame.lbHeaders = {}
  x = 12
  for _, c in ipairs(LB_COLUMNS) do
    local h = CreateFrame("Button", nil, frame)
    h:SetSize(c.width, 18)
    h:SetPoint("TOPLEFT", x, -top - 52)
    local fs = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", 2, 0)
    h.text, h.key, h.title = fs, c.key, c.title
    local hl = h:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.1)
    h:SetScript("OnClick", function(self)
      local by = string.match(self.sortKey or "", "^by:(%a+)$")
      if by then   -- PvP / deaths: rank by this column
        if lbSortKey == "rank" and lbBy == by then
          lbReverse = not lbReverse
        else
          lbBy, lbSortKey, lbReverse = by, "rank", false
        end
      elseif lbSortKey == self.sortKey then
        lbReverse = not lbReverse
      else
        lbSortKey, lbReverse = self.sortKey or "rank", false
      end
      refresh()
    end)
    h:Hide()
    table.insert(frame.lbHeaders, h)
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
    -- Leaderboards view: own font strings on the same row, and a pink band on your own row
    row.mine = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.mine:SetAllPoints()
    row.mine:SetColorTexture(W.C.pink[1], W.C.pink[2], W.C.pink[3], 0.2)
    row.mine:Hide()
    row.lb = {}
    cx = 0
    for _, c in ipairs(LB_COLUMNS) do
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("LEFT", cx + 2, 0)
      fs:SetWidth(c.width - 4)
      fs:SetJustifyH("LEFT")
      if fs.SetWordWrap then fs:SetWordWrap(false) end
      fs:Hide()
      row.lb[c.key] = fs
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
  frame.legend = legend

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

-- The guild window on its Leaderboards view (Sephya's boards), from /gf lb and the minimap menu.
function ns.openLeaderboards()
  if not hasLeaderboard() then
    ns.print("no leaderboard data: GayFurriesLeaderboard isn't loaded (it ships in the same download)")
    return
  end
  view, offset = "leaderboards", 0
  ns.toggleGuildWindow(true)
end
ns.commands["lb"] = function() ns.openLeaderboards() end
ns.commands["leaderboard"] = ns.commands["lb"]

-- Keep the window current when a new scan lands.
local baseUpdate = ns.updateUI
function ns.updateUI()
  if baseUpdate then baseUpdate() end
  refresh()
end
