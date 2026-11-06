-- GFoA Guild Sync: minigame logic, pure Lua (no WoW API), tested by tests/test_games.lua.
-- Paw Drop: a peg-and-ball game of our own (docs/minigames.md). Board units are pixels, y grows downwards.
-- Also the guild score messages (M / M?) and the "this week" key shared by every minigame.
local _, ns = ...
ns = ns or {}
local L = ns.logic or {}
ns.logic = L

local sqrt, sin, cos, floor, abs = math.sqrt, math.sin, math.cos, math.floor, math.abs

local P = {
  W = 400, H = 440,
  LAUNCH_X = 200, LAUNCH_Y = 18,
  BALL_R = 5, PEG_R = 6,
  GRAVITY = 520, SPEED = 400, MAX_SPEED = 720,
  BOUNCE = 0.72, WALL_BOUNCE = 0.85,
  STEP = 1 / 240,
  BALLS = 10, PINKS = 15,
  BASKET_Y = 428, BASKET_W = 64, BASKET_SWING = 150, BASKET_RATE = 0.9,
  POINTS = { blue = 10, pink = 100, gold = 300 },
  WIN_BONUS = 1000,       -- per ball left
  STUCK_SPEED = 35, STUCK_TIME = 1.5, SHOT_MAX = 20,
  AIM_MAX = 1.45,         -- radians either side of straight down
}
L.PAW = P

-- ---------------------------------------------------------------------------
-- Layouts: lists of { x, y }
-- ---------------------------------------------------------------------------

local function ring(out, cx, cy, rx, ry, n, a0)
  for i = 0, n - 1 do
    local a = (a0 or 0) + i * 2 * math.pi / n
    table.insert(out, { x = cx + rx * cos(a), y = cy + ry * sin(a) })
  end
end

local LAYOUTS = {
  { name = "Paw print", build = function()
    local out = {}
    ring(out, 200, 318, 96, 72, 22)
    ring(out, 200, 318, 50, 34, 10, 0.3)
    for _, toe in ipairs({ { 82, 204 }, { 150, 136 }, { 250, 136 }, { 318, 204 } }) do
      ring(out, toe[1], toe[2], 32, 32, 8)
    end
    return out
  end },
  { name = "Rainbow", build = function()
    local out = {}
    for k, r in ipairs({ 110, 150, 190, 230, 270, 310 }) do
      local n = floor(math.pi * r / 28)
      for i = 0, n do
        local a = math.pi + i * math.pi / n
        local x, y = 200 + r * cos(a), 430 + r * sin(a)
        if y < 410 and x > 14 and x < 386 and (k % 2 == 1 or i % 2 == 0) and y > 96 then table.insert(out, { x = x, y = y }) end
      end
    end
    return out
  end },
  { name = "Diamond", build = function()
    local out = {}
    local row = 0
    for y = 100, 400, 30 do
      local shift = (row % 2 == 1) and 20 or 0
      for x = 20 + shift, 380, 40 do
        if abs(x - 200) / 200 + abs(y - 250) / 160 <= 1.2 then table.insert(out, { x = x, y = y }) end
      end
      row = row + 1
    end
    return out
  end },
}
L.PAW_LAYOUTS = LAYOUTS

