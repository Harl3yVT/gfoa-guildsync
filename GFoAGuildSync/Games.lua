-- GFoA Guild Sync: minigames window (/gf pegs). One window, several games of our own (docs/minigames.md): Paw Drop
-- (peg-and-ball, this file) and Paw Stack (drop-and-merge, StackGame.lua), picked with the switch button; the last
-- game played opens next time (option lastGame). The account's best scores live in GFoAGuildSyncDB.minigames[game],
-- guildmates' bests heard over hidden addon messages (M / M? / MD) in GFoAGuildSyncCache.games[game]. Opens itself on
-- flight paths, AFK and battleground queues only when that option is on. Games in progress are kept per character
-- (GFoAGuildSyncSettings.gameSave[game]) over reloads.
-- Logic and physics live in GameLogic.lua / StackLogic.lua; the game files only draw, play stock UI sounds and handle
-- input. A game registers itself with ns.registerGame(def) (see "Game modes" below).
local _, ns = ...
local L = ns.logic
local P = L.PAW

local frame, canvas, fx, hud, status, boardPanel, boardText, boardChip, actionBtn, dailyBtn, switchBtn, chBtn
local rowBtns, goalBg, goalFill = {}, nil, nil
local floaters, sparks = {}, {}
local auto = {}       -- auto-open state (L.autoQueueEvent): opened = "taxi" / "afk" / "queue" while the window opened
                      -- itself and nobody has played yet, queueDismissed = closed by the player while queued
local selfHiding      -- true while the addon hides the window itself (not a close by the player)
local boardBy = "best"
local shell = {}      -- helpers handed to every game (ns.gameShell)
ns.gameShell = shell

local COLORS = {
  blue = { 0.663, 0.898, 0.961 },   -- #A9E5F5
  pink = { 0.976, 0.722, 0.831 },   -- #F9B8D4
  gold = { 1.0, 0.784, 0.4 },
}
shell.COLORS = COLORS
local RAINBOW = { { 0.976, 0.722, 0.831 }, { 1, 0.784, 0.569 }, { 1, 0.945, 0.651 }, { 0.741, 0.89, 0.639 },
  { 0.663, 0.898, 0.961 }, { 0.741, 0.71, 0.957 } }
shell.RAINBOW = RAINBOW

-- ---------------------------------------------------------------------------
-- Game modes. def = {
--   id, title (also L.GAME_IDS[id]), build(layer) once, start(daily) a new game, resume(save) -> true when it
--   resumed, save() -> table for gameSave (nil = nothing to keep), hasGame() -> a game is loaded,
--   update(elapsed) every frame while shown, hud() -> text, click(x, y) in board units,
--   action() -> text, enabled; actionClick(); actionTip() -> title, text; busy() -> true while a ball is in flight
--   (an auto-opened window then stays open), extras() -> M message extra fields after the class (optional),
--   scoreNote(row) -> text after a row in Guild scores (optional) }
-- ---------------------------------------------------------------------------

local games, order = {}, {}
local cur   -- the def on screen

function ns.registerGame(def)
  if games[def.id] then return end
  games[def.id] = def
  table.insert(order, def.id)
end

local function current()
  return cur or games[ns.opt("lastGame", "paw")] or games.paw
end

-- ---------------------------------------------------------------------------
-- Saved scores
-- ---------------------------------------------------------------------------

local function myRecord(id)
  local db = ns.db
  if type(db.minigames) ~= "table" then db.minigames = {} end
  if type(db.minigames[id]) ~= "table" then db.minigames[id] = {} end
  return db.minigames[id]
end
shell.record = myRecord

local function peers(id)
  local c = ns.cache
  if type(c) ~= "table" then return {} end
  if type(c.games) ~= "table" then c.games = {} end
  if type(c.games[id]) ~= "table" then c.games[id] = {} end
  local t = c.games[id]
  for who, e in pairs(t) do
    if type(e) ~= "table" or ns.now() - (e.t or 0) > 30 * 86400 then t[who] = nil end
  end
  return t
end
shell.peers = peers

local function myClass()
  local _, class = ns.call("UnitClass", "player")
  return L.gameClass(ns.plain(class))
end
shell.myClass = myClass

