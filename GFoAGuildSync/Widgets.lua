-- GFoA Guild Sync: tiny widget helpers (plain frames and stock templates only; nothing secure or protected).
-- Look: "A · Paw Sticker" (design canvas "GFoA Guild Sync look"): dark plum frames, pink title with a little paw,
-- a thin pastel rainbow rule under it, pink active tab. Textures are our own, drawn by guildbot/assets/make_assets.py.
local _, ns = ...

local W = {}
ns.ui = W

W.MEDIA = "Interface\\AddOns\\GFoAGuildSync\\Media\\"
W.TEX = {
  white = W.MEDIA .. "white", paw = W.MEDIA .. "paw", rule = W.MEDIA .. "rule", pill = W.MEDIA .. "pill",
  minimap = W.MEDIA .. "minimap",
}
-- Palette (0-1 RGB) and matching colour escapes.
W.C = {
  bg = { 0.082, 0.071, 0.106 },      -- #15121B
  border = { 0.227, 0.196, 0.271 },  -- #3A3245
  chip = { 0.165, 0.141, 0.200 },    -- #2A2433
  plum = { 0.169, 0.133, 0.208 },    -- #2B2235
  pink = { 0.976, 0.722, 0.831 },    -- #F9B8D4
  text = { 0.929, 0.902, 0.949 },    -- #EDE6F2
}
W.PINK = "|cfff9b8d4"
W.MUTED = "|cffa79db3"   -- hints and secondary text (readable on the dark frame)
W.GOOD = "|cffbde3a3"    -- online / ready (pastel green)
W.WAIT = "|cffffc891"    -- waiting cooldowns (pastel orange)

-- Pink section header line for text lists, with an optional muted note after it.
function W.headerLine(text, extra)
  return W.PINK .. text .. "|r" .. (extra and (" " .. W.MUTED .. extra .. "|r") or "")
end

-- Empty state for text lists: a small paw, a pink line and a muted hint.
function W.emptyLines(title, hint)
  local out = { "    |T" .. W.TEX.paw .. ":14|t " .. W.PINK .. title .. "|r" }
  if hint then table.insert(out, "    " .. W.MUTED .. hint .. "|r") end
  return out
end

function W.backdrop(f, alpha)
  local bg, edge = W.C.bg, W.C.border
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = W.TEX.white, edgeFile = W.TEX.white, tile = false, edgeSize = 1,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(bg[1], bg[2], bg[3], alpha or 0.95)
    if f.SetBackdropBorderColor then f:SetBackdropBorderColor(edge[1], edge[2], edge[3], 1) end
  else
    local t = f:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(bg[1], bg[2], bg[3], alpha or 0.95)
  end
end

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil
W.BACKDROP_TEMPLATE = BACKDROP_TEMPLATE

-- Title row: paw icon, pink title, rainbow rule underneath. Content starts W.TOP px below the frame's top edge.
W.TOP = 36
function W.header(f, title)
  local icon = f:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(W.TEX.paw)
  icon:SetSize(16, 16)
  icon:SetPoint("TOPLEFT", 9, -7)
  local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  t:SetPoint("LEFT", icon, "RIGHT", 5, 0)
  t:SetTextColor(W.C.pink[1], W.C.pink[2], W.C.pink[3])
  t:SetText(title)
  local rule = f:CreateTexture(nil, "ARTWORK")
  rule:SetTexture(W.TEX.rule)
  rule:SetHeight(2)
  rule:SetPoint("TOPLEFT", 10, -28)
  rule:SetPoint("TOPRIGHT", -10, -28)
  f.title, f.titleIcon, f.rule = t, icon, rule
  return t
end

-- Thin divider line (under column headers).
function W.divider(parent)
  local d = parent:CreateTexture(nil, "ARTWORK")
  d:SetHeight(1)
  d:SetColorTexture(W.C.border[1], W.C.border[2], W.C.border[3], 1)
  return d
end

