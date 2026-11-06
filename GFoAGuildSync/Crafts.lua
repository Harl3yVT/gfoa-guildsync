-- GFoA Guild Sync: crafter lookup and craft-request notes.
--   * hold Shift while you hover an item (or click a chat link): every guild crafter, online ones first
--   * /gf who <shift-click an item>: the same list in chat (only you see it)
--   * /gf crafts: open craft requests you can make (from the Discord data, and officers' own addons), with Dismiss
-- Nothing is sent anywhere: this only reads what the addon already has.
local _, ns = ...
local L = ns.logic

-- Set of lower first names online right now: the last roster scan's online members plus you.
function ns.onlineSet()
  local set = {}
  for _, m in ipairs(ns.db and ns.db.guild and ns.db.guild.members or {}) do
    if type(m) == "table" and m.online and type(m.name) == "string" then set[string.lower(m.name)] = true end
  end
  local me = ns.unitName and ns.unitName("player")
  if type(me) == "string" then set[string.lower(me)] = true end
  return set
end

function ns.crafterLookup(itemName)
  return L.crafterLookup(ns.guildCrafters(itemName), ns.onlineSet())
end

-- Tooltip lines for the full lookup: { text, r, g, b } (at most `max` crafters).
function ns.crafterLookupLines(itemName, max)
  local list = ns.crafterLookup(itemName)
  if #list == 0 then return {} end
  max = max or 8
  local out = { { "Guild crafters (online first):", 0.83, 0.55, 1 } }
  for i = 1, math.min(max, #list) do
    local c = list[i]
    local prof = c.prof and (" - " .. c.prof .. (c.skill and (" " .. c.skill) or "")) or ""
    if c.online then
      table.insert(out, { "  " .. ns.displayName(c.name) .. prof .. "  online", 0.74, 0.89, 0.64 })
    else
      table.insert(out, { "  " .. ns.displayName(c.name) .. prof, 0.75, 0.72, 0.8 })
    end
  end
  if #list > max then table.insert(out, { "  +" .. (#list - max) .. " more", 0.65, 0.62, 0.7 }) end
  return out
end

local function itemArg(arg)
  local name = type(arg) == "string" and string.match(arg, "%[(.-)%]")
  if not name and type(arg) == "string" and arg ~= "" then name = arg end
  return name
end

ns.commands["who"] = function(arg)
  local name = itemArg(arg)
  if not name then
    ns.print("usage: /gf who <shift-click an item into the chat box>, or hold Shift over the item")
    return
  end
  local list = ns.crafterLookup(name)
  if #list == 0 then
    ns.print("no guild crafter known for " .. name .. " (the Discord data and guild sync list who knows what)")
    return
  end
  local parts = {}
  for i = 1, math.min(12, #list) do
    local c = list[i]
    table.insert(parts, (c.online and ns.ui.GOOD or "") .. ns.displayName(c.name) .. (c.online and " (online)|r" or "")
      .. (c.prof and (ns.ui.MUTED .. " " .. c.prof .. (c.skill and (" " .. c.skill) or "") .. "|r") or ""))
  end
  ns.print(name .. ": " .. table.concat(parts, ", ") .. (#list > 12 and (" +" .. (#list - 12) .. " more") or ""))
end

-- ---------------------------------------------------------------------------
-- Craft requests you can make
-- ---------------------------------------------------------------------------

local function myNames()
  local set = {}
  for name in pairs(ns.db and ns.db.characters or {}) do
    if type(name) == "string" then set[string.lower(name)] = true end
  end
  local me = ns.unitName and ns.unitName("player")
  if type(me) == "string" then set[string.lower(me)] = true end
  return set
end

-- Requests from the Discord data plus the ones an officer addon holds itself (newer than the last upload).
local function allRequests()
  local out, seen = {}, {}
  local d = ns.discordData()
  local sources = { ns.db and ns.db.craftRequests or false, d and d.craftRequests or false }
  for i = 1, #sources do
    local list = sources[i]
    for _, r in ipairs(type(list) == "table" and list or {}) do
      if type(r) == "table" and type(r.sender) == "string" then
        local k = L.craftRequestKey(r)
        if not seen[k] then
          seen[k] = true
          table.insert(out, r)
        end
      end
    end
  end
  return out
end

function ns.craftRequestsForMe()
  if not ns.cache then return {} end
  ns.cache.craftDismissed = L.pruneDismissed(ns.cache.craftDismissed, ns.now())
  return L.craftRequestsFor(allRequests(), myNames(), ns.guildCrafters, ns.cache.craftDismissed, ns.now(),
    (ns.config.craftRequestKeepDays or 7) * 86400)
end

local ROWS = 10
local frame, rows, offset = nil, {}, 0

local function render()
  if not frame or not frame:IsShown() then return end
  local W = ns.ui
  local list = ns.craftRequestsForMe()
  if offset > math.max(0, #list - ROWS) then offset = math.max(0, #list - ROWS) end
  if #list == 0 then frame.empty:Show() else frame.empty:Hide() end
  for i = 1, ROWS do
    local row, e = rows[i], list[offset + i]
    if e then
      local r = e.req
      row.text:SetText(W.PINK .. r.item .. "|r " .. W.MUTED .. "for|r " .. ns.displayName(r.sender) .. "  " .. W.MUTED .. ns.ago(r.t)
        .. "  (you: " .. table.concat(e.who, ", ") .. ")|r")
      row.key = e.key
      row:Show()
    else
      row:Hide()
    end
  end
  frame.count:SetText(W.MUTED .. #list .. " open. Whisper the asker in game or answer in the Discord crafting channel."
    .. "|r")
end

local function create()
  if frame then return frame end
  local W = ns.ui
  local f = W.window("GFoAGuildSyncCraftsFrame", "Craft requests for you", 460, 44 + ROWS * 20 + 20, "craftsPos")
  for i = 1, ROWS do
    local row = CreateFrame("Frame", nil, f)
    row:SetHeight(20)
    row:SetPoint("TOPLEFT", 12, -f.top - (i - 1) * 20)
    row:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    local btn = W.button(row, "Dismiss", 60, 18, function()
      if ns.cache and row.key then
        ns.cache.craftDismissed = type(ns.cache.craftDismissed) == "table" and ns.cache.craftDismissed or {}
        ns.cache.craftDismissed[row.key] = ns.now()
      end
      render()
      if ns.updateUI then ns.updateUI() end
    end)
    btn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", 0, 0)
    fs:SetPoint("RIGHT", btn, "LEFT", -6, 0)
    fs:SetJustifyH("LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    row.text = fs
    rows[i] = row
  end
  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.empty:SetPoint("TOPLEFT", 12, -f.top - 4)
  f.empty:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.empty:SetJustifyH("LEFT")
  f.empty:SetText("Nothing open for your crafters. Requests come from \"Ask guild crafters\" in the game and reach"
    .. " you with the Discord data (uploader) or an officer's addon.")
  if f.empty.SetWordWrap then f.empty:SetWordWrap(true) end
  f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.count:SetPoint("BOTTOMLEFT", 12, 10)
  f.count:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.count:SetJustifyH("LEFT")
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    offset = math.max(0, offset - delta * 3)
    render()
  end)
  f:SetScript("OnShow", render)
  frame = f
  return f
end

function ns.toggleCrafts(show)
  local f = create()
  if show == nil then show = not f:IsShown() end
  if show then
    f:Show()
    render()
  else
    f:Hide()
  end
end

-- One line for the minimap tooltip / status, or nil.
function ns.craftNoteLine()
  local n = #ns.craftRequestsForMe()
  if n == 0 then return nil end
  return n .. " craft request" .. (n == 1 and "" or "s") .. " you can make (/gf crafts)"
end

ns.commands["crafts"] = function() ns.toggleCrafts() end
ns.commands["requests"] = ns.commands["crafts"]

-- One chat line after login when something is open for you (Options: "Tell me about craft requests").
ns.on("PLAYER_LOGIN", function()
  ns.after(25, "craftNotes", function()
    if not ns.opt("craftNotes", false) then return end
    local line = ns.craftNoteLine()
    if line then ns.print(line) end
  end)
end)
