-- GFoA Guild Sync: Paw Stack, the drop-and-merge minigame (docs/minigames.md section 4), a mode of the minigames
-- window in Games.lua. Drop pastel paw-balls from the dropper (follows the mouse, click to drop); two equal balls that
-- touch merge into the next size. The jar is full when a ball rests above the line for 2 s.
-- Logic and physics live in StackLogic.lua; this file only draws and handles input.
local _, ns = ...
local L = ns.logic
local S = L.STACK
local shell = ns.gameShell

local GAME = "stack"
local stack = { id = GAME, title = "Paw Stack" }
local layer, ballTex, held, nextTex, nextLabel, lineTex = nil, {}, nil, nil, nil, nil
local game

-- One pastel per size, small to big.
local SIZE_COLORS = {
  { 0.976, 0.722, 0.831 }, { 1.0, 0.784, 0.569 }, { 1.0, 0.945, 0.651 }, { 0.741, 0.890, 0.639 },
  { 0.663, 0.898, 0.961 }, { 0.741, 0.710, 0.957 }, { 0.886, 0.651, 0.945 }, { 1.0, 0.600, 0.702 },
  { 0.988, 0.835, 0.459 }, { 0.565, 0.851, 0.776 }, { 1.0, 1.0, 1.0 },
}

local function tint(t, size, alpha)
  local c = SIZE_COLORS[size] or SIZE_COLORS[1]
  t:SetVertexColor(c[1], c[2], c[3], alpha or 1)
end

local function ballTexture(parent, layerName)
  local t = parent:CreateTexture(nil, layerName or "ARTWORK")
  t:SetTexture(ns.ui.TEX.pawball)
  return t
end

local function setBall(t, size, x, y, alpha)
  local d = S.RADII[size] * 2
  t:SetSize(d, d)
  tint(t, size, alpha)
  shell.place(t, x, y)
  t:Show()
end

