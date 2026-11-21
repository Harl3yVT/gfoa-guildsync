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
  SCORE_SANE = 200000,    -- more than any board can give (all pegs at x5 plus the biggest win bonus)
  SAVE_BALLS_MAX = 9999,  -- your own saved game: free balls can take it past 99
  SLOW_RANGE = 70,        -- slow motion while a ball is this close to the last pink peg
}
L.PAW = P

-- ---------------------------------------------------------------------------
-- Seeded random numbers: the same seed gives the same numbers in every client (daily boards, challenges, saves).
-- Park-Miller "minimal standard": every product stays below 2^53, so doubles are exact.
-- ---------------------------------------------------------------------------

local RNG_M = 2147483647

function L.cleanSeed(seed)
  seed = floor(tonumber(seed) or 1) % RNG_M
  if seed <= 0 then seed = seed + RNG_M - 1 end
  return seed
end

-- rng(n) -> 1..n like math.random, keeping its state in holder.rngS (so a game can be saved and resumed).
function L.makeRng(holder)
  holder.rngS = L.cleanSeed(holder.rngS)
  return function(n)
    holder.rngS = (holder.rngS * 16807) % RNG_M
    return floor(holder.rngS / RNG_M * (n or 1)) + 1
  end
end

-- UTC day number (daily boards change at 00:00 UTC).
function L.gameDay(t)
  return floor((t or 0) / 86400)
end

-- Same seed for everyone on one UTC day, different per game.
function L.dailySeed(game, day)
  local s = 7
  for i = 1, #game do s = (s * 31 + string.byte(game, i)) % RNG_M end
  return L.cleanSeed(s + (floor(day or 0) % 100000) * 7919 + 1)
end

-- ---------------------------------------------------------------------------
-- Layouts: lists of { x, y }. Every layout keeps pegs 20+ px apart and inside the board (tests/test_games.lua).
-- ---------------------------------------------------------------------------

local function ring(out, cx, cy, rx, ry, n, a0)
  for i = 0, n - 1 do
    local a = (a0 or 0) + i * 2 * math.pi / n
    table.insert(out, { x = cx + rx * cos(a), y = cy + ry * sin(a) })
  end
end

-- n points evenly spaced along a curve f(u) for u in 0..1 (sampled by arc length). closed: the end meets the start.
local function curve(out, f, n, closed)
  local pts, len = {}, { 0 }
  local steps = 600
  for i = 0, steps do
    local x, y = f(i / steps)
    pts[i + 1] = { x, y }
    if i > 0 then
      local a, b = pts[i], pts[i + 1]
      len[i + 1] = len[i] + sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
    end
  end
  local total = len[#len]
  local k = 1
  for j = 0, n - 1 do
    local want = total * j / (closed and n or (n - 1))
    while k < #len - 1 and len[k + 1] < want do k = k + 1 end
    local seg = len[k + 1] - len[k]
    local u = seg > 0 and (want - len[k]) / seg or 0
    local a, b = pts[k], pts[k + 1]
    table.insert(out, { x = a[1] + (b[1] - a[1]) * u, y = a[2] + (b[2] - a[2]) * u })
  end
end

-- Drops points closer than `gap` to one kept before them (sharp corners of curves).
local function spaced(pts, gap)
  local out = {}
  for _, p in ipairs(pts) do
    local ok = true
    for _, q in ipairs(out) do
      if (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 < gap * gap then
        ok = false
        break
      end
    end
    if ok then table.insert(out, p) end
  end
  return out
end

local function row(out, y, x0, x1, step)
  for x = x0, x1, step do table.insert(out, { x = x, y = y }) end
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
    local r = 0
    for y = 100, 400, 30 do
      local shift = (r % 2 == 1) and 20 or 0
      for x = 20 + shift, 380, 40 do
        if abs(x - 200) / 200 + abs(y - 250) / 160 <= 1.2 then table.insert(out, { x = x, y = y }) end
      end
      r = r + 1
    end
    return out
  end },
  { name = "Heart", build = function()
    local out = {}
    local function heart(s, cy)
      return function(u)
        local t = u * 2 * math.pi
        local x = 16 * sin(t) ^ 3
        local y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
        return 200 + x * s, cy - y * s
      end
    end
    curve(out, heart(9.6, 232), 42, true)
    curve(out, heart(5, 240), 22, true)
    return spaced(out, 21)
  end },
  { name = "Crown", build = function()
    -- A crown silhouette filled from an offset 28 px grid: a band of three rows and five spikes.
    local out = {}
    local spikes = { { 70, 160 }, { 135, 190 }, { 200, 130 }, { 265, 190 }, { 330, 160 } }
    local r = 0
    for y = 132, 392, 26 do
      local shift = (r % 2 == 1) and 14 or 0
      for x = 46 + shift, 354, 28 do
        local keep = y >= 330
        for _, s in ipairs(spikes) do
          local h = 330 - s[2]
          if y >= s[2] and y < 330 and abs(x - s[1]) <= 6 + 30 * (y - s[2]) / h then keep = true end
        end
        if keep then table.insert(out, { x = x, y = y }) end
      end
      r = r + 1
    end
    return out
  end },
  { name = "Spiral", build = function()
    local out = {}
    curve(out, function(u)
      local a = 0.6 + u * 4.4 * math.pi
      local r = 24 + 9.5 * a
      return 200 + r * cos(a), 255 + r * 0.92 * sin(a)
    end, 62, false)
    return out
  end },
  { name = "Twin towers", build = function()
    local out = {}
    for i = 0, 8 do
      local y = 128 + i * 32
      local shift = (i % 2 == 1) and 14 or 0
      for _, cx in ipairs({ 92, 308 }) do
        for k = -1, 1 do table.insert(out, { x = cx + k * 30 + shift - 7, y = y }) end
      end
    end
    row(out, 220, 150, 250, 25)
    row(out, 316, 162, 238, 38)
    return out
  end },
  { name = "Guild paw", build = function()
    local out = {}
    row(out, 104, 26, 374, 34)
    row(out, 132, 43, 357, 34)
    ring(out, 200, 330, 74, 54, 16)
    ring(out, 200, 330, 28, 18, 5, 0.6)
    for _, toe in ipairs({ { 104, 240 }, { 162, 200 }, { 238, 200 }, { 296, 240 } }) do
      ring(out, toe[1], toe[2], 22, 22, 6)
    end
    return out
  end },
}
L.PAW_LAYOUTS = LAYOUTS

