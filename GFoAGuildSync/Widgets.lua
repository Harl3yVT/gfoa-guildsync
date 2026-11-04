-- GFoA Guild Sync: tiny widget helpers (plain frames and stock templates only; nothing secure or protected).
local _, ns = ...

local W = {}
ns.ui = W

function W.backdrop(f, alpha)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.08, 0.05, 0.12, alpha or 0.92)
  else
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.08, 0.05, 0.12, alpha or 0.92)
  end
end

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil
W.BACKDROP_TEMPLATE = BACKDROP_TEMPLATE

-- A movable window with a title and close button; Escape closes it; position saved per character under posKey.
function W.window(name, title, width, height, posKey)
  local f = CreateFrame("Frame", name, UIParent, BACKDROP_TEMPLATE)
  f:SetSize(width, height)
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
  local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  t:SetPoint("TOPLEFT", 10, -9)
  t:SetText(title)
  f.title = t
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)
  close:SetScript("OnClick", function() f:Hide() end)
  if name and type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, name) end
  f:Hide()
  return f
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
function W.popup(anchor, items)
  if not popup then
    popup = CreateFrame("Frame", "GFoAGuildSyncPopup", UIParent, BACKDROP_TEMPLATE)
    popup:SetFrameStrata("DIALOG")
    popup:SetClampedToScreen(true)
    popup:EnableMouse(true)
    W.backdrop(popup, 0.97)
    popup.buttons = {}
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "GFoAGuildSyncPopup") end
  end
  if popup:IsShown() and popup.anchor == anchor then
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
      hl:SetColorTexture(1, 1, 1, 0.12)
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
