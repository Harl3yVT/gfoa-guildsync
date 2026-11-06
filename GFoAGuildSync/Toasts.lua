-- GFoA Guild Sync: opt-in toasts (off by default; /gf toasts on, or the Options checkbox).
--   * "Up to #2 on Most quests turned in": one of your characters moved up a shared stats leaderboard (the order
--     comes with the Discord data, so you see it after the uploader ran and you /reload or log in)
--   * "Thrall reached level 60!": a guildie dinged 60 between two roster scans
-- A small frame near the top of the screen that fades out by itself after a few seconds. No sound, no chat.
local _, ns = ...
local L = ns.logic

local SHOW_SECONDS, FADE_SECONDS, MAX_BATCH = 5, 1, 3
local queue, toast, shownAt = {}, nil, nil

local function create()
  if toast then return toast end
  local W = ns.ui
  local f = CreateFrame("Frame", "GFoAGuildSyncToast", UIParent, W.BACKDROP_TEMPLATE)
  f:SetSize(320, 46)
  f:SetPoint("TOP", UIParent, "TOP", 0, -150)
  f:SetFrameStrata("HIGH")
  W.backdrop(f, 0.92)
  local icon = f:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(W.TEX.paw)
  icon:SetSize(24, 24)
  icon:SetPoint("LEFT", 10, 0)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 2)
  title:SetPoint("RIGHT", f, "RIGHT", -10, 0)
  title:SetJustifyH("LEFT")
  title:SetTextColor(W.C.pink[1], W.C.pink[2], W.C.pink[3])
  local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
  text:SetPoint("RIGHT", f, "RIGHT", -10, 0)
  text:SetJustifyH("LEFT")
  f.title, f.text = title, text
  f:EnableMouse(true)
  f:SetScript("OnMouseUp", function(self) self:Hide() end)   -- click to dismiss
  f:SetScript("OnUpdate", function(self)
    if not shownAt then return end
    local age = (GetTime and GetTime() or ns.now()) - shownAt
    if age >= SHOW_SECONDS + FADE_SECONDS then
      self:Hide()
    elseif age > SHOW_SECONDS then
      self:SetAlpha(1 - (age - SHOW_SECONDS) / FADE_SECONDS)
    end
  end)
  f:SetScript("OnHide", function()
    shownAt = nil
    if #queue > 0 then ns.after(1, "toastNext", ns.nextToast) end
  end)
  f:Hide()
  toast = f
  return f
end

function ns.nextToast()
  if #queue == 0 or (toast and toast:IsShown()) then return end
  local item = table.remove(queue, 1)
  local f = create()
  f.title:SetText(item.title)
  f.text:SetText(item.text)
  f:SetAlpha(1)
  shownAt = GetTime and GetTime() or ns.now()
  f:Show()
end

function ns.toast(title, text)
  if not ns.opt("toasts", false) then return end
  table.insert(queue, { title = title, text = text })
  ns.nextToast()
end

-- Several at once (a long time away): the first few, then one "and N more".
local function toastBatch(title, texts)
  for i = 1, math.min(MAX_BATCH, #texts) do ns.toast(title, texts[i]) end
  if #texts > MAX_BATCH then ns.toast(title, "... and " .. (#texts - MAX_BATCH) .. " more") end
end

-- Leaderboards: compare each of your characters' ranks with what this PC saw last time (account-wide cache, only
-- ranks, no values). The first look only remembers.
local function checkBoards()
  local d = ns.discordData()
  if not ns.cache or not d or type(d.boards) ~= "table" then return end
  local seen = type(ns.cache.boardRanks) == "table" and ns.cache.boardRanks or {}
  if seen.generated == d.generated then return end
  local texts, ranks = {}, {}
  for name in pairs(ns.db and ns.db.characters or {}) do
    local now = L.boardRanks(d.boards, name)
    if next(now) then ranks[name] = now end
    local old = type(seen.ranks) == "table" and seen.ranks[name] or (seen.generated and {} or nil)
    for _, m in ipairs(L.boardMoves(old, now)) do table.insert(texts, ns.displayName(name) .. ": " .. L.boardMoveText(m)) end
  end
  ns.cache.boardRanks = { generated = d.generated, ranks = ranks }
  toastBatch("Guild leaderboard", texts)
end

-- Dings: Roster.lua calls this after each scan with the levels of the scan before.
function ns.onRosterScan(oldLevels, members)
  if not ns.opt("toasts", false) then return end
  local mine = ns.db and ns.db.characters or {}
  local texts = {}
  for _, name in ipairs(L.dings(oldLevels, members)) do
    if not mine[name] then table.insert(texts, ns.displayName(name) .. " reached level " .. L.MAX_LEVEL .. "!") end
  end
  toastBatch("Guild", texts)
end

ns.commands["toasts"] = function(arg)
  if arg == "on" or arg == "off" then
    ns.setOpt("toasts", arg == "on")
  else
    ns.setOpt("toasts", not ns.opt("toasts", false))
  end
  local on = ns.opt("toasts", false)
  ns.print("toasts " .. (on and "on: leaderboard moves and guildies reaching 60" or "off"))
  if on then
    ns.toast("GFoA Guild Sync", "Toasts are on. Click one to close it.")
    checkBoards()
  end
end

ns.on("PLAYER_LOGIN", function()
  ns.after(30, "toastBoards", function()
    -- Remember ranks even while toasts are off, so turning them on later doesn't replay old moves.
    if ns.opt("toasts", false) then checkBoards() else
      local d = ns.discordData()
      if ns.cache and d and type(d.boards) == "table" then
        local ranks = {}
        for name in pairs(ns.db and ns.db.characters or {}) do
          local now = L.boardRanks(d.boards, name)
          if next(now) then ranks[name] = now end
        end
        ns.cache.boardRanks = { generated = d.generated, ranks = ranks }
      end
    end
  end)
end)
