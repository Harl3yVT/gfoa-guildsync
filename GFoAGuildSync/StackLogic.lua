-- GFoA Guild Sync: Paw Stack minigame logic, pure Lua (no WoW API), tested by tests/test_games.lua.
-- A drop-and-merge game of our own (docs/minigames.md section 4): paw-balls in 11 sizes fall into a jar; two equal
-- balls that touch merge into the next size. Board units are pixels, y grows downwards.
-- Physics: position-based circle contacts (a few iterations per fixed step), balls that stay still go to sleep and
-- cost almost nothing until something touches them. Needs GameLogic.lua first (seeded rng, days, records).
local _, ns = ...
ns = ns or {}
local L = ns.logic or {}
ns.logic = L

local sqrt, floor, abs, min, max = math.sqrt, math.floor, math.abs, math.min, math.max

local S = {
  W = 400, H = 440,
  JAR_L = 50, JAR_R = 350, JAR_BOTTOM = 432,
  LINE_Y = 92,              -- a ball resting above this line for OVER_TIME seconds ends the game
  DROP_Y = 46,
  RADII = { 8, 11, 14, 18, 22, 27, 32, 38, 44, 51, 58 },
  DROP_SIZES = 5,           -- the dropper hands out sizes 1-5
  GRAVITY = 900, STEP = 1 / 120, ITERATIONS = 4,
  DAMP = 0.99, WALL_FRICTION = 0.98,
  MAX_SPEED = 600,          -- px/s: pushes out of an overlap (a merge growing inside the pile) never fling a ball
  SLEEP_SPEED = 20, SLEEP_TIME = 0.4, WAKE_PUSH = 0.6,
  COOLDOWN = 0.45,
  OVER_TIME = 2, OVER_GRACE = 1.2,  -- a new ball has this long to fall below the line
  MAX_BALLS = 80,
  SHAKE_UP = 280, SHAKE_SIDE = 60,
  SCORE_SANE = 100000,
}
L.STACK = S
L.GAME_IDS.stack = "Paw Stack"
L.GAME_SANE.stack = S.SCORE_SANE

-- A biggest-ball size from an M extra field (1-11), or nil.
function L.stackBiggest(v)
  v = tonumber(v)
  if not v or v ~= floor(v) or v < 1 or v > #S.RADII then return nil end
  return v
end

-- Points for making size n: the triangle number n(n+1)/2 (two size-11s clear each other for size "12").
function L.stackPoints(n)
  return floor(n * (n + 1) / 2)
end

local function nextSize(g)
  return g.rng(S.DROP_SIZES)
end

local function setup(g, opts)
  opts = opts or {}
  g.balls, g.score, g.state, g.t, g.acc = {}, 0, "play", 0, 0
  g.cool, g.events, g.biggest, g.drops, g.shaken = 0, {}, 0, 0, false
  g.daily, g.challenge, g.overT = opts.daily, opts.challenge, 0
  g.cur = nextSize(g)
  g.nxt = nextSize(g)
  g.x = (S.JAR_L + S.JAR_R) / 2
  return g
end

-- New game from a seed: the same seed gives the same drop order in every client.
function L.stackNewSeeded(seed, opts)
  local g = { seed = L.cleanSeed(seed), rngS = seed }
  g.rng = L.makeRng(g)
  return setup(g, opts)
end

-- Today's drop order for everyone ("Daily").
function L.stackNewDaily(t, opts)
  opts = opts or {}
  local day = L.gameDay(t)
  opts.daily = day
  return L.stackNewSeeded(L.dailySeed("stack", day), opts)
end

local function push(g, kind, value, x, y) table.insert(g.events, { kind = kind, value = value, x = x, y = y }) end

-- Dropper position for a board x (kept inside the jar for the held ball).
function L.stackClampX(g, x)
  local r = S.RADII[g.cur] or S.RADII[1]
  return max(S.JAR_L + r, min(S.JAR_R - r, tonumber(x) or g.x))
end

