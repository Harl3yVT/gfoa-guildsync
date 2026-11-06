-- GFoA Guild Sync: small status frame and minimap button.
-- Both only show information; neither does anything in game.
local _, ns = ...

local statusFrame, statusText, minimapButton

local function statusLines()
  local db = ns.db
  if not db then return "not loaded" end
  local g = db.guild
  local me = ns.call("UnitName", "player")
  local c = me and db.characters[me]
  local raid = ns.currentRaid and ns.currentRaid()
  local lines = {
    string.format("Roster: %d members (%s)", g and g.members and #g.members or 0, ns.ago(g and g.updated)),
    string.format("Characters: %d (this one %s)", ns.count(db.characters), ns.ago(c and c.updated)),
    string.format("Raids: %d  Loot: %d (>= q%d)", #db.raids, #db.loot, ns.lootMin()),
  }
  if raid then
    local snaps = raid.snapshots and #raid.snapshots or 0
    table.insert(lines, string.format("In raid: %s (%d snapshots)", tostring(raid.zone), snaps))
  end
  local run = ns.currentDungeon and ns.currentDungeon()
  if run then
    table.insert(lines, string.format("Dungeon: %s (%d bosses, %s)", tostring(run.zone), run.bossesKilled or 0,
      ns.logic.formatDuration(ns.now() - (run.start or ns.now()))))
  end
  if ns.xpStatusLine then table.insert(lines, ns.xpStatusLine()) end
  if ns.officerMode and ns.officerMode() then
    table.insert(lines, string.format("Officer mode: %d members synced, %d craft requests", ns.count(db.guildSync),
      type(db.craftRequests) == "table" and #db.craftRequests or 0))
  end
  for _, l in ipairs(ns.eventTooltipLines and ns.eventTooltipLines() or {}) do table.insert(lines, l) end
  local crafts = ns.craftNoteLine and ns.craftNoteLine()
  if crafts then table.insert(lines, crafts) end
  if ns.lastError then table.insert(lines, "|cffff8a8aErrors: " .. (ns.errorCount or 0) .. "|r") end
  table.insert(lines, ns.ui.MUTED .. "Saved on logout or /reload|r")
  return table.concat(lines, "\n")
end

function ns.updateUI()
  if statusFrame and statusText and statusFrame:IsShown() then
    statusText:SetText(statusLines())
  end
end

local function createStatusFrame()
  if statusFrame then return statusFrame end
  local f = CreateFrame("Frame", "GFoAGuildSyncStatusFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  local W = ns.ui
  f:SetSize(300, 298)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    ns.settings.framePos = { point, relPoint, x, y }
  end)
  W.backdrop(f, 0.92)
  local pos = ns.settings and ns.settings.framePos
  if type(pos) == "table" and pos[1] then
    f:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
  end

  W.header(f, "GFoA Guild Sync")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)
  close:SetScript("OnClick", function()
    f:Hide()
    ns.settings.frameShown = false
  end)

  statusText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statusText:SetPoint("TOPLEFT", 12, -W.TOP)
  statusText:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  statusText:SetJustifyH("LEFT")
  if statusText.SetJustifyV then statusText:SetJustifyV("TOP") end

  -- Buttons: the other windows.
  local buttons = {
    { "Guild", function() ns.toggleGuildWindow() end },
    { "Cooldowns", function() ns.toggleCooldowns() end },
    { "Attune", function() ns.toggleAttunements() end },
    { "Levelling", function() ns.toggleLevelling() end },
    { "Finder", function() ns.toggleFinder() end },
    { "Dungeons", function() ns.toggleDungeons() end },
    { "My stats", function() ns.toggleStats() end },
    { "Characters", function() ns.toggleCharacters() end },
    { "Options", function() ns.openOptions() end },
  }
  -- Three rows of three, then "Export for Discord" full width at the bottom.
  for i, b in ipairs(buttons) do
    local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
    local btn = W.button(f, b[1], 90, 18, b[2])
    btn:SetPoint("BOTTOMLEFT", 9 + col * 96, 28 + (2 - row) * 20)
  end
  local export = W.button(f, "Export for Discord", 282, 18, function() ns.showExport() end)
  export:SetPoint("BOTTOMLEFT", 9, 8)

  f:SetScript("OnShow", function() ns.updateUI() end)
  f:Hide()
  statusFrame = f
  return f
end

function ns.toggleFrame(show)
  local f = createStatusFrame()
  if show == nil then show = not f:IsShown() end
  ns.settings.frameShown = show and true or false
  if show then
    f:Show()
    ns.updateUI()
  else
    f:Hide()
  end
end

-- ---------------------------------------------------------------------------
-- Minimap button
-- ---------------------------------------------------------------------------

local function placeMinimapButton()
  if not minimapButton or not Minimap then return end
  -- Default bottom-right (315): the lower-left of the ring is where other addons' buttons pile up.
  local angle = math.rad(ns.settings.minimapAngle or 315)
  local radius = ((Minimap.GetWidth and Minimap:GetWidth() or 140) / 2) + 5
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function createMinimapButton()
  if minimapButton or not Minimap then return end
  local b = CreateFrame("Button", "GFoAGuildSyncMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")

  -- Our own round paw-sticker icon (Media/minimap.tga, 64x64 with alpha): no stock border needed.
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(ns.ui.TEX.minimap)
  icon:SetAllPoints()
  local glow = b:CreateTexture(nil, "HIGHLIGHT")
  glow:SetTexture(ns.ui.TEX.minimap)
  glow:SetAllPoints()
  glow:SetBlendMode("ADD")
  glow:SetAlpha(0.35)
  -- Next guild event countdown ("2h", "45m") under the icon, from the Discord data (Events.lua).
  local countdown = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  countdown:SetPoint("TOP", b, "BOTTOM", 0, 4)
  countdown:SetTextColor(ns.ui.C.pink[1], ns.ui.C.pink[2], ns.ui.C.pink[3])
  b.countdown = countdown
  b:SetScript("OnMouseDown", function() icon:SetSize(29, 29); icon:ClearAllPoints(); icon:SetPoint("CENTER") end)
  b:SetScript("OnMouseUp", function() icon:ClearAllPoints(); icon:SetAllPoints() end)

  b:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      ns.toggleGuildWindow()
    else
      ns.ui.popup(self, ns.menuItems())
    end
  end)
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      if not (mx and cx and scale) then return end
      cx, cy = cx / scale, cy / scale
      ns.settings.minimapAngle = math.deg(math.atan2(cy - my, cx - mx)) % 360
      placeMinimapButton()
    end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  b:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    local pink = ns.ui.C.pink
    GameTooltip:AddLine("|T" .. ns.ui.TEX.paw .. ":14|t GFoA Guild Sync", pink[1], pink[2], pink[3])
    GameTooltip:AddLine(statusLines(), 1, 1, 1)
    GameTooltip:AddLine("Left-click: menu. Right-click: guild window. Drag: move.", 0.65, 0.62, 0.70)
    GameTooltip:AddLine("Alt+right-click an item: ask guild crafters.", 0.65, 0.62, 0.70)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  minimapButton = b
  placeMinimapButton()
  ns.updateMinimapCountdown()
end

function ns.updateMinimapCountdown()
  if not minimapButton or not minimapButton.countdown then return end
  local text = ns.eventCountdownText and ns.eventCountdownText()
  minimapButton.countdown:SetText(text or "")
end

function ns.menuItems()
  local items = {
    { text = "Status window", func = function() ns.toggleFrame() end },
    { text = "Guild window", func = function() ns.toggleGuildWindow() end },
    { text = "Profession cooldowns", func = function() ns.toggleCooldowns() end },
    { text = "Attunements", func = function() ns.toggleAttunements() end },
    { text = "Dungeon runs", func = function() ns.toggleDungeons() end },
    { text = "Levelling and race to 60", func = function() ns.toggleLevelling() end },
    { text = "Guildie finder", func = function() ns.toggleFinder() end },
    { text = "Raid night: who's ready", func = function() ns.toggleReady() end },
    { text = "Craft requests for you", func = function() ns.toggleCrafts() end },
    { text = "My stats (private)", func = function() ns.toggleStats() end },
    { text = "My characters (Discord link)", func = function() ns.toggleCharacters() end },
    { text = "Export for Discord", func = function() ns.showExport() end },
    { text = "Options", func = function() ns.openOptions() end },
  }
  -- Sephya's GayFurriesLeaderboard ships in the same download; only listed when it's loaded.
  if _G.GayFurriesLeaderboardFrame then
    table.insert(items, 3, { text = "Guild leaderboards", func = function() ns.openLeaderboards() end })
    table.insert(items, #items, { text = "Leaderboard (Sephya's)", func = function()
      local lb = _G.GayFurriesLeaderboardFrame
      if lb then lb:SetShown(not lb:IsShown()) end
    end })
  end
  return items
end

-- Hide or show GayFurriesLeaderboard's own minimap button (setting "leaderboardMinimapHidden", per character, off by
-- default). Only Show/Hide on its frame; its position and settings stay its own.
function ns.applyLeaderboardMinimap()
  local b = _G.GayFurriesLeaderboardMinimapButton
  if not b then return end
  if ns.opt("leaderboardMinimapHidden", false) then b:Hide() else b:Show() end
end

function ns.toggleMinimap(show)
  if show == nil then show = ns.settings.minimapHidden and true or false end
  ns.settings.minimapHidden = not show
  if show then
    createMinimapButton()
    if minimapButton then minimapButton:Show() end
  elseif minimapButton then
    minimapButton:Hide()
  end
end

ns.commands["show"] = function() ns.toggleFrame() end
ns.commands["minimap"] = function(arg)
  if arg == "reset" then
    ns.settings.minimapAngle = nil
    ns.toggleMinimap(true)
    placeMinimapButton()
    ns.print("minimap button moved back to its default spot (drag it to move it)")
    return
  end
  ns.toggleMinimap()
  ns.print("minimap button " .. (ns.settings.minimapHidden and "hidden" or "shown"))
end

ns.on("PLAYER_LOGIN", function()
  if not ns.settings.minimapHidden then ns.safe("minimap", createMinimapButton) end
  if ns.settings.frameShown then ns.safe("frame", ns.toggleFrame, true) end
  ns.safe("leaderboardMinimap", ns.applyLeaderboardMinimap)
end)

ns.every(30, "ui", function() ns.updateUI() end)