-- ---------------------------------------------------------------------------
-- Class powers: one per game, armed with a button before a shot (docs/minigames.md section 5)
-- ---------------------------------------------------------------------------

L.PAW_POWERS = {
  MAGE = { name = "Split", text = "the ball splits in two on its first hit" },
  HUNTER = { name = "Aimed Shot", text = "the aim line shows the first 3 bounces" },
  PRIEST = { name = "Shield", text = "if this shot misses the basket, the ball comes back" },
  WARRIOR = { name = "Charge", text = "the ball goes through its first 3 pegs" },
  PALADIN = { name = "Blessing", text = "the basket is twice as wide for one shot" },
  ROGUE = { name = "Pick Pocket", text = "the first hit also lights pegs within 40 px" },
  SHAMAN = { name = "Chain Lightning", text = "the first hit also lights the 3 nearest pegs" },
  WARLOCK = { name = "Drain", text = "+1 ball if the shot hits 5 or more pegs" },
  DRUID = { name = "Shapeshift", text = "a bigger, bouncier ball for one shot" },
}
-- Tuning (balance check: tests/sim_paw_powers.lua keeps every class's random-aim average within 10% of the others).
local POW = {
  CHARGE = 3, CHARGE_SPEED = 1.5, SHIELD_ARMED_SHOT_ONLY = true, SPLIT_SPEED = 0.4, PICK_RANGE = 40, CHAIN = 3, DRAIN_HITS = 5, HUNTER_BOUNCES = 3,
  DRUID_R = 8, DRUID_BOUNCE = 0.9, BLESSING = 2,
}
L.PAW_POWER_TUNING = POW

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

-- opts: class (WoW class file name, gives the power), daily (UTC day), challenge ({ from, score }).
local function setup(g, layout, opts)
  opts = opts or {}
  layout = layout or g.rng(#LAYOUTS)
  local pegs = {}
  for _, pt in ipairs(LAYOUTS[layout].build()) do
    table.insert(pegs, { x = pt.x, y = pt.y, kind = "blue", lit = false, gone = false })
  end
  local pinks = math.min(P.PINKS, floor(#pegs / 4))
  local order = shuffled(#pegs, g.rng)
  for i = 1, pinks do pegs[order[i]].kind = "pink" end
  g.layout, g.layoutName, g.pegs = layout, LAYOUTS[layout].name, pegs
  g.balls, g.score, g.shotScore, g.pinkTotal, g.pinkLeft = P.BALLS, 0, 0, pinks, pinks
  g.state, g.t, g.acc, g.ball, g.shot, g.events = "aim", 0, 0, nil, nil, {}
  g.power = L.PAW_POWERS[opts.class or ""] and opts.class or nil
  g.powerUsed, g.armed, g.shield = false, nil, false
  g.daily, g.challenge, g.shots = opts.daily, opts.challenge, 0
  pickGold(g)
  return g
end

-- New game on layout `layout` (1..#LAYOUTS, random when nil) with any rng(n) -> 1..n.
function L.pawNewGame(rng, layout, opts)
  return setup({ rng = rng or math.random }, layout, opts)
end

-- New game from a seed: the same seed gives the same board, pinks and first gold in every client.
-- The layout comes from the seed too unless given.
function L.pawNewSeeded(seed, opts, layout)
  local g = { seed = L.cleanSeed(seed), rngS = seed }
  g.rng = L.makeRng(g)
  return setup(g, layout, opts)
end

-- Today's board for everyone: seed from the UTC day.
function L.pawNewDaily(t, opts)
  opts = opts or {}
  local day = L.gameDay(t)
  opts.daily = day
  return L.pawNewSeeded(L.dailySeed("paw", day), opts)
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
L.pawPinksCleared = pinksCleared

function L.pawBasketX(t)
  return P.W / 2 + P.BASKET_SWING * sin(t * P.BASKET_RATE)
end

-- Basket width right now (Blessing doubles it for one shot).
function L.pawBasketW(g)
  if g.shot and g.shot.power == "PALADIN" then return P.BASKET_W * POW.BLESSING end
  return P.BASKET_W
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

-- The power can be armed (or disarmed) while aiming, once per game.
function L.pawCanArm(g)
  return g.state == "aim" and g.power ~= nil and not g.powerUsed
end

function L.pawArm(g, on)
  if on == nil then on = not g.armed end
  if on and not L.pawCanArm(g) then return false end
  g.armed = on and g.power or nil
  return true
end

local function newBall(angle, power)
  local b = { x = P.LAUNCH_X, y = P.LAUNCH_Y, vx = P.SPEED * sin(angle), vy = P.SPEED * cos(angle), slow = 0, age = 0,
    r = P.BALL_R, bounce = P.BOUNCE, pierce = 0, passed = {} }
  if power == "DRUID" then b.r, b.bounce = POW.DRUID_R, POW.DRUID_BOUNCE end
  if power == "WARRIOR" then
    b.pierce = POW.CHARGE
    b.vx, b.vy = b.vx * POW.CHARGE_SPEED, b.vy * POW.CHARGE_SPEED
  end
  return b
end

function L.pawFire(g, angle)
  if g.state ~= "aim" or g.balls <= 0 then return false end
  angle = L.pawClampAim(angle or 0)
  local power = g.armed
  if power then
    g.powerUsed, g.armed = true, nil
    if power == "PRIEST" then g.shield = true end
  end
  g.balls = g.balls - 1
  g.shots = (g.shots or 0) + 1
  local b = newBall(angle, power)
  g.shot = { balls = { b }, power = power, hits = 0, caught = false, firstHit = false }
  g.ball = b
  g.state, g.shotScore = "fly", 0
  return true
end

-- kind, value, and the board point it happened at (for floating numbers).
local function push(g, kind, a, x, y) table.insert(g.events, { kind = kind, value = a, x = x, y = y }) end

local function endShot(g)
  local shot = g.shot
  g.ball, g.shot = nil, nil
  for _, p in ipairs(g.pegs) do
    if p.lit then p.lit, p.gone = false, true end
  end
  local caught = shot and shot.caught
  if POW.SHIELD_ARMED_SHOT_ONLY and g.shield and not (shot and shot.power == "PRIEST") then g.shield = false end
  if caught then
    g.balls = g.balls + 1
    push(g, "free")
  elseif g.shield then
    g.shield = false
    g.balls = g.balls + 1
    push(g, "shield")
  end
  if shot and shot.power == "WARLOCK" and shot.hits >= POW.DRAIN_HITS then
    g.balls = g.balls + 1
    push(g, "drain")
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
  if g.shot then g.shot.hits = g.shot.hits + 1 end
  local pts = P.POINTS[p.kind] * L.pawMultiplier(pinksCleared(g))
  g.score, g.shotScore = g.score + pts, g.shotScore + pts
  if p.kind == "gold" then
    g.balls = g.balls + 1
    push(g, "gold", pts, p.x, p.y)
  else
    push(g, "hit", pts, p.x, p.y)
  end
end

-- First-hit powers: Split adds a second ball, Pick Pocket and Chain Lightning light more pegs.
local function firstHit(g, b, p)
  local shot = g.shot
  if not shot or shot.firstHit then return end
  shot.firstHit = true
  local power = shot.power
  if power == "MAGE" then
    local b2 = newBall(0)
    b2.x, b2.y, b2.vx, b2.vy = b.x, b.y, -b.vx * POW.SPLIT_SPEED, b.vy * POW.SPLIT_SPEED
    if abs(b2.vx) < 40 then b2.vx = (b.vx >= 0) and -90 or 90 end
    table.insert(shot.balls, b2)
    push(g, "split", nil, b.x, b.y)
  elseif power == "ROGUE" then
    for _, q in ipairs(g.pegs) do
      if q ~= p and not q.gone and not q.lit and (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2 <= POW.PICK_RANGE ^ 2 then
        hitPeg(g, q)
      end
    end
  elseif power == "SHAMAN" then
    local near = {}
    for _, q in ipairs(g.pegs) do
      if q ~= p and not q.gone and not q.lit then
        table.insert(near, { q = q, d = (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2 })
      end
    end
    table.sort(near, function(a, c) return a.d < c.d end)
    for i = 1, math.min(POW.CHAIN, #near) do hitPeg(g, near[i].q) end
  end
end

-- Moves ball b one fixed step. Returns the first peg touched (or nil). Shared by the game and the aim preview.
-- Charge: the ball goes through its first b.pierce pegs (and never bounces off a peg it went through).
local function stepBall(b, pegs, onHit)
  local dt = P.STEP
  b.vy = b.vy + P.GRAVITY * dt
  b.x, b.y = b.x + b.vx * dt, b.y + b.vy * dt
  local R = b.r or P.BALL_R
  if b.x < R then b.x, b.vx = R, abs(b.vx) * P.WALL_BOUNCE end
  if b.x > P.W - R then b.x, b.vx = P.W - R, -abs(b.vx) * P.WALL_BOUNCE end
  if b.y < R then b.y, b.vy = R, abs(b.vy) * P.WALL_BOUNCE end
  local rr = R + P.PEG_R
  local bounce = b.bounce or P.BOUNCE
  local touched
  for _, p in ipairs(pegs) do
    if not p.gone and not (b.passed and b.passed[p]) then
      local dx, dy = b.x - p.x, b.y - p.y
      local d2 = dx * dx + dy * dy
      if d2 < rr * rr then
        if (b.pierce or 0) > 0 then
          b.pierce = b.pierce - 1
          b.passed[p] = true
        else
          local d = sqrt(d2)
          local nx, ny
          if d < 1e-6 then nx, ny, d = 0, -1, 0 else nx, ny = dx / d, dy / d end
          b.x, b.y = p.x + nx * rr, p.y + ny * rr
          local vn = b.vx * nx + b.vy * ny
          if vn < 0 then
            b.vx = b.vx - (1 + bounce) * vn * nx
            b.vy = b.vy - (1 + bounce) * vn * ny
          end
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
  local reach = (b.r or P.BALL_R) + P.PEG_R + 3
  for _, p in ipairs(g.pegs) do
    if p.lit and not p.gone then
      local dx, dy = b.x - p.x, b.y - p.y
      if all or dx * dx + dy * dy <= reach * reach then p.lit, p.gone = false, true end
    end
  end
end

local function stepShot(g)
  local shot = g.shot
  local live = 0
  for i = 1, #shot.balls do
    local b = shot.balls[i]
    if not b.done then
      local prevY = b.y
      stepBall(b, g.pegs, function(p)
        local fresh = not p.lit
        hitPeg(g, p)
        if fresh then firstHit(g, b, p) end
      end)
      b.age = b.age + P.STEP
      local top = P.BASKET_Y - b.r
      if prevY < top and b.y >= top and abs(b.x - L.pawBasketX(g.t)) <= L.pawBasketW(g) / 2 then
        b.done, shot.caught = true, true
      elseif b.y > P.H + b.r then
        b.done = true
      else
        live = live + 1
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
  end
  if live == 0 then
    endShot(g)
  else
    for _, b in ipairs(shot.balls) do
      if not b.done then
        g.ball = b
        break
      end
    end
  end
end

-- Advances the game by dt seconds (any size; runs whole fixed steps, the rest carries over).
function L.pawUpdate(g, dt)
  dt = math.min(dt or 0, 0.25)
  g.t = g.t + dt
  if g.state ~= "fly" then return end
  g.acc = g.acc + dt
  while g.acc >= P.STEP and g.state == "fly" do
    g.acc = g.acc - P.STEP
    stepShot(g)
  end
  if g.state ~= "fly" then g.acc = 0 end
end

-- Finishes a ball in flight at once (no drawing): used before saving, so a reload never loses or repeats a ball.
function L.pawFinishShot(g)
  local guard = 0
  while g.state == "fly" and guard < 100000 do
    L.pawUpdate(g, 0.25)
    guard = guard + 1
  end
end

-- Balls in flight (for drawing).
function L.pawBallsInPlay(g)
  local out = {}
  if g.shot then
    for _, b in ipairs(g.shot.balls) do
      if not b.done then table.insert(out, b) end
    end
  end
  return out
end

-- true while a ball is close to the last pink peg (the window slows time down).
function L.pawSlowMo(g)
  if g.state ~= "fly" or not g.shot then return false end
  local last
  for _, p in ipairs(g.pegs) do
    if p.kind == "pink" and not p.gone and not p.lit then
      if last then return false end
      last = p
    end
  end
  if not last then return false end
  for _, b in ipairs(g.shot.balls) do
    if not b.done and (b.x - last.x) ^ 2 + (b.y - last.y) ^ 2 <= P.SLOW_RANGE ^ 2 then return true end
  end
  return false
end

-- Dotted aim line: up to n points (every few steps) until the first peg the ball would touch, or the bottom.
-- Aimed Shot (armed) follows the ball through its first 3 bounces instead.
function L.pawPreview(g, angle, n)
  angle = L.pawClampAim(angle or 0)
  local b = newBall(angle, g.armed)
  local bounces = (g.armed == "HUNTER") and POW.HUNTER_BOUNCES or 1
  n = n or 30
  local pts, seen, hits = {}, {}, 0
  for i = 1, 600 * bounces do
    local touched = stepBall(b, g.pegs)
    if touched and not seen[touched] then
      seen[touched] = true
      hits = hits + 1
    end
    if i % 8 == 0 or touched then table.insert(pts, { x = b.x, y = b.y }) end
    if hits >= bounces or #pts >= n or b.y > P.H then break end
  end
  return pts
end

-- ---------------------------------------------------------------------------
-- Save / resume (per character, on logout and /reload)
-- ---------------------------------------------------------------------------

local KIND_CODE = { blue = "b", pink = "p", gold = "g" }
local CODE_KIND = { b = "blue", p = "pink", g = "gold" }

-- Plain table for SavedVariables, or nil when there is nothing to keep (game over, or not started from a seed).
-- Call L.pawFinishShot first: a ball in flight is not saved.
function L.pawSave(g)
  if not g or g.state ~= "aim" or not g.seed then return nil end
  local codes = {}
  for i, p in ipairs(g.pegs) do
    local c = KIND_CODE[p.kind] or "b"
    codes[i] = p.gone and string.upper(c) or c
  end
  return {
    v = 1, seed = g.seed, rngS = g.rngS, layout = g.layout, pegs = table.concat(codes),
    balls = g.balls, score = g.score, t = g.t, power = g.power, powerUsed = g.powerUsed or nil,
    shield = g.shield or nil, daily = g.daily, shots = g.shots,
    challenge = type(g.challenge) == "table" and { from = g.challenge.from, score = g.challenge.score } or nil,
  }
end

-- Rebuilds a saved game; nil for anything that doesn't fit (other version, layout changed, junk).
function L.pawLoad(s)
  if type(s) ~= "table" or s.v ~= 1 or not LAYOUTS[tonumber(s.layout) or 0] or type(s.pegs) ~= "string" then
    return nil
  end
  local g = L.pawNewSeeded(s.seed, { class = s.power, daily = tonumber(s.daily), challenge = s.challenge }, s.layout)
  if #s.pegs ~= #g.pegs or string.find(s.pegs, "[^bpgBPG]") then return nil end
  for i, p in ipairs(g.pegs) do
    local c = string.sub(s.pegs, i, i)
    p.kind = CODE_KIND[string.lower(c)]
    p.gone = c ~= string.lower(c)
  end
  local balls, score = tonumber(s.balls), tonumber(s.score)
  -- your own save: loose limits (P.SCORE_SANE and the ball count are for checking guildmates' scores)
  if not balls or balls < 1 or balls > P.SAVE_BALLS_MAX or not score or score < 0 or score > L.GAME_SCORE_MAX then
    return nil
  end
  g.balls, g.score = floor(balls), floor(score)
  g.rngS = L.cleanSeed(s.rngS)
  g.t = tonumber(s.t) or 0
  g.powerUsed, g.shield, g.shots = s.powerUsed and true or false, s.shield and true or false, tonumber(s.shots) or 0
  g.pinkLeft = pinksLeft(g)
  if g.pinkLeft == 0 then return nil end
  return g
end

-- ---------------------------------------------------------------------------
-- Scores (shared by every minigame)
-- ---------------------------------------------------------------------------

L.GAME_IDS = { paw = "Paw Drop" }
L.GAME_SCORE_MAX = 99999999
-- Received scores above what a game can produce are dropped and never shown (score sanity check).
L.GAME_SANE = { paw = P.SCORE_SANE }

-- Week number since Monday 1970-01-05 00:00 UTC (resets Monday 00:00 UTC).
function L.gameWeek(t)
  return floor(((t or 0) - 345600) / 604800)
end

-- Records a finished game into rec (account table for one game). Returns true on a new all-time best.
-- Daily games also keep rec.daily = { day, best } (second return value: true on a new best for today).
function L.gameRecord(rec, score, won, t, who, daily)
  score = floor(tonumber(score) or 0)
  rec.played = (rec.played or 0) + 1
  if won then rec.won = (rec.won or 0) + 1 end
  local week = L.gameWeek(t)
  if rec.week ~= week then rec.week, rec.weekBest = week, 0 end
  if score > (rec.weekBest or 0) then rec.weekBest = score end
  local dailyBest = false
  if daily then
    if type(rec.daily) ~= "table" or rec.daily.day ~= daily then rec.daily = { day = daily, best = 0 } end
    if score > (rec.daily.best or 0) then
      rec.daily.best = score
      dailyBest = true
    end
  end
  if score > (rec.best or 0) then
    rec.best, rec.bestBy, rec.bestAt = score, who, t
    return true, dailyBest
  end
  return false, dailyBest
end

local function cleanScore(v)
  v = tonumber(v)
  if not v or v ~= v or v < 0 then return 0 end
  return math.min(floor(v), L.GAME_SCORE_MAX)
end

local function sane(game, v)
  return v <= (L.GAME_SANE[game] or L.GAME_SCORE_MAX)
end

-- Extra fields are short words or numbers only (they ride a ':'-separated message).
local function cleanExtra(v)
  if v == nil or v == false then return "" end
  return (string.gsub(tostring(v), "[^%w]", ""))
end

-- M:<game>:<best>:<weekBest>:<week>[:<extra>...]. Extras by position (docs/sync-format.md): 1 = class file name,
-- 2 = Paw Stack's biggest ball ever (1-11).
function L.gameScoreMessage(game, rec, t, extras)
  local week = L.gameWeek(t)
  local wk = (rec.week == week) and cleanScore(rec.weekBest) or 0
  local msg = string.format("M:%s:%d:%d:%d", game, cleanScore(rec.best), wk, week)
  if extras then
    local n = 0
    for i in pairs(extras) do
      if type(i) == "number" and i > n then n = i end
    end
    for i = 1, n do msg = msg .. ":" .. cleanExtra(extras[i]) end
  end
  return msg
end

-- MD:<game>:<score>:<day>: today's best on the daily board (nil when there is none for today).
function L.gameDailyMessage(game, rec, t)
  local day = L.gameDay(t)
  if type(rec.daily) ~= "table" or rec.daily.day ~= day or cleanScore(rec.daily.best) <= 0 then return nil end
  return string.format("MD:%s:%d:%d", game, cleanScore(rec.daily.best), day)
end

-- Returns "M?" for a query; "M", game, best, weekBest, week, extras (list of strings after the week, maybe empty);
-- "MD", game, score, day; nil for anything else, unknown games and scores no board can give.
function L.parseGameMessage(msg)
  if type(msg) ~= "string" then return nil end
  if msg == "M?" then return "M?" end
  local dgame, dscore, dday = string.match(msg, "^MD:(%l+):(%d+):(%d+)$")
  if dgame then
    if not L.GAME_IDS[dgame] then return nil end
    dscore = cleanScore(dscore)
    if not sane(dgame, dscore) then return nil end
    return "MD", dgame, dscore, tonumber(dday)
  end
  local game, best, wk, week, rest = string.match(msg, "^M:(%l+):(%d+):(%d+):(%-?%d+)(.*)$")
  if not game or not L.GAME_IDS[game] or (rest ~= "" and string.sub(rest, 1, 1) ~= ":") then return nil end
  best, wk = cleanScore(best), cleanScore(wk)
  if not sane(game, best) or not sane(game, wk) then return nil end
  local extras = {}
  for field in string.gmatch(rest, ":([^:]*)") do table.insert(extras, field) end
  return "M", game, best, wk, tonumber(week), extras
end

-- An M line's week is the sender's current week. More than a week away from ours = a wrong PC clock: ignore the line
-- (the officer's guildGames copy keeps the highest week, so one bad week would stick there).
function L.gameWeekPlausible(week, t)
  week = tonumber(week)
  return week ~= nil and math.abs(week - L.gameWeek(t)) <= 1
end

-- A WoW class file name from an M extra field, or nil.
function L.gameClass(v)
  if type(v) == "string" and string.match(v, "^%u+$") and #v <= 12 then return v end
  return nil
end

-- Leaderboards view rows (GuildWindow.lua, combined "This week | Best ever" like PvP): { name, week, total, value,
-- rank, mine }, value = the column ranked by ("week" or "total"), ties by the other column then name. Equal
-- results share a rank. keep(name) -> false leaves a name out (former members).
function L.gameLeaderboardRows(peers, mine, myName, by, now, keep)
  local rows = {}
  for _, r in ipairs(L.gameBoard(peers, mine, myName, "best", now)) do
    if not keep or keep(r.name) then
      local row = { name = r.name, week = r.week, total = r.best, mine = r.mine }
      row.value = by == "total" and row.total or row.week
      table.insert(rows, row)
    end
  end
  local function tie(r) return by == "total" and r.week or r.total end
  table.sort(rows, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    if tie(a) ~= tie(b) then return tie(a) > tie(b) end
    return string.lower(a.name) < string.lower(b.name)
  end)
  for i, r in ipairs(rows) do
    local p = rows[i - 1]
    r.rank = (p and p.value == r.value and tie(p) == tie(r)) and p.rank or i
  end
  return rows
end

-- Rows { name, best, week, today, class, mine } for one game, sorted by the chosen column ("best", "week" or
-- "today"; ties by name). Scores from earlier weeks / days count as 0. peers = { [name] = { best, weekBest, week,
-- t, class, day, daily, biggest } }; mine = the account record (best, weekBest, week, daily = { day, best },
-- biggest). biggest = Paw Stack's biggest ball ever (nil for other games).
function L.gameBoard(peers, mine, myName, by, now, myClass)
  local week, day = L.gameWeek(now), L.gameDay(now)
  local rows = {}
  local function add(name, e, isMe, class)
    local today = 0
    if isMe then
      if type(e.daily) == "table" and e.daily.day == day then today = e.daily.best or 0 end
    elseif e.day == day then
      today = e.daily or 0
    end
    local r = { name = name, best = e.best or 0, week = (e.week == week) and (e.weekBest or 0) or 0, today = today,
      class = class, mine = isMe, biggest = tonumber(e.biggest) }
    if r.best > 0 or r.today > 0 then table.insert(rows, r) end
  end
  for name, e in pairs(peers or {}) do
    if type(e) == "table" and name ~= myName then add(name, e, false, e.class) end
  end
  if myName and type(mine) == "table" then add(myName, mine, true, myClass) end
  local key = (by == "week" or by == "today") and by or "best"
  table.sort(rows, function(a, b)
    if a[key] ~= b[key] then return a[key] > b[key] end
    return a.name < b.name
  end)
  return rows
end

-- ---------------------------------------------------------------------------
-- Guild and social (docs/minigames.md section 6): challenges, the weekly pink-peg goal, tooltip badges and the
-- officer copy of scores for the Discord weekly champions post
-- ---------------------------------------------------------------------------

L.GAME_GOAL_DEFAULT = 1000
L.GAME_GOAL_MAX = 1000000
L.GAME_PINKS_MAX = 100000   -- pink pegs one player can clear in a week (far above what anyone plays)
L.GAME_ORDER = { "paw", "stack" }

local function cleanSeedNum(v)
  v = tonumber(v)
  if not v or v ~= floor(v) or v < 1 or v > 2147483646 then return nil end
  return v
end

-- MC:<game>:<seed>:<score>: "play my last board and beat this", sent by hidden addon whisper on a click only.
function L.challengeMessage(game, seed, score)
  return string.format("MC:%s:%d:%d", game, cleanSeedNum(seed) or 1, cleanScore(score))
end

-- MR:<game>:<seed>:<score>: the result of playing someone's challenge, whispered back to them.
function L.challengeResultMessage(game, seed, score)
  return string.format("MR:%s:%d:%d", game, cleanSeedNum(seed) or 1, cleanScore(score))
end

-- MG:<goal>: the guild's weekly pink-peg goal, from an officer's addon.
function L.goalMessage(goal)
  return string.format("MG:%d", floor(tonumber(goal) or L.GAME_GOAL_DEFAULT))
end

-- "MC" / "MR", game, seed, score; "MG", goal; nil for anything else (unknown game, bad seed, impossible score).
function L.parseSocialMessage(msg)
  if type(msg) ~= "string" then return nil end
  local goal = string.match(msg, "^MG:(%d+)$")
  if goal then
    goal = tonumber(goal)
    if goal < 1 or goal > L.GAME_GOAL_MAX then return nil end
    return "MG", goal
  end
  local kind, game, seed, score = string.match(msg, "^(M[CR]):(%l+):(%d+):(%d+)$")
  if not kind or not L.GAME_IDS[game] then return nil end
  seed, score = cleanSeedNum(seed), cleanScore(score)
  if not seed or not sane(game, score) then return nil end
  return kind, game, seed, score
end

-- Who won a challenge from my side: "win", "lose" or "tie".
function L.challengeOutcome(mine, theirs)
  mine, theirs = tonumber(mine) or 0, tonumber(theirs) or 0
  if mine > theirs then return "win" elseif mine < theirs then return "lose" end
  return "tie"
end

-- Pink pegs I cleared this week. The record is account-wide (SavedVariables), so with `name` the count is per
-- character (rec.pinksBy[name] = { week, n }): an alt must not send its main's pegs again (the guild goal would count
-- them twice). Without `name`: rec.pinks = { week, n }.
local function pinkSlot(rec, name, create)
  if type(name) ~= "string" then return rec.pinks end
  if type(rec.pinksBy) ~= "table" then
    if not create then return nil end
    rec.pinksBy = {}
  end
  return rec.pinksBy[name]
end

function L.gamePinksWeek(rec, t, name)
  local p = type(rec) == "table" and pinkSlot(rec, name)
  if type(p) ~= "table" or p.week ~= L.gameWeek(t) then return 0 end
  return math.min(L.GAME_PINKS_MAX, math.max(0, floor(tonumber(p.n) or 0)))
end

function L.gameAddPinks(rec, n, t, name)
  local week = L.gameWeek(t)
  local p = pinkSlot(rec, name, true)
  if type(p) ~= "table" or p.week ~= week then
    p = { week = week, n = 0 }
    if type(name) == "string" then
      for k, v in pairs(rec.pinksBy) do
        if type(v) ~= "table" or v.week ~= week then rec.pinksBy[k] = nil end   -- only this week's counts matter
      end
      rec.pinksBy[name] = p
    else
      rec.pinks = p
    end
  end
  p.n = math.min(L.GAME_PINKS_MAX, (p.n or 0) + math.max(0, floor(tonumber(n) or 0)))
end

-- A pink-peg count from an M extra field, or nil.
function L.gamePinks(v)
  v = tonumber(v)
  if not v or v ~= floor(v) or v < 0 or v > L.GAME_PINKS_MAX then return nil end
  return v
end

-- The guild's pink pegs this week: every guildmate heard this week plus me.
function L.goalTotal(peers, mine, myName, t)
  local week, total = L.gameWeek(t), 0
  for name, e in pairs(peers or {}) do
    if type(e) == "table" and name ~= myName and e.week == week then total = total + (L.gamePinks(e.pinks) or 0) end
  end
  return total + L.gamePinksWeek(mine, t, myName)
end

-- Tooltip badges for a name ("Paw Drop: #1 this week"), from scores already heard: top 3 of this week per game.
-- peersByGame / recordsByGame are keyed by game id.
function L.gameBadges(peersByGame, recordsByGame, name, myName, t)
  local out = {}
  if type(name) ~= "string" then return out end
  local lname = string.lower(name)
  for _, game in ipairs(L.GAME_ORDER) do
    local rows = L.gameLeaderboardRows(peersByGame and peersByGame[game], recordsByGame and recordsByGame[game],
      myName, "week", t)
    for _, r in ipairs(rows) do
      if r.week > 0 and r.rank <= 3 and string.lower(r.name) == lname then
        table.insert(out, string.format("%s: #%d this week", L.GAME_IDS[game] or game, r.rank))
      end
    end
  end
  return out
end

-- Officer mode: copy one heard score into GFoAGuildSyncDB.guildGames[game][name] (the uploader sends it; the bot's
-- minigame_store reads best / weekBest / week / t / class / biggest, and prev = { week, weekBest, biggest }).
-- A score for a later week doesn't wipe the earlier week's best: the latest week before it stays in `prev` until the
-- next upload has carried it (the bot keeps the max per week, so sending it twice changes nothing). The all-time best
-- never goes down. Entries older than 30 days are dropped.
function L.guildGamesCopy(db, game, name, e, t)
  if type(db) ~= "table" or not L.GAME_IDS[game] or type(name) ~= "string" or type(e) ~= "table" then return end
  if type(db.guildGames) ~= "table" then db.guildGames = {} end
  local g = db.guildGames[game]
  if type(g) ~= "table" then
    g = {}
    db.guildGames[game] = g
  end
  local old = type(g[name]) == "table" and g[name] or nil
  local new = { best = cleanScore(e.best), weekBest = cleanScore(e.weekBest), week = tonumber(e.week), t = t,
    class = L.gameClass(e.class), biggest = tonumber(e.biggest) }
  if old then
    -- every week score we know for this name: the old entry, its prev and the new message
    local weeks = {}
    local function add(wk, best, biggest)
      wk = tonumber(wk)
      best = cleanScore(best)
      if not wk or best <= 0 then return end
      local w = weeks[wk]
      if not w then
        weeks[wk] = { week = wk, weekBest = best, biggest = tonumber(biggest) }
      else
        w.weekBest = math.max(w.weekBest, best)
        w.biggest = math.max(w.biggest or 0, tonumber(biggest) or 0)
        if w.biggest == 0 then w.biggest = nil end
      end
    end
    add(old.week, old.weekBest, old.biggest)
    if type(old.prev) == "table" then add(old.prev.week, old.prev.weekBest, old.prev.biggest) end
    local oldWeek = tonumber(old.week)
    if new.week and oldWeek and new.week < oldWeek then
      -- a late message for an earlier week: it only counts for that week, the newer entry stays on top
      add(new.week, new.weekBest, new.biggest)
      new.week, new.weekBest, new.biggest = oldWeek, cleanScore(old.weekBest), tonumber(old.biggest)
      new.class = new.class or L.gameClass(old.class)
    end
    add(new.week, new.weekBest, new.biggest)
    local top = new.week and weeks[new.week]
    if top then new.weekBest, new.biggest = top.weekBest, top.biggest end
    local prev
    for wk, w in pairs(weeks) do
      if (not new.week or wk < new.week) and (not prev or wk > prev.week) then prev = w end
    end
    new.prev = prev
    new.best = math.max(new.best, cleanScore(old.best))
    new.class = new.class or L.gameClass(old.class)
  end
  g[name] = new
  for who, v in pairs(g) do
    if type(v) ~= "table" or t - (tonumber(v.t) or 0) > 30 * 86400 then g[who] = nil end
  end
end

-- ---------------------------------------------------------------------------
-- Auto-open of the minigame window (Games.lua, option "gamesAutoOpen"). st = { opened = "taxi" / "afk" / "queue"
-- while the window opened itself, queueDismissed = true once the player closed it while queued }.
-- ---------------------------------------------------------------------------

-- "confirm" while a battleground invite is up, "queued" while waiting, else nil. statusOf(i) = GetBattlefieldStatus(i).
function L.queueState(n, statusOf)
  local state
  for i = 1, n do
    local s = statusOf(i)
    if s == "confirm" then return "confirm" end
    if s == "queued" then state = "queued" end
  end
  return state
end

-- On UPDATE_BATTLEFIELD_STATUS with queue state qs: "open", "close" (it opened for the queue), "closeForce"
-- (the queue popped: whatever opened itself gets out of the way) or nil. A close by the player while queued is
-- remembered until the queue state leaves "queued", so the next status event doesn't open it again.
function L.autoQueueEvent(st, qs)
  if qs ~= "queued" then st.queueDismissed = nil end
  if qs == "queued" then
    if not st.queueDismissed then return "open" end
  elseif qs == "confirm" then
    if st.opened then return "closeForce" end
  elseif st.opened == "queue" then
    return "close"
  end
  return nil
end

-- The window closed (OnHide). byPlayer = false when the addon closed it itself.
function L.autoClosed(st, qs, byPlayer)
  st.opened = nil
  if byPlayer and qs == "queued" then st.queueDismissed = true end
end