local function newBall(size, x, y)
  return { size = size, r = S.RADII[size], x = x, y = y, px = x, py = y, vx = 0, vy = 0, still = 0, sleep = false,
    age = 0 }
end

function L.stackCanDrop(g)
  return g.state == "play" and g.cool <= 0 and #g.balls < S.MAX_BALLS
end

-- Drops the held ball at board x. Returns true when it dropped.
function L.stackDrop(g, x)
  if not L.stackCanDrop(g) then return false end
  g.x = L.stackClampX(g, x)
  table.insert(g.balls, newBall(g.cur, g.x, S.DROP_Y))
  g.cur, g.nxt = g.nxt, nextSize(g)
  g.cool, g.drops = S.COOLDOWN, g.drops + 1
  push(g, "drop", g.balls[#g.balls].size, g.x, S.DROP_Y)
  return true
end

-- Shake the jar: once per game, a small upward nudge to every ball.
function L.stackShake(g)
  if g.state ~= "play" or g.shaken then return false end
  g.shaken = true
  for i, b in ipairs(g.balls) do
    b.sleep, b.still = false, 0
    -- velocity lives in the previous position (position-based solver)
    b.py = b.py + S.SHAKE_UP * S.STEP
    b.px = b.px + ((i % 2 == 0) and -S.SHAKE_SIDE or S.SHAKE_SIDE) * S.STEP
  end
  push(g, "shake")
  return true
end

local function wake(b)
  if b.sleep then
    b.sleep, b.still = false, 0
  end
end

local function walls(g)
  for _, b in ipairs(g.balls) do
    if not b.sleep then
      if b.x < S.JAR_L + b.r then b.x = S.JAR_L + b.r end
      if b.x > S.JAR_R - b.r then b.x = S.JAR_R - b.r end
      if b.y < b.r then b.y = b.r end
      if b.y > S.JAR_BOTTOM - b.r then
        b.y = S.JAR_BOTTOM - b.r
        b.px = b.x - (b.x - b.px) * S.WALL_FRICTION
      end
    end
  end
end

-- One pass of contacts: every touching pair (sweep over balls sorted by their top edge), then the jar walls, so a
-- pass always ends with every ball inside the jar.
local function solve(g, order)
  local n = #order
  for i = 1, n do
    local a = order[i]
    local bottom = a.y + a.r
    for j = i + 1, n do
      local b = order[j]
      if b.y - b.r > bottom then break end
      if not (a.sleep and b.sleep) then
        local dx, dy = b.x - a.x, b.y - a.y
        local rr = a.r + b.r
        local d2 = dx * dx + dy * dy
        if d2 < rr * rr then
          local d = sqrt(d2)
          local nx, ny
          if d < 1e-6 then nx, ny, d = 0, 1, 0 else nx, ny = dx / d, dy / d end
          local overlap = rr - d
          if a.sleep and overlap > S.WAKE_PUSH then wake(a) end
          if b.sleep and overlap > S.WAKE_PUSH then wake(b) end
          -- heavier (bigger) balls move less; a sleeping ball doesn't move at all
          local ma, mb = a.r * a.r, b.r * b.r
          local wa = a.sleep and 0 or (b.sleep and 1 or mb / (ma + mb))
          local wb = b.sleep and 0 or (a.sleep and 1 or ma / (ma + mb))
          a.x, a.y = a.x - nx * overlap * wa, a.y - ny * overlap * wa
          b.x, b.y = b.x + nx * overlap * wb, b.y + ny * overlap * wb
        end
      end
    end
  end
  walls(g)
end

local function byTop(a, b)
  return a.y - a.r < b.y - b.r
end

-- Two equal balls touching merge into the next size at their midpoint (two 11s clear each other).
local function merges(g, order)
  local n = #order
  local gone = {}
  local born = {}
  for i = 1, n do
    local a = order[i]
    if not gone[a] then
      for j = i + 1, n do
        local b = order[j]
        if b.y - b.r > a.y + a.r + 1 then break end
        if not gone[b] and b.size == a.size and not (a.sleep and b.sleep) then
          local rr = a.r + b.r + 0.75
          if (b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 <= rr * rr then
            gone[a], gone[b] = true, true
            local size = a.size + 1
            local x, y = (a.x + b.x) / 2, (a.y + b.y) / 2
            local pts = L.stackPoints(size)
            g.score = g.score + pts
            if size <= #S.RADII then
              local r = S.RADII[size]
              x = max(S.JAR_L + r, min(S.JAR_R - r, x))
              y = max(r, min(S.JAR_BOTTOM - r, y))
              local c = newBall(size, x, y)
              c.px, c.py = x - (a.x - a.px + b.x - b.px) / 2, y - (a.y - a.py + b.y - b.py) / 2
              c.age = S.OVER_GRACE   -- a merge isn't a new drop: it counts for the line at once
              table.insert(born, c)
              if size > g.biggest then g.biggest = size end
            end
            push(g, "merge", pts, x, y)
            g.events[#g.events].size = size
            break
          end
        end
      end
    end
  end
  if next(gone) == nil then return false end
  local keep = {}
  for _, b in ipairs(g.balls) do
    if not gone[b] then table.insert(keep, b) end
  end
  for _, c in ipairs(born) do
    -- wake the neighbours: the new ball is bigger and the pile has to make room
    for _, b in ipairs(keep) do
      local rr = b.r + c.r + 4
      if (b.x - c.x) ^ 2 + (b.y - c.y) ^ 2 <= rr * rr then wake(b) end
    end
    table.insert(keep, c)
  end
  g.balls = keep
  return true
end

local function step(g)
  local dt = S.STEP
  local awake = 0
  for _, b in ipairs(g.balls) do
    if not b.sleep then awake = awake + 1 end
  end
  if awake == 0 then
    -- a jar at rest: nothing moves, nothing can merge (merges need an awake ball); only ages and the line count
    for _, b in ipairs(g.balls) do b.age = b.age + dt end
    awake = nil
  end
  for _, b in ipairs(awake and g.balls or {}) do
    if not b.sleep then
      local vx, vy = (b.x - b.px) * S.DAMP, (b.y - b.py) * S.DAMP
      b.px, b.py = b.x, b.y
      b.x, b.y = b.x + vx, b.y + vy + S.GRAVITY * dt * dt
    end
    b.age = b.age + dt
  end
  local order = {}
  if awake then
    for i, b in ipairs(g.balls) do order[i] = b end
    table.sort(order, byTop)
    for _ = 1, S.ITERATIONS do solve(g, order) end
  end
  local maxMove = S.MAX_SPEED * dt
  for _, b in ipairs(g.balls) do
    if not b.sleep then
      local mx, my = b.x - b.px, b.y - b.py
      local m2 = mx * mx + my * my
      if m2 > maxMove * maxMove then
        local k = maxMove / sqrt(m2)
        b.px, b.py = b.x - mx * k, b.y - my * k
      end
      local sp = sqrt((b.x - b.px) ^ 2 + (b.y - b.py) ^ 2) / dt
      if sp < S.SLEEP_SPEED then b.still = b.still + dt else b.still = 0 end
      if b.still >= S.SLEEP_TIME then
        b.sleep, b.px, b.py = true, b.x, b.y
      end
    end
  end
  -- a sleeping ball that lost every contact below it (its support merged or was pushed away) wakes up and falls;
  -- only while something is awake (a jar fully at rest can't lose support, and this check costs time)
  for _, b in ipairs(awake and g.balls or {}) do
    if b.sleep and b.y + b.r < S.JAR_BOTTOM - 0.5 then
      local held = false
      for _, o in ipairs(g.balls) do
        if o ~= b and o.y > b.y - 0.01 then
          local rr = o.r + b.r + 0.5
          if (o.x - b.x) ^ 2 + (o.y - b.y) ^ 2 <= rr * rr then
            held = true
            break
          end
        end
      end
      if not held then wake(b) end
    end
  end
  if awake and not g.noMerge then
    table.sort(order, byTop)
    merges(g, order)
  end
  -- game over: some ball has rested above the line for OVER_TIME seconds
  local above = false
  for _, b in ipairs(g.balls) do
    if b.age >= S.OVER_GRACE and b.y - b.r < S.LINE_Y then
      above = true
      break
    end
  end
  g.overT = above and (g.overT + dt) or 0
  if g.overT >= S.OVER_TIME then
    g.state = "over"
    push(g, "over", g.score)
  end
end

-- Advances the game by dt seconds (any size; runs whole fixed steps, the rest carries over).
function L.stackUpdate(g, dt)
  dt = min(dt or 0, 0.25)
  g.t = g.t + dt
  if g.state ~= "play" then return end
  g.cool = max(0, g.cool - dt)
  g.acc = g.acc + dt
  while g.acc >= S.STEP and g.state == "play" do
    g.acc = g.acc - S.STEP
    step(g)
  end
end

-- How many balls are awake (for tests and the window's idle check).
function L.stackAwake(g)
  local n = 0
  for _, b in ipairs(g.balls) do
    if not b.sleep then n = n + 1 end
  end
  return n
end

-- Lets the jar come to rest (no drawing), at most `seconds` of game time: used before saving.
function L.stackSettle(g, seconds)
  local t = 0
  seconds = seconds or 10
  while g.state == "play" and L.stackAwake(g) > 0 and t < seconds do
    L.stackUpdate(g, 0.25)
    t = t + 0.25
  end
end

-- ---------------------------------------------------------------------------
-- Save / resume (per character, on logout and /reload)
-- ---------------------------------------------------------------------------

-- Never runs physics: what is on screen is what gets saved (a settle here could end the game unseen).
function L.stackSave(g)
  if not g or g.state ~= "play" or not g.seed then return nil end
  local list = {}
  for _, b in ipairs(g.balls) do
    table.insert(list, string.format("%d,%.1f,%.1f", b.size, b.x, b.y))
  end
  return {
    v = 1, seed = g.seed, rngS = g.rngS, cur = g.cur, nxt = g.nxt, score = g.score, biggest = g.biggest,
    drops = g.drops, shaken = g.shaken or nil, daily = g.daily, balls = table.concat(list, ";"),
    challenge = type(g.challenge) == "table" and { from = g.challenge.from, score = g.challenge.score } or nil,
  }
end

function L.stackLoad(s)
  if type(s) ~= "table" or s.v ~= 1 or type(s.balls) ~= "string" then return nil end
  local g = L.stackNewSeeded(s.seed, { daily = tonumber(s.daily), challenge = s.challenge })
  local cur, nxt, score = tonumber(s.cur), tonumber(s.nxt), tonumber(s.score)
  -- your own save: only the hard cap (SCORE_SANE is for guildmates' scores, a good game may pass it)
  if not cur or not nxt or not S.RADII[cur] or not S.RADII[nxt] or not score or score < 0 or score > L.GAME_SCORE_MAX then
    return nil
  end
  g.cur, g.nxt, g.score = cur, nxt, floor(score)
  g.rngS = L.cleanSeed(s.rngS)
  g.biggest = math.max(0, math.min(#S.RADII, tonumber(s.biggest) or 0))
  g.drops, g.shaken = tonumber(s.drops) or 0, s.shaken and true or false
  for item in string.gmatch(s.balls, "[^;]+") do
    local size, x, y = string.match(item, "^(%d+),(%-?[%d%.]+),(%-?[%d%.]+)$")
    size, x, y = tonumber(size), tonumber(x), tonumber(y)
    if not size or not S.RADII[size] or not x or not y or x < S.JAR_L or x > S.JAR_R or y < 0 or y > S.JAR_BOTTOM then
      return nil
    end
    local b = newBall(size, x, y)
    b.age = S.OVER_GRACE
    table.insert(g.balls, b)
    if #g.balls > S.MAX_BALLS then return nil end
  end
  return g
end
