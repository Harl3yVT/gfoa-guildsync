-- GFoA Guild Sync: minigames window (/gf pegs). Paw Drop, a peg-and-ball game of our own (docs/minigames.md),
-- with the account's best scores in GFoAGuildSyncDB.minigames and guildmates' bests heard over hidden addon
-- messages (M / M?) in GFoAGuildSyncCache.games. Opens itself on flight paths / AFK only when that option is on.
-- Logic and physics live in GameLogic.lua; this file only draws and handles input.
local _, ns = ...
local L = ns.logic
local P = L.PAW

local GAME = "paw"
local frame, canvas, hud, status, boardPanel, boardText, boardChip
local pegTex, ballTex, basketTex, aimDots = {}, nil, nil, {}
local game
local lastAim
local autoOpened      -- "taxi" / "afk" while the window opened itself and nobody has shot yet
local boardBy = "best"

local COLORS = {
  blue = { 0.663, 0.898, 0.961 },   -- #A9E5F5
  pink = { 0.976, 0.722, 0.831 },   -- #F9B8D4
  gold = { 1.0, 0.784, 0.4 },
}

-- ---------------------------------------------------------------------------
-- Saved scores
-- ---------------------------------------------------------------------------

local function myRecord()
  local db = ns.db
  if type(db.minigames) ~= "table" then db.minigames = {} end
  if type(db.minigames[GAME]) ~= "table" then db.minigames[GAME] = {} end
  return db.minigames[GAME]
end

local function peers()
  local c = ns.cache
  if type(c) ~= "table" then return {} end
  if type(c.games) ~= "table" then c.games = {} end
  if type(c.games[GAME]) ~= "table" then c.games[GAME] = {} end
  local t = c.games[GAME]
  for who, e in pairs(t) do
    if type(e) ~= "table" or ns.now() - (e.t or 0) > 30 * 86400 then t[who] = nil end
  end
  return t
end

