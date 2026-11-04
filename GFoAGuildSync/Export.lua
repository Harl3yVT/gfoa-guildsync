-- GFoA Guild Sync: /gfoa export -> "GFOA1.<crc32>.<base64 JSON>" of your own characters, shown in a selectable box
-- to copy into the guild Discord ("Import from addon"). Read only: copying is done by the player (Ctrl+A, Ctrl+C).
local _, ns = ...
local L = ns.logic

local frame, edit, partLabel, info
local parts, partIndex = { "" }, 1

local function showPart()
  local text = parts[partIndex] or ""
  edit:SetText(text)
  edit:SetCursorPosition(0)
  edit:HighlightText()
  edit:SetFocus()
  partLabel:SetText(#parts > 1 and string.format("Part %d/%d", partIndex, #parts) or "")
  if frame.prev then
    if #parts > 1 then
      frame.prev:Show()
      frame.next:Show()
    else
      frame.prev:Hide()
      frame.next:Hide()
    end
  end
end

local function create()
  if frame then return frame end
  local W = ns.ui
  frame = W.window("GFoAGuildSyncExportFrame", "Export for Discord", 460, 300, "exportPos")

  info = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  info:SetPoint("TOPLEFT", 12, -30)
  info:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
  info:SetJustifyH("LEFT")

  local scroll = CreateFrame("ScrollFrame", "GFoAGuildSyncExportScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -72)
  scroll:SetPoint("BOTTOMRIGHT", -32, 40)
  local bg = frame:CreateTexture(nil, "ARTWORK")
  bg:SetPoint("TOPLEFT", scroll, "TOPLEFT", -4, 4)
  bg:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 4, -4)
  bg:SetColorTexture(0, 0, 0, 0.5)

  edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject(ChatFontSmall and "ChatFontSmall" or "GameFontHighlightSmall")
  edit:SetWidth(400)
  if edit.SetMaxLetters then edit:SetMaxLetters(0) end
  edit:SetScript("OnEscapePressed", function() frame:Hide() end)
  -- Typing doesn't change the export: put the text back and keep it selected.
  edit:SetScript("OnTextChanged", function(self, userInput)
    if userInput then
      self:SetText(parts[partIndex] or "")
      self:HighlightText()
    end
  end)
  edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  edit:SetScript("OnMouseUp", function(self) self:HighlightText() end)
  scroll:SetScrollChild(edit)

  partLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  partLabel:SetPoint("BOTTOM", 0, 14)

  frame.prev = W.button(frame, "< Prev", 70, 20, function()
    if partIndex > 1 then
      partIndex = partIndex - 1
      showPart()
    end
  end)
  frame.prev:SetPoint("BOTTOMLEFT", 12, 10)
  frame.next = W.button(frame, "Next >", 70, 20, function()
    if partIndex < #parts then
      partIndex = partIndex + 1
      showPart()
    end
  end)
  frame.next:SetPoint("BOTTOMRIGHT", -12, 10)
  return frame
end

function ns.showExport()
  if ns.refreshCharacter then ns.refreshCharacter() end
  local s, droppedOrReason = L.makeExport(ns.db.characters, ns.now(), ns.call("GetRealmName"), ns.ADDON_VERSION,
    { link = ns.db.link, main = ns.db.main })
  if not s then
    ns.print("export: " .. tostring(droppedOrReason))
    return
  end
  parts = L.splitParts(s, L.EXPORT_PART)
  partIndex = 1
  create()
  local n = math.min(L.EXPORT_MAX_CHARS, ns.count(ns.db.characters))
  local lines = {
    string.format("Your %d character(s) on this PC, %d characters of text. Press Ctrl+A then Ctrl+C,", n, #s),
    "then paste it in Discord: guild panel > Import from addon."
      .. (#parts > 1 and " Paste each part in its own box, in order." or ""),
  }
  if droppedOrReason == true then table.insert(lines, "|cffffcc00Recipes left out to fit.|r") end
  info:SetText(table.concat(lines, "\n"))
  frame:Show()
  showPart()
end

ns.commands["export"] = function() ns.showExport() end