-- Shuffled indexes 1..n (rng(k) returns 1..k, like math.random).
local function shuffled(n, rng)
  local t = {}
  for i = 1, n do t[i] = i end
  for i = n, 2, -1 do
    local j = rng(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

local function pickGold(g)
  for _, p in ipairs(g.pegs) do
    if p.kind == "gold" and not p.gone then p.kind = "blue" end
  end
  local blues = {}
  for _, p in ipairs(g.pegs) do
    if p.kind == "blue" and not p.gone then table.insert(blues, p) end
  end
  if #blues > 0 then blues[g.rng(#blues)].kind = "gold" end
end

local function pinksLeft(g)
  local n = 0
  for _, p in ipairs(g.pegs) do
    if p.kind == "pink" and not p.gone then n = n + 1 end
  end
  return n
end
L.pawPinksLeft = pinksLeft

-- New game on layout `layout` (1..#LAYOUTS, random when nil).
function L.pawNewGame(rng, layout)
  rng = rng or math.random
  layout = layout or rng(#LAYOUTS)
  local pegs = {}
  for _, pt in ipairs(LAYOUTS[layout].build()) do
    table.insert(pegs, { x = pt.x, y = pt.y, kind = "blue", lit = false, gone = false })
  end
  local pinks = math.min(P.PINKS, floor(#pegs / 4))
  local order = shuffled(#pegs, rng)
  for i = 1, pinks do pegs[order[i]].kind = "pink" end
  local g = {
    layout = layout, layoutName = LAYOUTS[layout].name, pegs = pegs, rng = rng,
    balls = P.BALLS, score = 0, shotScore = 0, pinkTotal = pinks, pinkLeft = pinks,
    state = "aim", t = 0, acc = 0, ball = nil, events = {},
  }
  pickGold(g)
  return g
end

function L.pawMultiplier(cleared)
  if cleared >= 14 then return 5 end
  if cleared >= 12 then return 3 end
  if cleared >= 8 then return 2 end
  return 1
end

-- Pinks hit so far this game (gone or lit on the current shot).
local function pinksCleared(g)
  local n = 0
  for _, p in ipairs(g.pegs) do
    if p.kind == "pink" and (p.gone or p.lit) then n = n + 1 end
  end
  return n
end

function L.pawBasketX(t)
  return P.W / 2 + P.BASKET_SWING * sin(t * P.BASKET_RATE)
end

function L.pawClampAim(angle)
  if angle ~= angle then return 0 end
  return math.max(-P.AIM_MAX, math.min(P.AIM_MAX, angle))
end

-- Aim angle (0 = straight down, positive = to the right) towards board point x, y.
function L.pawAimAt(x, y)
  local dx, dy = x - P.LAUNCH_X, math.max(1, y - P.LAUNCH_Y)
  return L.pawClampAim(math.atan2(dx, dy))
end

function L.pawFire(g, angle)
  if g.state ~= "aim" or g.balls <= 0 then return false end
  angle = L.pawClampAim(angle or 0)
  g.balls = g.balls - 1
  g.ball = { x = P.LAUNCH_X, y = P.LAUNCH_Y, vx = P.SPEED * sin(angle), vy = P.SPEED * cos(angle), slow = 0, age = 0 }
  g.state, g.shotScore = "fly", 0
  return true
end

local function push(g, kind, a) table.insert(g.events, { kind = kind, value = a }) end

local function endShot(g, caught)
  g.ball = nil
  for _, p in ipairs(g.pegs) do
    if p.lit then p.lit, p.gone = false, true end
  end
  if caught then
    g.balls = g.balls + 1
    push(g, "free")
  end
  g.pinkLeft = pinksLeft(g)
  if g.pinkLeft == 0 then
    local bonus = g.balls * P.WIN_BONUS
    g.score = g.score + bonus
    g.state = "won"
    push(g, "won", bonus)
  elseif g.balls <= 0 then
    g.state = "lost"
    push(g, "lost")
  else
    g.state = "aim"
    pickGold(g)
    push(g, "shot", g.shotScore)
  end
end

local function hitPeg(g, p)
  if p.lit or p.gone then return end
  p.lit = true
  local pts = P.POINTS[p.kind] * L.pawMultiplier(pinksCleared(g))
  g.score, g.shotScore = g.score + pts, g.shotScore + pts
  if p.kind == "gold" then
    g.balls = g.balls + 1
    push(g, "gold", pts)
  else
    push(g, "hit", pts)
  end
end

-- Moves ball b one fixed step. Returns the first peg touched (or nil). Shared by the game and the aim preview.
local function stepBall(b, pegs, onHit)
  local dt = P.STEP
  b.vy = b.vy + P.GRAVITY * dt
  b.x, b.y = b.x + b.vx * dt, b.y + b.vy * dt
  local R = P.BALL_R
  if b.x < R then b.x, b.vx = R, abs(b.vx) * P.WALL_BOUNCE end
  if b.x > P.W - R then b.x, b.vx = P.W - R, -abs(b.vx) * P.WALL_BOUNCE end
  if b.y < R then b.y, b.vy = R, abs(b.vy) * P.WALL_BOUNCE end
  local rr = R + P.PEG_R
  local touched
  for _, p in ipairs(pegs) do
    if not p.gone then
      local dx, dy = b.x - p.x, b.y - p.y
      local d2 = dx * dx + dy * dy
      if d2 < rr * rr then
        local d = sqrt(d2)
        local nx, ny
        if d < 1e-6 then nx, ny, d = 0, -1, 0 else nx, ny = dx / d, dy / d end
        b.x, b.y = p.x + nx * rr, p.y + ny * rr
        local vn = b.vx * nx + b.vy * ny
        if vn < 0 then
          b.vx = b.vx - (1 + P.BOUNCE) * vn * nx
          b.vy = b.vy - (1 + P.BOUNCE) * vn * ny
        end
        touched = touched or p
        if onHit then onHit(p) end
      end
    end
  end
  local s2 = b.vx * b.vx + b.vy * b.vy
  if s2 > P.MAX_SPEED * P.MAX_SPEED then
    local k = P.MAX_SPEED / sqrt(s2)
    b.vx, b.vy = b.vx * k, b.vy * k
  end
  return touched
end

-- Removes lit pegs next to a crawling ball so it can't sit on them forever.
local function unstick(g, b, all)
  local reach = P.BALL_R + P.PEG_R + 3
  for _, p in ipairs(g.pegs) do
    if p.lit and not p.gone then
      local dx, dy = b.x - p.x, b.y - p.y
      if all or dx * dx + dy * dy <= reach * reach then p.lit, p.gone = false, true end
    end
  end
end

-- Advances the game by dt seconds (any size; runs whole fixed steps, the rest carries over).
function L.pawUpdate(g, dt)
  dt = math.min(dt or 0, 0.25)
  g.t = g.t + dt
  if g.state ~= "fly" then return end
  g.acc = g.acc + dt
  local onHit = function(p) hitPeg(g, p) end
  while g.acc >= P.STEP and g.state == "fly" do
    g.acc = g.acc - P.STEP
    local b = g.ball
    local prevY = b.y
    stepBall(b, g.pegs, onHit)
    b.age = b.age + P.STEP
    local top = P.BASKET_Y - P.BALL_R
    if prevY < top and b.y >= top and abs(b.x - L.pawBasketX(g.t)) <= P.BASKET_W / 2 then
      endShot(g, true)
    elseif b.y > P.H + P.BALL_R then
      endShot(g, false)
    else
      if b.vx * b.vx + b.vy * b.vy < P.STUCK_SPEED * P.STUCK_SPEED then b.slow = b.slow + P.STEP else b.slow = 0 end
      if b.slow >= P.STUCK_TIME then
        unstick(g, b, false)
        b.slow = 0
      end
      if b.age >= P.SHOT_MAX then
        unstick(g, b, true)
        b.age = 0
      end
    end
  end
  if g.state ~= "fly" then g.acc = 0 end
end

-- Dotted aim line: up to n points (every few steps) until the first peg the ball would touch, or the bottom.
function L.pawPreview(g, angle, n)
  angle = L.pawClampAim(angle or 0)
  local b = { x = P.LAUNCH_X, y = P.LAUNCH_Y, vx = P.SPEED * sin(angle), vy = P.SPEED * cos(angle) }
  local pts = {}
  for i = 1, 600 do
    local touched = stepBall(b, g.pegs)
    if i % 8 == 0 or touched then table.insert(pts, { x = b.x, y = b.y }) end
    if touched or #pts >= (n or 30) or b.y > P.H then break end
  end
  return pts
end

-- ---------------------------------------------------------------------------
-- Scores (shared by every minigame)
-- ---------------------------------------------------------------------------

L.GAME_IDS = { paw = "Paw Drop" }
L.GAME_SCORE_MAX = 99999999

-- Week number since Monday 1970-01-05 00:00 UTC (resets Monday 00:00 UTC).
function L.gameWeek(t)
  return floor(((t or 0) - 345600) / 604800)
end

-- Records a finished game into rec (account table for one game). Returns true on a new all-time best.
function L.gameRecord(rec, score, won, t, who)
  score = floor(tonumber(score) or 0)
  rec.played = (rec.played or 0) + 1
  if won then rec.won = (rec.won or 0) + 1 end
  local week = L.gameWeek(t)
  if rec.week ~= week then rec.week, rec.weekBest = week, 0 end
  if score > (rec.weekBest or 0) then rec.weekBest = score end
  if score > (rec.best or 0) then
    rec.best, rec.bestBy, rec.bestAt = score, who, t
    return true
  end
  return false
end

local function cleanScore(v)
  v = tonumber(v)
  if not v or v ~= v or v < 0 then return 0 end
  return math.min(floor(v), L.GAME_SCORE_MAX)
end

-- M:<game>:<best>:<weekBest>:<week>[:<extra>...] (extra fields are for later versions; 1.7.0 ignores them)
function L.gameScoreMessage(game, rec, t)
  local week = L.gameWeek(t)
  local wk = (rec.week == week) and cleanScore(rec.weekBest) or 0
  return string.format("M:%s:%d:%d:%d", game, cleanScore(rec.best), wk, week)
end

-- Returns "M?" for a query, or "M", game, best, weekBest, week, extras (list of strings after the week, maybe
-- empty); nil for anything else.
function L.parseGameMessage(msg)
  if type(msg) ~= "string" then return nil end
  if msg == "M?" then return "M?" end
  local game, best, wk, week, rest = string.match(msg, "^M:(%l+):(%d+):(%d+):(%-?%d+)(.*)$")
  if not game or not L.GAME_IDS[game] or (rest ~= "" and string.sub(rest, 1, 1) ~= ":") then return nil end
  local extras = {}
  for field in string.gmatch(rest, ":([^:]*)") do table.insert(extras, field) end
  return "M", game, cleanScore(best), cleanScore(wk), tonumber(week), extras
end

-- Rows { name, best, week, mine } for one game, sorted by the chosen column (ties by name); scores from earlier
-- weeks count as 0 for "week". peers = { [name] = { best, weekBest, week, t } }.
function L.gameBoard(peers, mine, myName, by, now)
  local week = L.gameWeek(now)
  local rows = {}
  local function add(name, best, wk, w)
    table.insert(rows, { name = name, best = best or 0, week = (w == week) and (wk or 0) or 0, mine = name == myName })
  end
  for name, e in pairs(peers or {}) do
    if type(e) == "table" and name ~= myName then add(name, e.best, e.weekBest, e.week) end
  end
  if myName and mine and (mine.best or 0) > 0 then add(myName, mine.best, mine.weekBest, mine.week) end
  local key = by == "week" and "week" or "best"
  table.sort(rows, function(a, b)
    if a[key] ~= b[key] then return a[key] > b[key] end
    return a.name < b.name
  end)
  return rows
end