-- ---------------------------------------------------------------------------
-- Guild scores (hidden addon messages on the GFOA prefix, through Comm.lua's one-per-second queue)
-- ---------------------------------------------------------------------------

local lastQuery, lastReply = 0, 0

local function canShare()
  return ns.opt("shareGameScores", true) and ns.call("IsInGuild") and ns.registerCommPrefix
    and ns.registerCommPrefix() and ns.queueComm
end

local function sendScore()
  local rec = myRecord()
  if (rec.best or 0) <= 0 or not canShare() then return end
  ns.queueComm(L.gameScoreMessage(GAME, rec, ns.now()))
end

local function queryScores()
  if not canShare() or ns.now() - lastQuery < 300 then return end
  lastQuery = ns.now()
  ns.queueComm("M?")
end
ns.queryGameScores = queryScores

-- Rows for the guild window's "Paw Drop" leaderboard: names shown as "First Surname", class colour from the
-- last roster scan. keep(name) as in L.leaderboardRows.
function ns.gameLeaderboardRows(by, keep)
  local me = ns.call("UnitName", "player")
  local class = {}
  for _, m in ipairs(ns.db and ns.db.guild and ns.db.guild.members or {}) do
    if type(m) == "table" and type(m.name) == "string" then class[string.lower(m.name)] = m.class end
  end
  local rows = L.gameLeaderboardRows(peers(), myRecord(), me, by, ns.now())
  local out = {}
  for _, r in ipairs(rows) do
    local short = r.name
    r.name = ns.displayName and ns.displayName(short) or short
    r.class = class[string.lower(short)] or ""
    if not keep or keep(r.name) or r.mine then table.insert(out, r) end
  end
  return out
end

ns.on("CHAT_MSG_ADDON", function(_, prefix, msg, channel, sender)
  if prefix ~= L.COMM_PREFIX or channel ~= "GUILD" or type(msg) ~= "string" or ns.isSecret(msg) then return end
  local kind, game_, best, weekBest, week = L.parseGameMessage(msg)
  if not kind then return end
  local who = ns.shortName(sender)
  if not who or who == ns.call("UnitName", "player") then return end
  if kind == "M?" then
    if ns.now() - lastReply < 60 then return end
    lastReply = ns.now()
    ns.after(2 + math.random(0, 8), "gameReply", sendScore)
  elseif kind == "M" and game_ == GAME then
    peers()[who] = { best = best, weekBest = weekBest, week = week, t = ns.now() }
    if boardPanel and boardPanel:IsShown() then ns.safe("gameBoard", ns.refreshGameBoard) end
    if ns.refreshGuildWindow then ns.refreshGuildWindow() end   -- returns at once when it's closed
  end
end)

ns.on("PLAYER_LOGIN", function()
  ns.after(70 + math.random(0, 40), "gameLogin", sendScore)
end)

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

local function place(tex, x, y)
  tex:ClearAllPoints()
  tex:SetPoint("CENTER", canvas, "TOPLEFT", x, -y)
end

local function dot(size, layer)
  local t = canvas:CreateTexture(nil, layer or "ARTWORK")
  t:SetTexture(ns.ui.TEX.dot)
  t:SetSize(size, size)
  return t
end

local function drawPegs()
  for i, p in ipairs(game.pegs) do
    local t = pegTex[i]
    if not t then
      t = dot(P.PEG_R * 2 + 2)
      pegTex[i] = t
    end
    if p.gone then
      t:Hide()
    else
      local c = COLORS[p.kind] or COLORS.blue
      if p.lit then
        t:SetVertexColor(1, 1, 1, 1)
        t:SetSize(P.PEG_R * 2 + 5, P.PEG_R * 2 + 5)
      else
        t:SetVertexColor(c[1], c[2], c[3], 0.95)
        t:SetSize(P.PEG_R * 2 + 2, P.PEG_R * 2 + 2)
      end
      place(t, p.x, p.y)
      t:Show()
    end
  end
  for i = #game.pegs + 1, #pegTex do pegTex[i]:Hide() end
end

local function drawAim(pts)
  for i = 1, 30 do
    local d = aimDots[i]
    if not d then
      d = dot(4, "BORDER")
      d:SetVertexColor(0.93, 0.9, 0.95, 0.55)
      aimDots[i] = d
    end
    local pt = pts and pts[i]
    if pt then
      place(d, pt.x, pt.y)
      d:Show()
    else
      d:Hide()
    end
  end
end

local function cursorBoardPos()
  local s = canvas:GetEffectiveScale()
  local cx, cy = GetCursorPosition()
  local left, top = canvas:GetLeft(), canvas:GetTop()
  if not left or not top or not s or s == 0 then return nil end
  return cx / s - left, top - cy / s
end

local function hudText()
  local W = ns.ui
  local rec = myRecord()
  local cleared = game.pinkTotal - game.pinkLeft
  return string.format("%sBalls|r %d   %sScore|r %d   %sPink|r %d/%d   %sx%d|r   %sBest %d|r",
    W.MUTED, game.balls, W.MUTED, game.score, W.MUTED, cleared, game.pinkTotal,
    W.PINK, L.pawMultiplier(cleared), W.MUTED, rec.best or 0)
end

local function setStatus(text)
  status:SetText(text or "")
end

local function gameOver()
  local won = game.state == "won"
  local me = ns.call("UnitName", "player")
  local newBest = L.gameRecord(myRecord(), game.score, won, ns.now(), me)
  local W = ns.ui
  local line = (won and (W.GOOD .. "Board cleared!|r ") or (W.WAIT .. "Out of balls.|r ")) .. "Score " .. game.score
  if newBest then
    line = line .. "  " .. W.PINK .. "New best!|r"
    ns.after(30, "gameBest", sendScore)
  end
  setStatus(line .. "  " .. W.MUTED .. "New game to play again.|r")
end

local function drainEvents()
  local W = ns.ui
  for _, e in ipairs(game.events) do
    if e.kind == "free" then
      setStatus(W.GOOD .. "Caught! Free ball.|r")
    elseif e.kind == "gold" then
      setStatus(W.PINK .. "Gold paw: +1 ball|r")
    elseif e.kind == "shot" then
      if (e.value or 0) > 0 then setStatus("Shot: +" .. e.value) end
    elseif e.kind == "won" or e.kind == "lost" then
      gameOver()
    end
  end
  game.events = {}
end

local function render()
  if not game then return end
  drawPegs()
  if game.ball then
    place(ballTex, game.ball.x, game.ball.y)
    ballTex:Show()
  else
    ballTex:Hide()
  end
  place(basketTex, L.pawBasketX(game.t), P.BASKET_Y + 5)
  hud:SetText(hudText())
end

local function newGame()
  game = L.pawNewGame(math.random)
  lastAim = nil
  setStatus(ns.ui.MUTED .. game.layoutName .. ": clear the 15 pink pegs. Click to shoot.|r")
  render()
end

local function onUpdate(_, elapsed)
  if not game then return end
  L.pawUpdate(game, elapsed)
  if #game.events > 0 then drainEvents() end
  if game.state == "aim" and not (boardPanel and boardPanel:IsShown()) then
    local x, y = cursorBoardPos()
    if x then
      local a = L.pawAimAt(x, y)
      if not lastAim or math.abs(a - lastAim) > 0.002 then
        lastAim = a
        drawAim(L.pawPreview(game, a, 30))
      end
    end
  elseif lastAim then
    lastAim = nil
    drawAim(nil)
  end
  render()
end

local function shoot()
  if not game or game.state ~= "aim" or (boardPanel and boardPanel:IsShown()) then return end
  local x, y = cursorBoardPos()
  if not x then return end
  if L.pawFire(game, L.pawAimAt(x, y)) then
    autoOpened = nil   -- somebody is playing: it stays open after landing / coming back
    lastAim = nil
    drawAim(nil)
  end
end

-- ---------------------------------------------------------------------------
-- Guild scores panel (over the board)
-- ---------------------------------------------------------------------------

function ns.refreshGameBoard()
  if not boardPanel then return end
  local W = ns.ui
  local me = ns.call("UnitName", "player")
  local rows = L.gameBoard(peers(), myRecord(), me, boardBy, ns.now())
  local out = { W.headerLine(boardBy == "week" and "This week" or "All time",
    "best Paw Drop scores from guildmates' addons") , "" }
  if #rows == 0 then
    for _, l in ipairs(W.emptyLines("No scores yet", "Guildmates show up here once they've played (and are online).")) do
      table.insert(out, l)
    end
  end
  for i, r in ipairs(rows) do
    if i > 18 then break end
    local v = boardBy == "week" and r.week or r.best
    local name = r.mine and (W.PINK .. r.name .. " (you)|r") or r.name
    table.insert(out, string.format("%s%2d.|r  %s  %s%d|r", W.MUTED, i, name, W.GOOD, v))
  end
  boardText:SetText(table.concat(out, "\n"))
  boardChip:SetText(boardBy == "week" and "Show all time" or "Show this week")
end

local function toggleBoard()
  if boardPanel:IsShown() then
    boardPanel:Hide()
  else
    boardPanel:Show()
    queryScores()
    ns.refreshGameBoard()
  end
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local function create()
  local W = ns.ui
  frame = W.window("GFoAGuildSyncGamesFrame", "Paw Drop", P.W + 20, P.H + 28 + 24 + 34, "gamesPos")

  hud = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hud:SetPoint("TOPLEFT", 12, -frame.top)
  hud:SetJustifyH("LEFT")

  canvas = CreateFrame("Frame", nil, frame)
  canvas:SetSize(P.W, P.H)
  canvas:SetPoint("TOPLEFT", 10, -(frame.top + 18))
  if canvas.SetClipsChildren then canvas:SetClipsChildren(true) end
  local bg = canvas:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(W.C.plum[1], W.C.plum[2], W.C.plum[3], 0.9)
  canvas:EnableMouse(true)
  canvas:SetScript("OnMouseDown", function() ns.safe("gameShoot", shoot) end)

  local launcher = canvas:CreateTexture(nil, "ARTWORK")
  launcher:SetTexture(W.TEX.paw)
  launcher:SetSize(22, 22)
  place(launcher, P.LAUNCH_X, P.LAUNCH_Y - 4)

  basketTex = canvas:CreateTexture(nil, "ARTWORK")
  basketTex:SetTexture(W.TEX.pill)
  basketTex:SetSize(P.BASKET_W, 12)
  basketTex:SetVertexColor(W.C.pink[1], W.C.pink[2], W.C.pink[3], 0.9)

  ballTex = dot(P.BALL_R * 2 + 2, "OVERLAY")
  ballTex:SetVertexColor(1, 1, 1, 1)

  boardPanel = CreateFrame("Frame", nil, canvas, W.BACKDROP_TEMPLATE)
  boardPanel:SetPoint("TOPLEFT", 16, -16)
  boardPanel:SetPoint("BOTTOMRIGHT", -16, 16)
  boardPanel:SetFrameLevel(canvas:GetFrameLevel() + 5)
  W.backdrop(boardPanel, 0.97)
  boardPanel:EnableMouse(true)
  boardText = boardPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  boardText:SetPoint("TOPLEFT", 14, -14)
  boardText:SetPoint("RIGHT", -14, 0)
  boardText:SetJustifyH("LEFT")
  boardText:SetJustifyV("TOP")
  boardText:SetSpacing(3)
  boardChip = W.button(boardPanel, "Show this week", 120, 20, function()
    boardBy = boardBy == "week" and "best" or "week"
    ns.refreshGameBoard()
  end)
  boardChip:SetPoint("BOTTOMLEFT", 12, 12)
  local close = W.button(boardPanel, "Back to the game", 120, 20, toggleBoard)
  close:SetPoint("BOTTOMRIGHT", -12, 12)
  boardPanel:Hide()

  local newBtn = W.button(frame, "New game", 90, 22, newGame)
  newBtn:SetPoint("BOTTOMLEFT", 10, 8)
  local scoresBtn = W.button(frame, "Guild scores", 100, 22, toggleBoard)
  scoresBtn:SetPoint("LEFT", newBtn, "RIGHT", 6, 0)
  status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("LEFT", scoresBtn, "RIGHT", 8, 0)
  status:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)

  frame:SetScript("OnShow", function()
    if not game then newGame() end
    frame:SetScript("OnUpdate", function(self, elapsed) ns.safe("gameUpdate", onUpdate, self, elapsed) end)
  end)
  frame:SetScript("OnHide", function()
    frame:SetScript("OnUpdate", nil)   -- nothing runs while the window is closed; the game waits where it was
    autoOpened = nil
  end)