-- A movable window with a title and close button; Escape closes it; position saved per character under posKey.
-- height is measured as if the title bar were 28 px (the old layout); the paw header, and the tab row when navKey is
-- given, are added on top. Content starts f.top px below the top edge.
function W.window(name, title, width, height, posKey, navKey)
  local top = W.TOP + (navKey and 24 or 0)
  local f = CreateFrame("Frame", name, UIParent, BACKDROP_TEMPLATE)
  f:SetSize(width, height + top - 28)
  f.top, f.posKey = top, posKey
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    if posKey and ns.settings then ns.settings[posKey] = { point, relPoint, x, y } end
  end)
  W.backdrop(f)
  local pos = posKey and ns.settings and ns.settings[posKey]
  if type(pos) == "table" and pos[1] then
    f:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
  end
  W.header(f, title)
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)
  close:SetScript("OnClick", function() f:Hide() end)
  if navKey then W.tabs(f, navKey) end
  if name and type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, name) end
  f:Hide()
  return f
end

-- ---------------------------------------------------------------------------
-- Tabs: the four everyday windows share a chip row under the title. Clicking another chip swaps windows in place
-- (opens that one where this one was, closes this one). Only ever on a click.
-- ---------------------------------------------------------------------------

W.NAV = {
  { key = "guild", text = "Guild", frame = "GFoAGuildSyncGuildFrame", open = function() ns.toggleGuildWindow(true) end },
  { key = "cooldowns", text = "Cooldowns", frame = "GFoAGuildSyncCooldownFrame",
    open = function() ns.toggleCooldowns(true) end },
  { key = "level", text = "Buddy", frame = "GFoAGuildSyncLevelFrame", open = function() ns.toggleLevelling(true) end },
  { key = "finder", text = "Finder", frame = "GFoAGuildSyncFinderFrame", open = function() ns.toggleFinder(true) end },
}

local function tint(parts, c)
  for _, t in ipairs(parts) do t:SetVertexColor(c[1], c[2], c[3], 1) end
end

-- Capsule chip: pill.tga in three slices (8 px caps, stretchy middle), tinted.
local function chip(parent, text, active)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(18)
  local parts = {}
  for i, tc in ipairs({ { 0, 0.25 }, { 0.25, 0.75 }, { 0.75, 1 } }) do
    local t = b:CreateTexture(nil, "BACKGROUND")
    t:SetTexture(W.TEX.pill)
    t:SetTexCoord(tc[1], tc[2], 0, 1)
    t:SetPoint("TOP")
    t:SetPoint("BOTTOM")
    parts[i] = t
  end
  parts[1]:SetPoint("LEFT")
  parts[1]:SetWidth(9)
  parts[3]:SetPoint("RIGHT")
  parts[3]:SetWidth(9)
  parts[2]:SetPoint("LEFT", parts[1], "RIGHT")
  parts[2]:SetPoint("RIGHT", parts[3], "LEFT")
  local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("CENTER", 0, 0)
  fs:SetText(text)
  b:SetWidth(math.max(54, (fs.GetStringWidth and fs:GetStringWidth() or 50) + 22))
  local c = active and W.C.pink or W.C.chip
  tint(parts, c)
  local tc = active and W.C.plum or W.C.text
  fs:SetTextColor(tc[1], tc[2], tc[3])
  if not active then
    b:SetScript("OnEnter", function() tint(parts, W.C.border) end)
    b:SetScript("OnLeave", function() tint(parts, c) end)
  end
  return b
end

W.chip = chip   -- also the guild window's Roster | Leaderboards switch

function W.tabs(f, activeKey)
  local prev
  for _, item in ipairs(W.NAV) do
    local b = chip(f, item.text, item.key == activeKey)
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 6, 0) else b:SetPoint("TOPLEFT", 10, -W.TOP) end
    if item.key ~= activeKey then
      b:SetScript("OnClick", function() ns.safe("tab", W.swapTo, f, item) end)
    end
    prev = b
  end
end

function W.swapTo(from, item)
  local left, top = from:GetLeft(), from:GetTop()
  item.open()
  local to = _G[item.frame]
  if to and left and top then
    to:ClearAllPoints()
    to:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    if to.posKey and ns.settings then ns.settings[to.posKey] = { "TOPLEFT", "BOTTOMLEFT", left, top } end
  end
  from:Hide()
end

function W.button(parent, text, width, height, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, height or 20)
  b:SetText(text)
  if b.GetFontString and b:GetFontString() then b:GetFontString():SetFontObject("GameFontNormalSmall") end
  b:SetScript("OnClick", function(self, button) ns.safe("button", onClick, self, button) end)
  return b
end