local function render()
  for i = 1, math.max(#game.balls, #ballTex) do
    local b, t = game.balls[i], ballTex[i]
    if b and not t then
      t = ballTexture(layer)
      ballTex[i] = t
    end
    if b then
      setBall(t, b.size, b.x, b.y)
    elseif t then
      t:Hide()
    end
  end
  if game.state == "play" then
    setBall(held, game.cur, game.x, S.DROP_Y, L.stackCanDrop(game) and 0.95 or 0.4)
  else
    held:Hide()
  end
  setBall(nextTex, game.nxt, S.JAR_R + 25, 40, 0.9)
  nextTex:SetSize(math.min(30, S.RADII[game.nxt] * 2), math.min(30, S.RADII[game.nxt] * 2))
  -- the line goes pink while a ball sits above it
  if (game.overT or 0) > 0 then
    lineTex:SetVertexColor(1, 0.45, 0.6, 0.5 + 0.5 * math.min(1, game.overT / S.OVER_TIME))
  else
    lineTex:SetVertexColor(0.93, 0.9, 0.95, 0.25)
  end
end

local function finished()
  local rec = shell.record(GAME)
  if (game.biggest or 0) > (tonumber(rec.biggest) or 0) then rec.biggest = game.biggest end
  local W = ns.ui
  shell.finish(GAME, game, false, W.WAIT .. "The jar is full.|r ")
end

local function drainEvents()
  local W = ns.ui
  for _, e in ipairs(game.events) do
    if e.kind == "merge" then
      local big = (e.size or 0) >= 8
      if e.x then
        shell.floatText(e.x, e.y - 10, "+" .. e.value, big and shell.COLORS.gold or SIZE_COLORS[e.size] or shell.COLORS.pink)
      end
      shell.sound(big and "gold" or "hit")
      if (e.size or 0) > #S.RADII then
        shell.burst(e.x, e.y)
        shell.setStatus(W.PINK .. "Two of the biggest paws: they pop! +" .. e.value .. "|r")
      elseif big then
        shell.setStatus(W.GOOD .. "Size " .. e.size .. " paw!|r")
      end
    elseif e.kind == "shake" then
      shell.sound("power")
      shell.setStatus(W.MUTED .. "Shake! The jar gets a nudge.|r")
    elseif e.kind == "over" then
      finished()
    end
  end
  game.events = {}
  shell.refreshButtons()
end

local function begin(g, text)
  game = g
  shell.setStatus(ns.ui.MUTED .. text .. "|r")
  render()
end

function stack.start(daily)
  if daily then
    begin(L.stackNewDaily(ns.now()), "Today's drop order: same balls for everyone. Match two to merge.")
  else
    begin(L.stackNewSeeded(math.random(1, 2147483646)), "Drop paw-balls; two of a size merge. Keep under the line.")
  end
end

-- A guildmate's drop order: their seed, to beat their score.
function stack.startChallenge(seed, ch)
  begin(L.stackNewSeeded(seed, { challenge = ch }), ch.from .. "'s drop order: beat " .. ch.score .. ".")
end

function stack.resume(save)
  local g = L.stackLoad(save)
  if not g then return false end
  if g.daily and g.daily ~= L.gameDay(ns.now()) then return false end
  begin(g, "Back where you left off.")
  return true
end

function stack.hasGame() return game ~= nil end
function stack.busy() return false end   -- nothing is lost by closing: the jar just waits

-- For gameSave (logout / reload): the positions as they are. No physics here: settling could end the game
-- unseen ("jar full") and costs time on logout; the jar settles on resume.
function stack.save()
  if #game.events > 0 then drainEvents() end
  return L.stackSave(game)
end

function stack.hud()
  local W = ns.ui
  local rec = shell.record(GAME)
  local mode = game.daily and (W.PINK .. "Daily|r   ") or ""
  return string.format("%s%sScore|r %d   %sBiggest|r %d   %sBest %d|r", mode, W.MUTED, game.score, W.MUTED,
    game.biggest or 0, W.MUTED, rec.best or 0)
end

function stack.update(elapsed)
  if game.state == "play" and not shell.panelOpen() then
    local x = shell.cursor()
    if x then game.x = L.stackClampX(game, x) end
  end
  L.stackUpdate(game, elapsed)
  if #game.events > 0 then drainEvents() end
  render()
end

function stack.click(x)
  if L.stackDrop(game, x) then
    shell.played()
    shell.refreshButtons()
  end
end

function stack.action()
  if not game or game.state ~= "play" then return "Shake jar", false end
  if game.shaken then return "Shaken", false end
  return "Shake jar", true
end

function stack.actionTip()
  return "Shake the jar", "Once per game: a small upward nudge to every ball, to loosen a stuck pile."
end

function stack.actionClick()
  if game then L.stackShake(game) end
end

-- M extra field after the class: the biggest size ever made.
function stack.extras(rec)
  return { tostring(L.stackBiggest(rec.biggest) or 0) }
end

function stack.scoreNote(r)
  if r.mine then r.biggest = L.stackBiggest(shell.record(GAME).biggest) end
  if not r.biggest then return "" end
  return "  " .. ns.ui.MUTED .. "size " .. r.biggest .. "|r"
end

function stack.build(l)
  layer = l
  local W = ns.ui
  -- jar: two walls and a floor, and the line near the top
  local function bar(x1, y1, x2, y2)
    local t = l:CreateTexture(nil, "BORDER")
    t:SetTexture(W.TEX.white)
    t:SetVertexColor(0.93, 0.9, 0.95, 0.35)
    t:SetSize(math.max(2, x2 - x1), math.max(2, y2 - y1))
    shell.place(t, (x1 + x2) / 2, (y1 + y2) / 2)
    return t
  end
  bar(S.JAR_L - 3, S.LINE_Y - 20, S.JAR_L, S.JAR_BOTTOM + 3)
  bar(S.JAR_R, S.LINE_Y - 20, S.JAR_R + 3, S.JAR_BOTTOM + 3)
  bar(S.JAR_L - 3, S.JAR_BOTTOM, S.JAR_R + 3, S.JAR_BOTTOM + 3)
  lineTex = bar(S.JAR_L, S.LINE_Y - 1, S.JAR_R, S.LINE_Y + 1)
  held = ballTexture(l, "OVERLAY")
  nextTex = ballTexture(l, "OVERLAY")
  nextLabel = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  nextLabel:SetText(W.MUTED .. "Next|r")
  shell.place(nextLabel, S.JAR_R + 25, 18)
end

ns.registerGame(stack)