-- ---------------------------------------------------------------------------
-- Guild scores (hidden addon messages on the GFOA prefix, through Comm.lua's one-per-second queue)
-- ---------------------------------------------------------------------------

local lastQuery, lastReply = 0, 0

local function canShare()
  return ns.opt("shareGameScores", true) and ns.call("IsInGuild") and ns.registerCommPrefix
    and ns.registerCommPrefix() and ns.queueComm
end

local function sendScore()
  if not canShare() then return end
  for _, id in ipairs(order) do
    local def, rec = games[id], myRecord(id)
    local extras = { myClass() or "" }
    for _, v in ipairs(def.extras and def.extras(rec) or {}) do table.insert(extras, v) end
    if ns.officerMode and ns.officerMode() and (rec.best or 0) > 0 then   -- my own scores for the Discord post too
      local me = ns.call("UnitName", "player")
      if me then
        L.guildGamesCopy(ns.db, id, me, { best = rec.best, weekBest = (rec.week == L.gameWeek(ns.now())) and
          rec.weekBest or 0, week = L.gameWeek(ns.now()), class = myClass(), biggest = rec.biggest }, ns.now())
      end
    end
    if (rec.best or 0) > 0 then ns.queueComm(L.gameScoreMessage(id, rec, ns.now(), extras)) end
    local daily = L.gameDailyMessage(id, rec, ns.now())
    if daily then ns.queueComm(daily) end
  end
end

local function queryScores()
  if not canShare() or ns.now() - lastQuery < 300 then return end
  lastQuery = ns.now()
  ns.queueComm("M?")
end
ns.queryGameScores = queryScores

-- Rows for the guild window's minigame leaderboards (game "paw" or "stack"): names shown as "First Surname", class
-- colour from the last roster scan. keep(name) as in L.leaderboardRows.
function ns.gameLeaderboardRows(by, keep, game)
  game = game or "paw"
  local me = ns.call("UnitName", "player")
  local class = {}
  for _, m in ipairs(ns.db and ns.db.guild and ns.db.guild.members or {}) do
    if type(m) == "table" and type(m.name) == "string" then class[string.lower(m.name)] = m.class end
  end
  local rows = L.gameLeaderboardRows(peers(game), myRecord(game), me, by, ns.now())
  local out = {}
  for _, r in ipairs(rows) do
    local short = r.name
    r.name = ns.displayName and ns.displayName(short) or short
    r.class = class[string.lower(short)] or ""
    if not keep or keep(r.name) or r.mine then table.insert(out, r) end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Guild and social (docs/minigames.md section 6): challenges by hidden whisper, the weekly pink-peg goal, badges
-- ---------------------------------------------------------------------------

local function roster()
  return ns.db and ns.db.guild and ns.db.guild.members
end

-- The guild's weekly pink-peg goal: the last one an officer's addon sent, else our own officer setting, else 1000.
local function goal()
  local heard = type(ns.cache) == "table" and type(ns.cache.gameGoal) == "table" and tonumber(ns.cache.gameGoal.goal)
  return heard or tonumber(ns.db and ns.db.gameGoal) or L.GAME_GOAL_DEFAULT
end

-- Comm.lua sends this right after an officer hello.
function ns.gameGoalMessage()
  local g = tonumber(ns.db and ns.db.gameGoal)
  return g and L.goalMessage(g) or nil
end

local function cacheList(key, days)
  if type(ns.cache) ~= "table" then return {} end
  if type(ns.cache[key]) ~= "table" then ns.cache[key] = {} end
  local list = ns.cache[key]
  for i = #list, 1, -1 do
    if type(list[i]) ~= "table" or ns.now() - (tonumber(list[i].t) or 0) > days * 86400 then table.remove(list, i) end
  end
  return list
end

-- Challenges waiting for me in one game (newest first).
local function pendingFor(id)
  local out = {}
  for _, c in ipairs(cacheList("challenges", 7)) do
    if c.game == id then table.insert(out, 1, c) end
  end
  return out
end

-- Tooltip lines for a player ("Paw Drop: #1 this week"), from scores already heard. Discord.lua adds them.
function ns.gameBadges(name)
  if not ns.opt("gameBadges", false) or type(ns.db) ~= "table" then return {} end
  local p, r = {}, {}
  for _, id in ipairs(order) do
    p[id], r[id] = peers(id), myRecord(id)
  end
  return L.gameBadges(p, r, name, ns.call("UnitName", "player"), ns.now())
end

-- The last roster scan shows them offline (a whisper would print "No player named X is currently playing.").
local function offline(who)
  local m = L.rosterMember(roster(), who)
  return m and m.online == false
end

local function sendChallenge(id, who)
  local rec = myRecord(id)
  if type(rec.last) ~= "table" or not rec.last.seed or not ns.queueWhisper or not canShare() then return false end
  if offline(who) then return false, "offline" end
  ns.queueWhisper(L.challengeMessage(id, rec.last.seed, rec.last.score), who)
  local sent = cacheList("challengesSent", 14)
  table.insert(sent, { game = id, to = who, seed = rec.last.seed, score = rec.last.score, t = ns.now() })
  while #sent > 20 do table.remove(sent, 1) end
  return true
end

local function onSocial(kind, game_, a, b, channel, who)
  local W = ns.ui
  local shown = frame and frame:IsShown()
  if kind == "MG" then
    -- only from an officer (guild rank 0-2 in our last roster scan), like the bot data relay
    if channel ~= "GUILD" or not L.relayTrusted(roster(), who) or type(ns.cache) ~= "table" then return end
    ns.cache.gameGoal = { goal = game_, by = who, t = ns.now() }
  elseif channel ~= "WHISPER" or not L.rosterMember(roster(), who) then
    return   -- challenges only from people in our guild roster
  elseif kind == "MC" then
    local list = cacheList("challenges", 7)
    for i = #list, 1, -1 do
      if list[i].from == who and list[i].game == game_ then table.remove(list, i) end   -- their newest one wins
    end
    table.insert(list, { game = game_, from = who, seed = a, score = b, t = ns.now() })
    while #list > 10 do table.remove(list, 1) end
    if shown then
      shell.setStatus(W.PINK .. who .. " challenges you|r at " .. (L.GAME_IDS[game_] or game_) .. ": beat " .. b
        .. ". " .. W.MUTED .. "Challenges button, top right.|r")
    end
  elseif kind == "MR" then
    local mine
    -- game + seed only: challenges are account-wide, so they may answer from an alt (not the name we sent to)
    for _, s in ipairs(cacheList("challengesSent", 14)) do
      if s.game == game_ and s.seed == a then mine = s.score end
    end
    if not mine then return end
    local out = L.challengeOutcome(mine, b)
    local line = string.format("%s played your %s challenge: %d vs your %d. %s", who, L.GAME_IDS[game_] or game_, b,
      mine, out == "win" and "You win!" or (out == "lose" and (who .. " wins.") or "A tie!"))
    local results = cacheList("challengeResults", 14)
    table.insert(results, { game = game_, text = line, t = ns.now(), seen = shown or nil })
    while #results > 10 do table.remove(results, 1) end
    if shown then shell.setStatus((out == "win" and W.GOOD or W.MUTED) .. line .. "|r") end
  end
  if shown then
    shell.refreshButtons()
    if boardPanel and boardPanel:IsShown() then ns.safe("gameBoard", ns.refreshGameBoard) end
  end
end

ns.on("CHAT_MSG_ADDON", function(_, prefix, msg, channel, sender)
  if prefix ~= L.COMM_PREFIX or type(msg) ~= "string" or ns.isSecret(msg) then return end
  if channel == "WHISPER" or (channel == "GUILD" and string.sub(msg, 1, 3) == "MG:") then
    local skind, sgame, sa, sb = L.parseSocialMessage(msg)
    if not skind then return end
    local who = ns.shortName(sender)
    if not who or ns.isSecret(sender) or who == ns.call("UnitName", "player") then return end
    onSocial(skind, sgame, sa, sb, channel, who)
    return
  end
  if channel ~= "GUILD" then return end
  local kind, game_, a, b, c, extras = L.parseGameMessage(msg)
  if not kind then return end
  local who = ns.shortName(sender)
  if not who or who == ns.call("UnitName", "player") then return end
  if kind == "M?" then
    if ns.now() - lastReply < 60 then return end
    lastReply = ns.now()
    ns.after(2 + math.random(0, 8), "gameReply", sendScore)
    return
  end
  if kind == "M" and not L.gameWeekPlausible(c, ns.now()) then return end
  local t = peers(game_)
  local e = type(t[who]) == "table" and t[who] or {}
  if kind == "M" then
    e.best, e.weekBest, e.week = a, b, c
    e.class = L.gameClass(extras and extras[1]) or e.class
    if game_ == "stack" then e.biggest = L.stackBiggest(extras and extras[2]) or e.biggest end
    if game_ == "paw" then e.pinks = L.gamePinks(extras and extras[2]) end   -- this week's pinks (the guild goal)
  elseif kind == "MD" then
    e.daily, e.day = a, b
  end
  e.t = ns.now()
  t[who] = e
  if kind == "M" and ns.officerMode and ns.officerMode() then L.guildGamesCopy(ns.db, game_, who, e, ns.now()) end
  if boardPanel and boardPanel:IsShown() then ns.safe("gameBoard", ns.refreshGameBoard) end
  if ns.refreshGuildWindow then ns.refreshGuildWindow() end   -- returns at once when it's closed
end)

ns.on("PLAYER_LOGIN", function()
  ns.after(70 + math.random(0, 40), "gameLogin", sendScore)
end)

-- ---------------------------------------------------------------------------
-- Sounds: stock WoW UI sound kits only, while the window is open, option "Minigame sounds" (off by default)
-- ---------------------------------------------------------------------------

local SOUNDS = {   -- SOUNDKIT name, then the kit id it has had for years (used when the table is missing)
  hit = { "U_CHAT_SCROLL_BUTTON", 1115 },
  gold = { "LOOT_WINDOW_COIN_SOUND", 120 },
  free = { "IG_MAINMENU_OPTION_CHECKBOX_ON", 856 },
  power = { "IG_SPELLBOOK_OPEN", 829 },
  won = { "IG_QUEST_LIST_COMPLETE", 878 },
  lost = { "IG_QUEST_FAILED", 847 },
}
local lastHitSound = 0

local function sound(name)
  if not ns.opt("gameSounds", false) or not (frame and frame:IsShown()) then return end
  local s = SOUNDS[name]
  if not s then return end
  if name == "hit" then
    local now = ns.call("GetTime") or 0
    if now - lastHitSound < 0.07 then return end
    lastHitSound = now
  end
  local id = type(SOUNDKIT) == "table" and SOUNDKIT[s[1]] or s[2]
  ns.call("PlaySound", id, "SFX")
end
shell.sound = sound

-- ---------------------------------------------------------------------------
-- Drawing helpers (shared): board units are pixels from the canvas' top left, y down
-- ---------------------------------------------------------------------------

local function place(tex, x, y)
  tex:ClearAllPoints()
  tex:SetPoint("CENTER", canvas, "TOPLEFT", x, -y)
end
shell.place = place

local function dot(parent, size, layer)
  local t = parent:CreateTexture(nil, layer or "ARTWORK")
  t:SetTexture(ns.ui.TEX.dot)
  t:SetSize(size, size)
  return t
end
shell.dot = dot

-- Floating "+100" at a hit; rises and fades over 0.8 s.
local function floatText(x, y, text, color)
  local f
  for _, o in ipairs(floaters) do
    if not o.live then
      f = o
      break
    end
  end
  if not f then
    if #floaters >= 16 then return end
    f = { fs = fx:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") }
    table.insert(floaters, f)
  end
  f.live, f.age, f.x, f.y = true, 0, x, y
  f.fs:SetText(text)
  local c = color or COLORS.blue
  f.fs:SetTextColor(c[1], c[2], c[3], 1)
  place(f.fs, x, y)
  f.fs:Show()
end
shell.floatText = floatText

-- Rainbow burst: pastel dots flying out from a point (the middle of the board by default).
local function burst(x, y)
  for i = 1, 30 do
    local s = sparks[i]
    if not s then
      s = { tex = dot(fx, 7, "OVERLAY") }
      sparks[i] = s
    end
    local a = i * 2 * math.pi / 30
    local c = RAINBOW[(i % #RAINBOW) + 1]
    s.tex:SetVertexColor(c[1], c[2], c[3], 1)
    s.vx, s.vy = math.cos(a) * (120 + (i % 3) * 50), math.sin(a) * (120 + (i % 3) * 50)
    s.x, s.y, s.age, s.live = x or P.W / 2, y or P.H / 2, 0, true
    s.tex:Show()
  end
end
shell.burst = burst

local function animate(elapsed)
  for _, f in ipairs(floaters) do
    if f.live then
      f.age = f.age + elapsed
      if f.age >= 0.8 then
        f.live = false
        f.fs:Hide()
      else
        place(f.fs, f.x, f.y - 26 * f.age)
        f.fs:SetAlpha(1 - f.age / 0.8)
      end
    end
  end
  for _, s in ipairs(sparks) do
    if s.live then
      s.age = s.age + elapsed
      if s.age >= 1.2 then
        s.live = false
        s.tex:Hide()
      else
        s.x, s.y = s.x + s.vx * elapsed, s.y + s.vy * elapsed
        place(s.tex, s.x, s.y)
        s.tex:SetAlpha(1 - s.age / 1.2)
      end
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
shell.cursor = cursorBoardPos

local function setStatus(text)
  status:SetText(text or "")
end
shell.setStatus = setStatus

function shell.panelOpen()
  return boardPanel and boardPanel:IsShown()
end

-- Somebody is playing: an auto-opened window stays open after landing / coming back.
function shell.played()
  auto.opened = nil
end

function shell.daily(id)
  return ns.opt(id .. "Daily", false) and true or false
end

local function refreshButtons()
  if not actionBtn then return end
  local def = current()
  local text, enabled = def.action()
  actionBtn:SetText(text)
  if enabled then actionBtn:Enable() else actionBtn:Disable() end
  dailyBtn:SetText(shell.daily(def.id) and "Free play" or "Daily")
  local nextId = def.id
  for i, id in ipairs(order) do
    if id == def.id then nextId = order[i % #order + 1] end
  end
  switchBtn:SetText(nextId ~= def.id and ("Play " .. games[nextId].title) or def.title)
  switchBtn.nextId = nextId
  local n = #pendingFor(def.id)
  chBtn:SetText("Challenges (" .. n .. ")")
  chBtn:SetShown(n > 0)
end
shell.refreshButtons = refreshButtons

-- End of a game g: records the score (best / week / today), the board for challenges (rec.last), answers a
-- challenge and says how it went. won = Paw Drop's cleared board.
function shell.finish(id, g, won, prefix)
  local me = ns.call("UnitName", "player")
  local score = g.score
  local rec = myRecord(id)
  local newBest, dailyBest = L.gameRecord(rec, score, won, ns.now(), me, g.daily)
  if g.seed then rec.last = { seed = g.seed, score = score } end
  local W = ns.ui
  local line = prefix .. "Score " .. score
  if type(g.challenge) == "table" and g.challenge.from then
    local out = L.challengeOutcome(score, g.challenge.score)
    line = line .. string.format("  vs %s %d: %s", g.challenge.from, tonumber(g.challenge.score) or 0,
      out == "win" and (W.GOOD .. "you win!|r") or (out == "lose" and "they win." or "a tie!"))
    if ns.queueWhisper and canShare() and not offline(g.challenge.from) then
      ns.queueWhisper(L.challengeResultMessage(id, g.seed, score), g.challenge.from)
    end
  elseif newBest then
    line = line .. "  " .. W.PINK .. "New best!|r"
  elseif dailyBest then
    line = line .. "  " .. W.PINK .. "Best today!|r"
  end
  ns.after(30, "gameBest", sendScore)   -- this week's numbers (and the guild goal) stay fresh
  if won or newBest then
    burst()
    sound("won")
  else
    sound("lost")
  end
  if ns.settings and type(ns.settings.gameSave) == "table" then ns.settings.gameSave[id] = nil end
  setStatus(line .. "  " .. W.MUTED .. "New game to play again.|r")
  shell.refreshButtons()
  return newBest, dailyBest
end

-- ---------------------------------------------------------------------------
-- Paw Drop
-- ---------------------------------------------------------------------------

local paw = { id = "paw", title = "Paw Drop" }
local GAME = "paw"
local pegTex, ballTex, basketTex, aimDots = {}, {}, nil, {}
local game
local lastAim
local pawLayer

local function drawPegs()
  for i, p in ipairs(game.pegs) do
    local t = pegTex[i]
    if not t then
      t = dot(pawLayer, P.PEG_R * 2 + 2)
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

local function drawBalls()
  local live = L.pawBallsInPlay(game)
  for i = 1, math.max(#live, #ballTex) do
    local b, t = live[i], ballTex[i]
    if b and not t then
      t = dot(pawLayer, P.BALL_R * 2 + 2, "OVERLAY")
      t:SetVertexColor(1, 1, 1, 1)
      ballTex[i] = t
    end
    if b then
      t:SetSize(b.r * 2 + 2, b.r * 2 + 2)
      place(t, b.x, b.y)
      t:Show()
    elseif t then
      t:Hide()
    end
  end
end

local function drawAim(pts)
  for i = 1, 40 do
    local d = aimDots[i]
    if not d then
      d = dot(pawLayer, 4, "BORDER")
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

function paw.hud()
  local W = ns.ui
  local rec = myRecord(GAME)
  local cleared = game.pinkTotal - game.pinkLeft
  local mode = game.daily and (W.PINK .. "Daily|r   ") or ""
  return string.format("%s%sBalls|r %d   %sScore|r %d   %sPink|r %d/%d   %sx%d|r   %sBest %d|r",
    mode, W.MUTED, game.balls, W.MUTED, game.score, W.MUTED, cleared, game.pinkTotal,
    W.PINK, L.pawMultiplier(cleared), W.MUTED, rec.best or 0)
end

function paw.action()
  local pw = game and game.power and L.PAW_POWERS[game.power]
  if not pw then return "No power", false end
  if game.powerUsed then return pw.name .. " (used)", false end
  return game.armed and (pw.name .. " ready!") or pw.name, L.pawCanArm(game)
end

function paw.actionTip()
  local pw = game and game.power and L.PAW_POWERS[game.power]
  return pw and pw.name or "Class power",
    pw and ("Once per game, before a shot: " .. pw.text .. ".") or "Your class has no power in this game."
end

function paw.actionClick()
  if not game then return end
  if L.pawArm(game) then
    lastAim = nil   -- Aimed Shot / Shapeshift change the aim line
    sound("power")
  end
end

local function pawGameOver()
  local won = game.state == "won"
  local W = ns.ui
  L.gameAddPinks(myRecord(GAME), game.pinkTotal - game.pinkLeft, ns.now(), ns.call("UnitName", "player"))
  shell.finish(GAME, game, won, won and (W.GOOD .. "Board cleared!|r ") or (W.WAIT .. "Out of balls.|r "))
end

local function drainEvents()
  local W = ns.ui
  for _, e in ipairs(game.events) do
    if e.kind == "hit" then
      if e.x then floatText(e.x, e.y - 10, "+" .. e.value, COLORS.pink) end
      sound("hit")
    elseif e.kind == "free" then
      setStatus(W.GOOD .. "Caught! Free ball.|r")
      sound("free")
    elseif e.kind == "gold" then
      if e.x then floatText(e.x, e.y - 10, "+" .. e.value, COLORS.gold) end
      setStatus(W.PINK .. "Gold paw: +1 ball|r")
      sound("gold")
    elseif e.kind == "shield" then
      setStatus(W.GOOD .. "Shield: the ball comes back.|r")
      sound("free")
    elseif e.kind == "drain" then
      setStatus(W.GOOD .. "Drain: +1 ball.|r")
      sound("free")
    elseif e.kind == "split" then
      sound("power")
    elseif e.kind == "shot" then
      if (e.value or 0) > 0 then setStatus("Shot: +" .. e.value) end
    elseif e.kind == "won" or e.kind == "lost" then
      pawGameOver()
    end
  end
  game.events = {}
  refreshButtons()
end

local function pawRender()
  drawPegs()
  drawBalls()
  basketTex:SetSize(L.pawBasketW(game), 12)
  place(basketTex, L.pawBasketX(game.t), P.BASKET_Y + 5)
end

local function pawStart(g)
  game = g
  lastAim = nil
  drawAim(nil)
  local W = ns.ui
  local pw = game.power and L.PAW_POWERS[game.power]
  setStatus(W.MUTED .. (game.daily and "Today's board: " or "") .. game.layoutName .. ": clear the "
    .. game.pinkTotal .. " pink pegs." .. (pw and (" Power: " .. pw.text .. ".") or "") .. "|r")
  pawRender()
end

function paw.start(daily)
  if daily then
    pawStart(L.pawNewDaily(ns.now(), { class = myClass() }))
  else
    pawStart(L.pawNewSeeded(math.random(1, 2147483646), { class = myClass() }))
  end
end

-- A guildmate's board: their seed, to beat their score.
function paw.startChallenge(seed, ch)
  pawStart(L.pawNewSeeded(seed, { class = myClass(), challenge = ch }))
  setStatus(ns.ui.PINK .. ch.from .. "'s board:|r beat " .. ch.score .. ".")
end

-- M extra field after the class: pink pegs cleared this week (the guild goal).
function paw.extras(rec)
  return { tostring(L.gamePinksWeek(rec, ns.now(), ns.call("UnitName", "player"))) }
end

function paw.resume(save)
  local g = L.pawLoad(save)
  if not g then return false end
  if g.daily and g.daily ~= L.gameDay(ns.now()) then return false end
  pawStart(g)
  setStatus(ns.ui.MUTED .. "Back where you left off: " .. g.layoutName .. ".|r")
  return true
end

function paw.hasGame() return game ~= nil end
function paw.busy() return game ~= nil and game.state == "fly" end

-- The game in progress for gameSave (a ball in flight is finished first, so it is never lost).
function paw.save()
  L.pawFinishShot(game)
  if #game.events > 0 then drainEvents() end
  return L.pawSave(game)
end

function paw.update(elapsed)
  -- Slow motion near the last pink peg (drawing only; physics stays a fixed step).
  local dt = L.pawSlowMo(game) and elapsed * 0.35 or elapsed
  L.pawUpdate(game, dt)
  if #game.events > 0 then drainEvents() end
  if game.state == "aim" and not shell.panelOpen() then
    local x, y = cursorBoardPos()
    if x then
      local a = L.pawAimAt(x, y)
      if not lastAim or math.abs(a - lastAim) > 0.002 then
        lastAim = a
        drawAim(L.pawPreview(game, a, 40))
      end
    end
  elseif lastAim then
    lastAim = nil
    drawAim(nil)
  end
  pawRender()
end

function paw.click(x, y)
  if not game or game.state ~= "aim" then return end
  local armed = game.armed
  if L.pawFire(game, L.pawAimAt(x, y)) then
    shell.played()
    lastAim = nil
    drawAim(nil)
    if armed then sound("power") end
    refreshButtons()
  end
end

function paw.build(layer)
  pawLayer = layer
  local W = ns.ui
  local launcher = layer:CreateTexture(nil, "ARTWORK")
  launcher:SetTexture(W.TEX.paw)
  launcher:SetSize(22, 22)
  place(launcher, P.LAUNCH_X, P.LAUNCH_Y - 4)
  basketTex = layer:CreateTexture(nil, "ARTWORK")
  basketTex:SetTexture(W.TEX.pill)
  basketTex:SetSize(P.BASKET_W, 12)
  basketTex:SetVertexColor(W.C.pink[1], W.C.pink[2], W.C.pink[3], 0.9)
end

ns.registerGame(paw)

-- ---------------------------------------------------------------------------
-- Saving games in progress (per character, on logout / reload)
-- ---------------------------------------------------------------------------

local function saveGames()
  if not ns.settings then return end
  if type(ns.settings.gameSave) ~= "table" then ns.settings.gameSave = {} end
  for _, id in ipairs(order) do
    local def = games[id]
    -- a game never loaded this session keeps its old save
    if def.hasGame() then ns.settings.gameSave[id] = def.save() end
  end
end
ns.saveGames = saveGames

ns.on("PLAYER_LOGOUT", function() ns.safe("gameSave", saveGames) end)

-- ---------------------------------------------------------------------------
-- Guild scores panel (over the board)
-- ---------------------------------------------------------------------------

local SORT_NEXT = { best = "week", week = "today", today = "best" }
local SORT_TITLE = { best = "All time", week = "This week", today = "Today's board" }

local ROWS = 14

-- Right-click a name: challenge them to your last board.
local function rowMenu(btn)
  local def, r = current(), btn.row
  if not r or r.mine then return end
  local rec = myRecord(def.id)
  local items
  if type(rec.last) == "table" and rec.last.seed then
    items = { { text = "Challenge " .. r.name .. " (your last board, " .. rec.last.score .. ")", func = function()
      local ok, why = sendChallenge(def.id, r.name)
      if ok then
        shell.setStatus(ns.ui.GOOD .. "Challenge sent to " .. r.name .. ".|r")
      elseif why == "offline" then
        shell.setStatus(ns.ui.MUTED .. r.name .. " is offline. Challenge them when they're on.|r")
      else
        shell.setStatus(ns.ui.MUTED .. "Can't send right now (score sharing off, or not in a guild).|r")
      end
    end } }
  else
    items = { { text = "Finish a game first, then challenge " .. r.name, func = function() end } }
  end
  ns.ui.popup(btn, items)
end

function ns.refreshGameBoard()
  if not boardPanel then return end
  local W = ns.ui
  local def = current()
  local me = ns.call("UnitName", "player")
  local rows = L.gameBoard(peers(def.id), myRecord(def.id), me, boardBy, ns.now(), myClass())
  local out = { W.headerLine(SORT_TITLE[boardBy], def.title .. " scores from guildmates' addons"), "",
    string.format("%s      %-18s  %8s  %8s  %8s|r", W.MUTED, "", "best", "week", "today") }
  if #rows == 0 then
    for _, l in ipairs(W.emptyLines("No scores yet", "Guildmates show up here once they've played (and are online).")) do
      table.insert(out, l)
    end
  end
  boardText:SetText(table.concat(out, "\n"))
  for i = 1, ROWS do
    local btn, r = rowBtns[i], rows[i]
    btn.row = r
    if r then
      local name = ns.displayName and ns.displayName(r.name) or r.name
      name = (r.class and W.classColor(r.class) or "") .. name .. (r.class and "|r" or "")
      if r.mine then name = name .. W.PINK .. " (you)|r" end
      local function col(key, v)
        return (key == boardBy and W.GOOD or W.MUTED) .. string.format("%8d", v) .. "|r"
      end
      local note = def.scoreNote and def.scoreNote(r) or ""
      btn.text:SetText(string.format("%s%2d.|r  %s   %s  %s  %s%s", W.MUTED, i, name, col("best", r.best),
        col("week", r.week), col("today", r.today), note))
      btn:Show()
    else
      btn:Hide()
    end
  end
  -- the guild's weekly goal (Paw Drop's pink pegs)
  if def.id == "paw" then
    local total, g = L.goalTotal(peers("paw"), myRecord("paw"), me, ns.now()), goal()
    goalBg.text:SetText(string.format("%sGuild goal this week:|r %d / %d pink pegs%s", W.MUTED, total, g,
      total >= g and ("  " .. W.GOOD .. "reached!|r") or ""))
    goalFill:SetWidth(math.max(1, (goalBg:GetWidth() or 0) * math.min(1, total / g)))
    goalBg:Show()
  else
    goalBg:Hide()
  end
  boardChip:SetText("Sort: " .. SORT_TITLE[SORT_NEXT[boardBy]])
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

function ns.applyGamesScale()
  if not frame then return end
  local s = tonumber(ns.opt("gamesScale", 1)) or 1
  frame:SetScale(math.max(0.6, math.min(1, s)))
end

local function newGame()
  local def = current()
  def.start(shell.daily(def.id))
  refreshButtons()
end

-- Shows a game: its layer on, the others off; resumes its saved game or starts one the first time.
local function showGame(def)
  cur = def
  ns.setOpt("lastGame", def.id)
  for _, id in ipairs(order) do
    local d = games[id]
    if d.layer then d.layer:SetShown(d == def) end
  end
  if frame.title then frame.title:SetText(def.title) end
  if not def.hasGame() then
    local saves = ns.settings and ns.settings.gameSave
    if not def.resume(type(saves) == "table" and saves[def.id] or nil) then def.start(shell.daily(def.id)) end
  end
  if boardPanel:IsShown() then ns.refreshGameBoard() end
  -- a challenge result that came in while the window was closed
  for _, r in ipairs(cacheList("challengeResults", 14)) do
    if not r.seen and r.game == def.id then
      r.seen = true
      shell.setStatus(ns.ui.MUTED .. r.text .. "|r")
    end
  end
  refreshButtons()
  hud:SetText(def.hud())
end

local function onUpdate(_, elapsed)
  local def = current()
  if not def.hasGame() then return end
  def.update(elapsed)
  animate(elapsed)
  hud:SetText(def.hud())
end

local function create()
  local W = ns.ui
  frame = W.window("GFoAGuildSyncGamesFrame", current().title, P.W + 20, P.H + 28 + 24 + 34 + 18, "gamesPos")
  ns.applyGamesScale()

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
  canvas:SetScript("OnMouseDown", function()
    ns.safe("gameClick", function()
      local def = current()
      if shell.panelOpen() or not def.hasGame() then return end
      local x, y = cursorBoardPos()
      if x then def.click(x, y) end
    end)
  end)

  -- one layer frame per game (switching shows one), the floating numbers and bursts above them
  for _, id in ipairs(order) do
    local def = games[id]
    def.layer = CreateFrame("Frame", nil, canvas)
    def.layer:SetAllPoints()
    def.layer:SetFrameLevel(canvas:GetFrameLevel() + 1)
    def.build(def.layer)
    def.layer:Hide()
  end
  fx = CreateFrame("Frame", nil, canvas)
  fx:SetAllPoints()
  fx:SetFrameLevel(canvas:GetFrameLevel() + 3)

  boardPanel = CreateFrame("Frame", nil, canvas, W.BACKDROP_TEMPLATE)
  boardPanel:SetPoint("TOPLEFT", 16, -16)
  boardPanel:SetPoint("BOTTOMRIGHT", -16, 16)
  boardPanel:SetFrameLevel(canvas:GetFrameLevel() + 5)
  W.backdrop(boardPanel, 0.97)
  boardPanel:EnableMouse(true)
  boardText = boardPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  boardText:SetPoint("TOPLEFT", 14, -14)
  boardText:SetPoint("RIGHT", -14, 0)
  boardText:SetJustifyH("LEFT")
  boardText:SetJustifyV("TOP")
  boardText:SetSpacing(3)
  boardChip = W.button(boardPanel, "Sort: This week", 140, 20, function()
    boardBy = SORT_NEXT[boardBy]
    ns.refreshGameBoard()
  end)
  boardChip:SetPoint("BOTTOMLEFT", 12, 12)
  local close = W.button(boardPanel, "Back to the game", 120, 20, toggleBoard)
  close:SetPoint("BOTTOMRIGHT", -12, 12)
  for i = 1, ROWS do   -- one button per row: right-click a name to challenge them
    local b = CreateFrame("Button", nil, boardPanel)
    b:SetHeight(15)
    b:SetPoint("TOPLEFT", boardText, "BOTTOMLEFT", 0, -3 - (i - 1) * 15)
    b:SetPoint("RIGHT", boardPanel, "RIGHT", -14, 0)
    if b.RegisterForClicks then b:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetAllPoints()
    b.text:SetJustifyH("LEFT")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(W.C.pink[1], W.C.pink[2], W.C.pink[3], 0.12)
    b:SetScript("OnClick", function(self, button)
      if button == "RightButton" then ns.safe("gameChallenge", rowMenu, self) end
    end)
    b:Hide()
    rowBtns[i] = b
  end
  goalBg = CreateFrame("Frame", nil, boardPanel)
  goalBg:SetPoint("BOTTOMLEFT", 12, 40)
  goalBg:SetPoint("BOTTOMRIGHT", -12, 40)
  goalBg:SetHeight(8)
  local gbg = goalBg:CreateTexture(nil, "BACKGROUND")
  gbg:SetAllPoints()
  gbg:SetColorTexture(1, 1, 1, 0.12)
  goalFill = goalBg:CreateTexture(nil, "ARTWORK")
  goalFill:SetPoint("TOPLEFT")
  goalFill:SetPoint("BOTTOMLEFT")
  goalFill:SetColorTexture(W.C.pink[1], W.C.pink[2], W.C.pink[3], 0.9)
  goalBg.text = goalBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  goalBg.text:SetPoint("BOTTOMLEFT", goalBg, "TOPLEFT", 0, 3)
  boardPanel:Hide()

  chBtn = W.button(frame, "Challenges", 104, 18, function()
    local def, items = current(), {}
    for _, c in ipairs(pendingFor(current().id)) do
      table.insert(items, { text = c.from .. ": beat " .. c.score, func = function()
        local list = cacheList("challenges", 7)
        for i = #list, 1, -1 do
          if list[i] == c then table.remove(list, i) end
        end
        def.startChallenge(c.seed, { from = c.from, score = c.score })
        shell.played()
        refreshButtons()
      end })
    end
    W.popup(chBtn, items)
  end)
  chBtn:SetPoint("TOPRIGHT", -30, -(frame.top - 4))
  chBtn:Hide()

  status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("TOPLEFT", canvas, "BOTTOMLEFT", 2, -4)
  status:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)

  local newBtn = W.button(frame, "New game", 72, 22, newGame)
  newBtn:SetPoint("BOTTOMLEFT", 10, 8)
  dailyBtn = W.button(frame, "Daily", 64, 22, function()
    local id = current().id
    ns.setOpt(id .. "Daily", not shell.daily(id))
    newGame()
  end)
  dailyBtn:SetPoint("LEFT", newBtn, "RIGHT", 4, 0)
  local scoresBtn = W.button(frame, "Scores", 56, 22, toggleBoard)
  scoresBtn:SetPoint("LEFT", dailyBtn, "RIGHT", 4, 0)
  switchBtn = W.button(frame, "Play", 104, 22, function()
    local nextDef = games[switchBtn.nextId]
    if nextDef and nextDef ~= current() then showGame(nextDef) end
  end)
  switchBtn:SetPoint("LEFT", scoresBtn, "RIGHT", 4, 0)
  actionBtn = W.button(frame, "Power", 100, 22, function()
    current().actionClick()
    refreshButtons()
  end)
  actionBtn:SetPoint("BOTTOMRIGHT", -10, 8)
  actionBtn:SetScript("OnEnter", function(self)
    local title, text = current().actionTip()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(title)
    GameTooltip:AddLine(text, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  actionBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame:SetScript("OnShow", function()
    showGame(current())
    frame:SetScript("OnUpdate", function(self, elapsed) ns.safe("gameUpdate", onUpdate, self, elapsed) end)
  end)
  frame:SetScript("OnHide", function()
    frame:SetScript("OnUpdate", nil)   -- nothing runs while the window is closed; the game waits where it was
    L.autoClosed(auto, ns.queueState and ns.queueState(), not selfHiding)
  end)
end

-- show: true / false / nil (toggle); game: "paw" / "stack" to open that one.
function ns.toggleGames(show, game)
  if not frame then create() end
  if game and games[game] then
    -- /pawdrop while Paw Drop is on screen closes it; while Paw Stack is on screen it switches
    if show == nil then show = not (frame:IsShown() and current().id == game) end
    if show then
      cur = games[game]
      if frame:IsShown() then showGame(cur) end
    end
  end
  if show == nil then show = not frame:IsShown() end
  frame:SetShown(show and true or false)
end

-- ---------------------------------------------------------------------------
-- Open on flight paths / AFK / battleground queues (option "gamesAutoOpen", off by default). Opens the last game.
-- ---------------------------------------------------------------------------

local function inCombat()
  return ns.call("InCombatLockdown") or ns.call("UnitAffectingCombat", "player")
end

-- "confirm" while a battleground invite is up, "queued" while waiting, else nil.
local function queueState()
  if not ns.api("GetBattlefieldStatus") then return nil end
  local n = ns.call("GetMaxBattlefieldID") or (type(MAX_BATTLEFIELD_QUEUES) == "number" and MAX_BATTLEFIELD_QUEUES) or 3
  return L.queueState(n, function(i) return ns.plain(ns.call("GetBattlefieldStatus", i)) end)
end
ns.queueState = queueState

local function hideSelf()
  selfHiding = true
  frame:Hide()
  selfHiding = nil
end

local function autoOpen(reason)
  if not ns.opt("gamesAutoOpen", false) or inCombat() or queueState() == "confirm" then return end
  if frame and frame:IsShown() then return end
  ns.toggleGames(true)
  auto.opened = reason
end

local function autoClose(reason, force)
  if auto.opened ~= reason then return end
  auto.opened = nil
  if frame and frame:IsShown() and (force or not current().busy()) then hideSelf() end
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
ns.on("UPDATE_BATTLEFIELD_STATUS", function()
  -- a close by the player while queued is remembered until the queue ends (no reopening on every status event)
  local act = L.autoQueueEvent(auto, queueState())
  if act == "open" then
    autoOpen("queue")
  elseif act == "closeForce" then
    -- the queue popped: anything that opened itself gets out of the way of the join dialog (the game waits)
    autoClose(auto.opened, true)
  elseif act == "close" then
    autoClose("queue")
  end
end)
ns.on("PLAYER_REGEN_DISABLED", function()
  -- pulled while it opened itself: get it out of the way
  if auto.opened then
    auto.opened = nil
    if frame then hideSelf() end
  end
end)

ns.commands["pegs"] = function() ns.toggleGames(nil, "paw") end
ns.commands["pawdrop"] = ns.commands["pegs"]
ns.commands["peggle"] = ns.commands["pegs"]
ns.commands["games"] = function() ns.toggleGames() end   -- the last game played
ns.commands["stack"] = function() ns.toggleGames(nil, "stack") end

-- /gf gamegoal N: officers set the guild's weekly pink-peg goal (sent now and with every officer hello).
ns.commands["gamegoal"] = function(arg)
  local n = tonumber(arg)
  if not n then
    ns.print("Minigame guild goal: " .. goal() .. " pink pegs this week. Officers: /gf gamegoal <number>.")
    return
  end
  if not (ns.officerMode and ns.officerMode()) then
    ns.print("Only officers' addons can set the guild goal (/gf officer).")
    return
  end
  n = math.floor(n)
  if n < 1 or n > L.GAME_GOAL_MAX then
    ns.print("Pick a goal from 1 to " .. L.GAME_GOAL_MAX .. ".")
    return
  end
  ns.db.gameGoal = n
  if type(ns.cache) == "table" then
    ns.cache.gameGoal = { goal = n, by = ns.call("UnitName", "player"), t = ns.now() }
  end
  if canShare() then ns.queueComm(L.goalMessage(n)) end
  ns.print("Minigame guild goal set to " .. n .. " pink pegs a week.")
end
ns.commands["pawstack"] = ns.commands["stack"]

-- Short slash commands of their own: /pawdrop and /peggle open Paw Drop, /pawstack opens Paw Stack.
SLASH_GFOAPAWDROP1 = "/pawdrop"
SLASH_GFOAPAWDROP2 = "/peggle"
SlashCmdList["GFOAPAWDROP"] = function() ns.safe("slash", ns.toggleGames, nil, "paw") end
SLASH_GFOAPAWSTACK1 = "/pawstack"
SlashCmdList["GFOAPAWSTACK"] = function() ns.safe("slash", ns.toggleGames, nil, "stack") end