-- Checkbox with a label; get() returns the state, set(v) stores it.
function W.check(parent, label, get, set)
  local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  c:SetSize(24, 24)
  local fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("LEFT", c, "RIGHT", 2, 1)
  fs:SetText(label)
  c.label = fs
  c:SetScript("OnClick", function(self) ns.safe("check", set, self:GetChecked() and true or false) end)
  c.refresh = function() c:SetChecked(get() and true or false) end
  c:SetScript("OnShow", c.refresh)
  return c
end

function W.editBox(parent, width, numeric, onChange)
  local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  e:SetSize(width, 20)
  e:SetAutoFocus(false)
  if numeric and e.SetNumeric then e:SetNumeric(true) end
  if e.SetMaxLetters then e:SetMaxLetters(numeric and 2 or 40) end
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  if onChange then e:SetScript("OnTextChanged", function(self) ns.safe("edit", onChange, self:GetText() or "") end) end
  return e
end

-- ---------------------------------------------------------------------------
-- Popup menu (own frame, not UIDropDownMenu, so no shared-menu taint)
-- ---------------------------------------------------------------------------

local popup
-- noToggle: always (re)open with these items, instead of closing when opened again from the same anchor.
function W.popup(anchor, items, noToggle)
  if not popup then
    popup = CreateFrame("Frame", "GFoAGuildSyncPopup", UIParent, BACKDROP_TEMPLATE)
    popup:SetFrameStrata("DIALOG")
    popup:SetClampedToScreen(true)
    popup:EnableMouse(true)
    W.backdrop(popup, 0.97)
    popup.buttons = {}
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "GFoAGuildSyncPopup") end
  end
  if not noToggle and popup:IsShown() and popup.anchor == anchor then
    popup:Hide()
    return
  end
  popup.anchor = anchor
  local width = 140
  for i, item in ipairs(items) do
    local b = popup.buttons[i]
    if not b then
      b = CreateFrame("Button", nil, popup)
      b:SetHeight(16)
      b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 16)
      b:SetPoint("RIGHT", popup, "RIGHT", -6, 0)
      local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("LEFT", 4, 0)
      fs:SetJustifyH("LEFT")
      b.text = fs
      local hl = b:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetColorTexture(W.C.pink[1], W.C.pink[2], W.C.pink[3], 0.18)
      popup.buttons[i] = b
    end
    b.text:SetText(item.text)
    local w = (b.text.GetStringWidth and b.text:GetStringWidth() or 100) + 24
    if w > width then width = w end
    b:SetScript("OnClick", function()
      popup:Hide()
      ns.safe("menu", item.func)
    end)
    b:Show()
  end
  for i = #items + 1, #popup.buttons do popup.buttons[i]:Hide() end
  popup:SetSize(width, #items * 16 + 12)
  popup:ClearAllPoints()
  popup:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  popup:Show()
end

-- ---------------------------------------------------------------------------
-- Scrolling text list: fixed rows of font strings, mouse wheel scrolls
-- ---------------------------------------------------------------------------

function W.textList(parent, rows, rowHeight)
  rowHeight = rowHeight or 14
  local box = CreateFrame("Frame", nil, parent)
  box:EnableMouseWheel(true)
  box.lines, box.offset, box.rows = {}, 0, {}
  for i = 1, rows do
    local fs = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
    fs:SetPoint("RIGHT", box, "RIGHT", 0, 0)
    fs:SetJustifyH("LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    box.rows[i] = fs
  end
  function box:Render()
    local maxOff = math.max(0, #self.lines - rows)
    if self.offset > maxOff then self.offset = maxOff end
    if self.offset < 0 then self.offset = 0 end
    for i = 1, rows do self.rows[i]:SetText(self.lines[self.offset + i] or "") end
  end
  function box:SetLines(lines)
    self.lines = lines or {}
    self:Render()
  end
  box:SetScript("OnMouseWheel", function(self, delta)
    self.offset = self.offset - delta * 3
    self:Render()
  end)
  return box
end

-- Class colour escape for a class file name ("MAGE").
function W.classColor(class)
  local c = type(RAID_CLASS_COLORS) == "table" and class and RAID_CLASS_COLORS[class]
  if c and c.r then
    return string.format("|cff%02x%02x%02x", math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255))
  end
  return "|cffffffff"
end

function W.className(class)
  local names = type(LOCALIZED_CLASS_NAMES_MALE) == "table" and LOCALIZED_CLASS_NAMES_MALE
  if names and class and names[class] then return names[class] end
  if type(class) ~= "string" then return "?" end
  return string.sub(class, 1, 1) .. string.lower(string.sub(class, 2))
end