end

function ns.toggleGames(show)
  if not frame then create() end
  if show == nil then show = not frame:IsShown() end
  frame:SetShown(show and true or false)
end

-- ---------------------------------------------------------------------------
-- Open on flight paths / AFK (option "gamesAutoOpen", off by default)
-- ---------------------------------------------------------------------------

local function inCombat()
  return ns.call("InCombatLockdown") or ns.call("UnitAffectingCombat", "player")
end

local function autoOpen(reason)
  if not ns.opt("gamesAutoOpen", false) or inCombat() then return end
  if frame and frame:IsShown() then return end
  ns.toggleGames(true)
  autoOpened = reason
end

local function autoClose(reason)
  if autoOpened ~= reason then return end
  autoOpened = nil
  if frame and frame:IsShown() and not (game and game.state == "fly") then frame:Hide() end
end

ns.on("PLAYER_CONTROL_LOST", function()
  ns.after(1, "gamesTaxi", function()
    if ns.call("UnitOnTaxi", "player") then autoOpen("taxi") end
  end)
end)
ns.on("PLAYER_CONTROL_GAINED", function() autoClose("taxi") end)
ns.on("PLAYER_FLAGS_CHANGED", function(_, unit)
  if unit and unit ~= "player" then return end
  if ns.call("UnitIsAFK", "player") then autoOpen("afk") else autoClose("afk") end
end)
ns.on("PLAYER_REGEN_DISABLED", function()
  -- pulled while it opened itself: get it out of the way
  if autoOpened then
    autoOpened = nil
    if frame then frame:Hide() end
  end
end)

ns.commands["pegs"] = function() ns.toggleGames() end
ns.commands["pawdrop"] = ns.commands["pegs"]
ns.commands["games"] = ns.commands["pegs"]
ns.commands["peggle"] = ns.commands["pegs"]

-- Short slash commands of their own: /pawdrop and /peggle open the same window as /gf pegs.
SLASH_GFOAPAWDROP1 = "/pawdrop"
SLASH_GFOAPAWDROP2 = "/peggle"
SlashCmdList["GFOAPAWDROP"] = function() ns.safe("slash", ns.toggleGames) end
