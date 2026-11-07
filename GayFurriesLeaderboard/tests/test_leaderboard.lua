-- Stub-harness tests for Sephya's GayFurriesLeaderboard.lua: loads the real file against fake WoW globals and drives
-- it through its event handlers, comm messages and slash command. Not loaded by WoW (not in the .toc).
--   lune run addon/GayFurriesLeaderboard/tests/run_lune.luau addon/GayFurriesLeaderboard/tests/test_leaderboard.lua
-- (or a stock Lua 5.1:  lua addon/GayFurriesLeaderboard/tests/test_leaderboard.lua)
-- Tests named "KNOWN:" pin down current behaviour that is a listed, not-fixed problem (see the audit doc).
local here = (arg and arg[0] and string.match(arg[0], "^(.*)[/\\][^/\\]*$")) or "."
local ADDON = here .. "/../GayFurriesLeaderboard.lua"
local base = getfenv(1)

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
  end
end
local function ok(name, cond) eq(name, cond and true or false, true) end

-- Weekly reset used by the addon, Logic.lua and the bot: Tuesday 15:00 UTC.
local RESET_OFFSET = 5 * 86400 + 15 * 3600
local function weekOf(t) return math.floor((t - RESET_OFFSET) / 604800) end
local TUE_1459 = 1793717999 -- 2026-11-03 14:59:59 UTC, a Tuesday
local TUE_1500 = 1793718000 -- 2026-11-03 15:00:00 UTC
local WED_0700 = 1793775600 -- 2026-11-04 07:00:00 UTC (EU reset time)

---------------------------------------------------------------------------------------------------
-- Fake WoW
---------------------------------------------------------------------------------------------------
local function noop() end

local function newWorld(opts)
  opts = opts or {}
  local W = {
    clock = 1000, serverBase = (opts.server or (TUE_1500 + 86400)) - 1000, skew = 0,
    me = opts.me or "Sephya Moon", first = opts.first or "Sephya", class = opts.class or "HUNTER",
    hk = opts.hk or 100, money = opts.money or 123456, inGuild = true,
    roster = opts.roster or { "Sephya Moon-Forever", "Bob Smith-Forever", "Carl Stone-Forever", "Dan Ivy-Forever" },
    sent = {}, printed = {}, timers = {}, tickers = 0, frames = {}, rosterRequests = 0,
    npc = nil, tradeGive = 0, tradeGet = 0, guildSyncLoaded = opts.guildSyncLoaded or false,
  }
  if opts.noApi then W.hk = nil end

  local M = {}
  local function obj(kind, name, parent)
    local o = { kind = kind, name = name, parent = parent, shown = true, scripts = {}, events = {} }
    W.frames[#W.frames + 1] = o
    return setmetatable(o, { __index = function(_, k) return M[k] or noop end })
  end
  function M.GetFrameLevel() return 1 end
  function M.GetWidth() return 480 end
  function M.GetHeight() return 480 end
  function M.GetStringWidth() return 10 end
  function M.GetFont() return "Fonts\\FRIZQT__.TTF", 10 end
  function M.GetEffectiveScale() return 1 end
  function M.GetCenter() return 0, 0 end
  function M.IsShown(o) return o.shown end
  function M.SetScript(o, k, f) o.scripts[k] = f end
  function M.GetScript(o, k) return o.scripts[k] end
  function M.HookScript(o, k, f) o.scripts[k .. "#hook"] = f end
  function M.Show(o)
    local was = o.shown
    o.shown = true
    if not was and o.scripts.OnShow then o.scripts.OnShow(o) end
  end
  function M.Hide(o) o.shown = false end
  function M.RegisterEvent(o, e) o.events[e] = true end
  function M.SetText(o, t) o.text = t end
  function M.GetText(o) return o.text end
  function M.CreateTexture(o) return obj("Texture", nil, o) end
  function M.CreateFontString(o) return obj("FontString", nil, o) end
  function M.GetNormalTexture(o) return obj("Texture", nil, o) end

  local G = {}
  G.print = function(...)
    local out = {}
    for i = 1, select("#", ...) do out[i] = tostring((select(i, ...))) end
    W.printed[#W.printed + 1] = table.concat(out, " ")
  end
  G.CreateFrame = function(kind, name, parent) local o = obj(kind, name, parent); if name then G[name] = o end; return o end
  G.UIParent, G.Minimap, G.GameTooltip = obj("Frame"), obj("Frame"), obj("GameTooltip")
  G.UISpecialFrames = {}
  G.tinsert = table.insert
  G.GameFontNormal, G.GameFontNormalLarge = {}, {}
  G.RAID_CLASS_COLORS = { HUNTER = { r = 0.67, g = 0.83, b = 0.45 }, WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
  G.CLASS_ICON_TCOORDS = { HUNTER = { 0, 0.25, 0.25, 0.5 }, WARRIOR = { 0, 0.25, 0, 0.25 } }
  G.GetCursorPosition = function() return 0, 0 end
  G.SlashCmdList = {}
  G.GetTime = function() return W.clock end
  G.GetServerTime = function() return W.serverBase + W.clock end
  G.time = function() return W.serverBase + W.clock + W.skew end
  G.date = os and os.date or noop
  G.IsInGuild = function() return W.inGuild end
  G.UnitName = function(u)
    if u == "player" then return W.first, (W.me:match("^%S+ (.+)$")) end
    if u == "NPC" and W.npc then return (W.npc:match("^(%S+)")), (W.npc:match("^%S+ (.+)$")) end
  end
  G.GetUnitName = function(u) if u == "player" then return W.me elseif u == "NPC" then return W.npc end end
  G.UnitClass = function(u) if u == "player" then return "Hunter", W.class end end
  G.GetMoney = function() return W.money end
  if not opts.noApi then G.GetPVPLifetimeStats = function() return W.hk, 0, 0 end end
  G.IsInInstance = function() return W.instance ~= nil, W.instance or "none" end -- W.instance = "pvp" in a BG
  G.GetNumGuildMembers = function() return #W.roster end
  G.GetGuildRosterInfo = function(i) return W.roster[i] end
  G.Ambiguate = function(n, how) return (n:gsub("%-[^%-]*$", "")) end
  G.C_GuildInfo = { GuildRoster = function() W.rosterRequests = W.rosterRequests + 1 end }
  G.C_AddOns = { IsAddOnLoaded = function(n) return n == "GFoAGuildSync" and W.guildSyncLoaded end }
  G.C_ChatInfo = {
    SendAddonMessage = function(p, text, ch) W.sent[#W.sent + 1] = { prefix = p, text = text, channel = ch } end,
    RegisterAddonMessagePrefix = function(p) W.prefix = p end,
  }
  G.C_Timer = {
    After = function(d, f) W.timers[#W.timers + 1] = { at = W.clock + d, f = f } end,
    NewTicker = function(d, f) W.tickers = W.tickers + 1; W.timers[#W.timers + 1] = { at = W.clock + d, f = f, every = d } end,
  }
  G.GetPlayerTradeMoney = function() return W.tradeGive end
  G.GetTargetTradeMoney = function() return W.tradeGet end
  -- enUS global strings (classic era)
  G.DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
  G.DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel"
  G.RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)"
  G.COMBATLOG_HONORGAIN = "%s dies, honorable kill Rank: %s (Estimated Honor Points: %d)"
  G.COMBATLOG_DISHONORGAIN = "%s dies, dishonorable kill."
  G.ERR_TRADE_COMPLETE = "Trade complete."
  G.ERR_TRADE_CANCELLED = "Trade cancelled."
  G.GayFurriesLeaderboardDB = opts.db
  setmetatable(G, { __index = base })
  W.G = G

  local chunk = assert(loadfile(ADDON))
  setfenv(chunk, G)
  chunk("GayFurriesLeaderboard", {})
  for _, f in ipairs(W.frames) do
    if f.events.ADDON_LOADED then W.ev = f end
  end
  W.frame = G.GayFurriesLeaderboardFrame

  function W.fire(event, ...) return W.ev.scripts.OnEvent(W.ev, event, ...) end
  function W.advance(sec)
    local target = W.clock + sec
    while true do
      local best
      for i, t in ipairs(W.timers) do
        if t.at <= target and (not best or t.at < W.timers[best].at) then best = i end
      end
      if not best then break end
      local t = W.timers[best]
      W.clock = t.at
      if t.every then t.at = t.at + t.every else table.remove(W.timers, best) end
      t.f()
    end
    W.clock = target
  end
  function W.setServer(t) W.serverBase = t - W.clock end
  function W.server() return W.serverBase + W.clock end
  function W.login()
    W.fire("ADDON_LOADED", "GayFurriesLeaderboard")
    W.fire("PLAYER_ENTERING_WORLD", true, false)
    W.advance(9)
    W.sent = {}
  end
  function W.db() return G.GayFurriesLeaderboardDB end
  function W.mine() return W.db().members[W.me] end
  function W.char() return (W.db().chars or {})[W.me] end -- GFoA: per-character counters
  function W.stats() -- stats messages sent (not REQ / D: / R:)
    local out = {}
    for _, s in ipairs(W.sent) do
      if s.text ~= "REQ" and not s.text:find("^[DR]:") then out[#out + 1] = s.text end
    end
    return out
  end
  function W.sentWith(prefix)
    local out = {}
    for _, s in ipairs(W.sent) do if s.text:sub(1, #prefix) == prefix then out[#out + 1] = s.text end end
    return out
  end
  function W.sys(msg) W.fire("CHAT_MSG_SYSTEM", msg, "", "", "", "", "", 0) end
  function W.roll(name, result, max) W.sys(string.format("%s rolls %d (%d-%d)", name, result, 1, max)) end
  function W.addon(text, sender, channel) W.fire("CHAT_MSG_ADDON", "GPVPLB", text, channel or "GUILD", sender) end
  function W.slash(msg) W.G.SlashCmdList.GUILDPVPBOARD(msg) end
  return W
end

---------------------------------------------------------------------------------------------------
-- Load, migrations, errors before ADDON_LOADED, ticker stacking
---------------------------------------------------------------------------------------------------
do
  local W = newWorld()
  eq("prefix not registered before ADDON_LOADED", W.prefix, nil)
  ok("PLAYER_DEAD before ADDON_LOADED does not error", pcall(W.fire, "PLAYER_DEAD"))
  ok("CHAT_MSG_SYSTEM before ADDON_LOADED does not error", pcall(W.sys, "Sephya Moon has defeated Bob Smith in a duel"))
  ok("honor gain before ADDON_LOADED does not error", pcall(W.fire, "CHAT_MSG_COMBAT_HONOR_GAIN", "x dies, honorable kill Rank: y (Estimated Honor Points: 1)"))
  ok("slash before ADDON_LOADED errors (db nil; cannot happen in game)", not pcall(W.slash, "debug"))
  ok("KNOWN: stats message before ADDON_LOADED errors (db nil; game delivers ADDON_LOADED first)",
    not pcall(W.addon, "1:0:1:WARRIOR", "Bob Smith"))
  W.fire("ADDON_LOADED", "SomeOtherAddon")
  eq("other ADDON_LOADED ignored", W.db(), nil)
  W.fire("ADDON_LOADED", "GayFurriesLeaderboard")
  eq("prefix registered", W.prefix, "GPVPLB")
  eq("db created", type(W.db()), "table")
  eq("source defaults to api", W.db().source, "api")
  eq("theme defaults to gay", W.db().theme, "gay")
  eq("death before load not counted", W.db().chars, nil)
  -- PLAYER_ENTERING_WORLD three times inside the 5 s wait (login + loading screens), then again later
  W.fire("PLAYER_ENTERING_WORLD", true, false)
  W.advance(1); W.fire("PLAYER_ENTERING_WORLD", false, false)
  W.advance(1); W.fire("PLAYER_ENTERING_WORLD", false, true)
  W.advance(10)
  eq("tickers created once (no stacking)", W.tickers, 2)
  eq("one broadcast at ready", #W.stats(), 1)
  eq("one REQ at ready", #W.sentWith("REQ"), 1)
  W.fire("PLAYER_ENTERING_WORLD", false, false)
  W.advance(10)
  eq("later PLAYER_ENTERING_WORLD adds no tickers", W.tickers, 2)
  eq("roster asked when Guild Sync is not loaded", W.rosterRequests, 1)
  W.sent = {}
  W.advance(300)
  eq("300 s ticker broadcasts once", #W.stats(), 1)
  eq("300 s ticker asks roster", W.rosterRequests, 2)
end

do
  local W = newWorld({ guildSyncLoaded = true })
  W.login()
  W.advance(600)
  eq("roster never asked while Guild Sync runs", W.rosterRequests, 0)
end

do
  local W = newWorld({ db = { theme = "kyy", members = {} } })
  W.fire("ADDON_LOADED", "GayFurriesLeaderboard")
  eq("kyy theme migrates to gay", W.db().theme, "gay")
  W = newWorld({ db = { straight = true } })
  W.fire("ADDON_LOADED", "GayFurriesLeaderboard")
  eq("old straight toggle migrates", W.db().theme, "straight")
  W = newWorld({ db = { cat = true } })
  W.fire("ADDON_LOADED", "GayFurriesLeaderboard")
  eq("old cat toggle migrates", W.db().theme, "cat")
  W = newWorld({ db = { theme = "nonsense" } })
  W.fire("ADDON_LOADED", "GayFurriesLeaderboard")
  eq("unknown theme falls back", W.db().theme, "gay")
end

do -- first-name-only own entry is replaced by the full name
  local W = newWorld({ db = { members = { Sephya = { total = 5, week = 1 }, Bob = { total = 9, week = 1 } } } })
  W.login()
  eq("old first-name own entry removed", W.db().members.Sephya, nil)
  ok("full-name own entry written", W.mine() ~= nil)
  ok("KNOWN: other members' first-name entries stay forever", W.db().members.Bob ~= nil)
end

---------------------------------------------------------------------------------------------------
-- Weekly reset: Tuesday 15:00 UTC
---------------------------------------------------------------------------------------------------
do
  local W = newWorld({ server = TUE_1459 - 60 })
  W.login()
  local before = W.mine().week
  eq("week id before Tue 15:00 UTC", before, weekOf(W.server()))
  W.setServer(TUE_1500)
  W.fire("PLAYER_MONEY"); W.advance(11)
  eq("week id ticks at Tue 15:00:00 UTC", W.mine().week, before + 1)
  eq("week id formula boundary", weekOf(TUE_1500) - weekOf(TUE_1459), 1)
  eq("EU reset time (Wed 07:00 UTC) is not a boundary", weekOf(WED_0700) - weekOf(WED_0700 - 1), 0)
  eq("Tue 15:00 is exactly a week boundary", (TUE_1500 - RESET_OFFSET) % 604800, 0)
end

do -- week id uses GetServerTime; `updated` uses time() (local clock)
  local W = newWorld()
  W.skew = 3600
  W.login()
  eq("week from server clock", W.mine().week, weekOf(W.server()))
  local lag = W.mine().updated - W.server()
  ok("KNOWN: updated stamp follows the local clock (time()), here 1 h ahead", lag > 3590 and lag <= 3600)
end

---------------------------------------------------------------------------------------------------
-- PvP kills
---------------------------------------------------------------------------------------------------
do
  local W = newWorld({ hk = 100 })
  W.login()
  eq("total: world kills since the update, not the API lifetime count", W.mine().total, 0)
  eq("weekly starts at 0", W.mine().weekly, 0)
  W.hk = 105
  W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(11)
  eq("weekly counts new kills", W.mine().weekly, 5)
  local s = W.stats()
  eq("one throttled broadcast", #s, 1)
  eq("broadcast format", s[1], string.format("5:5:%d:HUNTER:0:0:123456", weekOf(W.server())))
  -- the API count drops (bad read / another character on the account) and comes back
  W.hk = 0
  W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(11)
  eq("a lower API read is ignored", W.mine().weekly, 5)
  W.hk = 106
  W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(11)
  eq("weekly not inflated after the count comes back", W.mine().weekly, 6)
  -- new week re-baselines
  W.setServer(W.server() + 7 * 86400)
  W.fire("PLAYER_MONEY"); W.advance(11)
  eq("new week: weekly back to 0", W.mine().weekly, 0)
  eq("new week: total kept", W.mine().total, 6)
end

do -- no API: honor-kill chat line fallback
  local W = newWorld({ noApi = true })
  W.login()
  eq("no API: total from log", W.mine().total, 0)
  W.fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Grunt Zog dies, honorable kill Rank: Scout (Estimated Honor Points: 12)")
  W.fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Grunt Zog dies, honorable kill Rank: Scout (Estimated Honor Points: 0)")
  W.advance(11)
  eq("honor kill lines counted", W.char().logKills, 2)
  eq("weekly from log", W.mine().weekly, 2)
  W.fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Peasant Tom dies, dishonorable kill.")
  W.advance(11)
  eq("dishonorable kill not counted", W.char().logKills, 2)
  W.fire("CHAT_MSG_COMBAT_HONOR_GAIN", "You have been awarded 198 honor points.")
  W.advance(11)
  eq("bonus honor line not counted", W.char().logKills, 2)
end

do -- source switch
  local W = newWorld({ hk = 400 })
  W.login()
  W.fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Grunt Zog dies, honorable kill Rank: Scout (Estimated Honor Points: 12)")
  W.hk = 401
  W.advance(11)
  eq("api mode ignores log count for total", W.mine().total, 1)
  eq("log counted in background", W.char().logKills, 1)
  W.slash("source log")
  eq("source log: total is log count", W.mine().total, 1)
  eq("source log: weekly re-baselined", W.mine().weekly, 0)
  W.slash("source api")
  eq("source api: back to API world kills", W.mine().total, 1)
  eq("source api: weekly re-baselined", W.mine().weekly, 0)
end

---------------------------------------------------------------------------------------------------
-- Deaths
---------------------------------------------------------------------------------------------------
do
  local W = newWorld()
  W.login()
  W.fire("PLAYER_DEAD"); W.fire("PLAYER_DEAD"); W.fire("PLAYER_DEAD")
  W.advance(11)
  eq("deaths total", W.mine().dTotal, 3)
  eq("deaths weekly", W.mine().dWeekly, 3)
  eq("three deaths, one broadcast", #W.stats(), 1)
  W.setServer(W.server() + 7 * 86400)
  W.fire("PLAYER_MONEY"); W.advance(11)
  eq("deaths weekly resets", W.mine().dWeekly, 0)
  eq("deaths total kept", W.mine().dTotal, 3)
end

do -- the week only rolls over on the next snapshot: a death right after the reset lands in the old week
  local W = newWorld({ server = TUE_1500 - 120 })
  W.login()
  W.advance(200) -- now past Tue 15:00, no snapshot since
  W.fire("PLAYER_DEAD"); W.advance(11)
  eq("KNOWN: first death after the reset (before any snapshot) not in the new week", W.mine().dWeekly, 0)
  eq("KNOWN: ... but it is in the total", W.mine().dTotal, 1)
end

---------------------------------------------------------------------------------------------------
-- GFoA: per-character counters. SavedVariables are account-wide; deaths / kill + death week bases / log kills now
-- live in db.chars["First Surname"], so a main and its alts each keep their own numbers.
---------------------------------------------------------------------------------------------------
local NOW = TUE_1500 + 86400 -- newWorld's default server time
local WK = weekOf(NOW)
local ALT = { me = "Alty Moon", first = "Alty" }
local function as(opts, extra) -- newWorld options for one character on a shared account
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end
local ROW_KEYS = "class,dTotal,dWeekly,gold,total,updated,week,weekly"
local function rowKeys(m)
  local ks = {}
  for k in pairs(m) do ks[#ks + 1] = k end
  table.sort(ks)
  return table.concat(ks, ",")
end
local function oldDb() -- a pre-update file: counters at the top level, written by the main
  return {
    source = "api", theme = "cat", shareGold = true,
    deaths = 7, logKills = 3, weekId = WK, weekBase = 90, dWeekBase = 5,
    members = { ["Sephya Moon"] = { total = 100, weekly = 10, dTotal = 7, dWeekly = 2, gold = 1, week = WK,
      class = "HUNTER", updated = 1 }, ["Bob Smith"] = { total = 50, weekly = 7, dTotal = 12, dWeekly = 3, gold = 9,
      week = WK, class = "WARRIOR", updated = 1 } },
  }
end

do -- main and alt on one account: deaths and weekly kills stay separate, switching back and forth
  local shared = {}
  local A = newWorld({ db = shared, hk = 500 })
  A.login()
  A.hk = 505; A.fire("PLAYER_PVP_KILLS_CHANGED"); A.advance(11)
  eq("main weekly 5", A.mine().weekly, 5)
  local B = newWorld(as(ALT, { db = shared, hk = 10 }))
  B.login()
  eq("alt starts at 0 weekly kills", B.mine().weekly, 0)
  eq("alt total is its own world kills", B.mine().total, 0)
  B.fire("PLAYER_DEAD"); B.fire("PLAYER_DEAD")
  B.hk = 13; B.fire("PLAYER_PVP_KILLS_CHANGED"); B.advance(11)
  eq("alt deaths on the alt", B.mine().dTotal, 2)
  eq("alt weekly deaths", B.mine().dWeekly, 2)
  eq("alt weekly kills", B.mine().weekly, 3)
  local A2 = newWorld({ db = shared, hk = 505 })
  A2.login()
  eq("main weekly kills unchanged by the alt", A2.mine().weekly, 5)
  eq("alt deaths not on the main's total", A2.mine().dTotal, 0)
  A2.fire("PLAYER_DEAD"); A2.hk = 507; A2.fire("PLAYER_PVP_KILLS_CHANGED"); A2.advance(11)
  eq("main death counted on the main", A2.mine().dTotal, 1)
  eq("main weekly kills go on", A2.mine().weekly, 7)
  local B2 = newWorld(as(ALT, { db = shared, hk = 13 }))
  B2.login()
  eq("back on the alt: deaths", B2.mine().dTotal, 2)
  eq("back on the alt: weekly kills", B2.mine().weekly, 3)
  eq("main row still on the board", shared.members["Sephya Moon"].dTotal, 1)
  eq("alt row on the board", shared.members["Alty Moon"].dTotal, 2)
  local C = newWorld({ db = shared, me = "Bigalt Moon", first = "Bigalt", hk = 900 })
  C.login()
  eq("alt with more kills than the main: weekly 0 (was 900 - main's base)", C.mine().weekly, 0)
  eq("three characters in db.chars", (function() local n = 0; for _ in pairs(shared.chars) do n = n + 1 end; return n end)(), 3)
end

do -- migration: the first character after the update takes the old account-wide counters
  local shared = oldDb()
  local A = newWorld({ db = shared, hk = 100 })
  A.login()
  eq("migrated: deaths", A.char().deaths, 7)
  eq("migrated: log kills", A.char().logKills, 3)
  eq("migrated: kill week base re-based for world kills", A.char().weekBase, 0)
  eq("migrated: death week base", A.char().dWeekBase, 5)
  eq("migrated: week id", A.char().weekId, WK)
  eq("migrated: weekly kills restart at 0 (world kills only)", A.mine().weekly, 0)
  eq("migrated: death total", A.mine().dTotal, 7)
  eq("migrated: weekly deaths", A.mine().dWeekly, 2)
  eq("migratedChars flag set", shared.migratedChars, true)
  eq("old top-level deaths kept in place", shared.deaths, 7)
  eq("old top-level week base kept in place", shared.weekBase, 90)
  eq("theme untouched", shared.theme, "cat")
  ok("other members untouched", shared.members["Bob Smith"] and shared.members["Bob Smith"].dTotal == 12)
  local B = newWorld(as(ALT, { db = shared, hk = 40 }))
  B.login()
  eq("second character starts fresh: deaths", B.mine().dTotal, 0)
  eq("second character starts fresh: weekly kills", B.mine().weekly, 0)
  eq("second character: own API baseline", B.char().apiSeen, 40)
  eq("second character: no log kills inherited", B.char().logKills, nil)
  B.fire("PLAYER_DEAD"); B.advance(11)
  eq("old top-level deaths no longer counted into", shared.deaths, 7)
  eq("main keeps its migrated deaths", shared.chars["Sephya Moon"].deaths, 7)
end

do -- migration rule: whoever logs in first owns the old totals, even an alt
  local shared = oldDb()
  local B = newWorld(as(ALT, { db = shared, hk = 40 }))
  B.login()
  eq("alt first: takes the old deaths", B.mine().dTotal, 7)
  local A = newWorld({ db = shared, hk = 100 })
  A.login()
  eq("main after: starts at 0 deaths", A.mine().dTotal, 0)
  eq("main after: weekly kills from its own base", A.mine().weekly, 0)
end

do -- fresh install, and a character first saved under its first name only
  local W = newWorld()
  W.login()
  eq("fresh: flag set", W.db().migratedChars, true)
  eq("fresh: no top-level deaths written", W.db().deaths, nil)
  ok("fresh: own counters made", W.char() ~= nil)
  W = newWorld({ db = { migratedChars = true, members = {}, chars = { Sephya = { deaths = 4, weekId = WK, dWeekBase = 1 } } } })
  W.login()
  eq("first-name counters moved to the full name", W.char().deaths, 4)
  eq("first-name counters entry removed", W.db().chars.Sephya, nil)
  eq("moved counters used", W.mine().dWeekly, 3)
end

do -- week rollover per character
  local shared = {}
  local A = newWorld({ db = shared, hk = 100 })
  A.login(); A.fire("PLAYER_DEAD"); A.advance(11)
  local B = newWorld(as(ALT, { db = shared, hk = 10 }))
  B.login(); B.fire("PLAYER_DEAD"); B.advance(11)
  local A3 = newWorld({ db = shared, hk = 104, server = NOW + 7 * 86400 })
  A3.login()
  eq("main in the new week", A3.char().weekId, WK + 1)
  eq("main weekly kills re-based", A3.mine().weekly, 0)
  eq("main weekly deaths re-based", A3.mine().dWeekly, 0)
  eq("main death total kept", A3.mine().dTotal, 1)
  eq("alt still on the old week until it logs in", shared.chars["Alty Moon"].weekId, WK)
  local B3 = newWorld(as(ALT, { db = shared, hk = 12, server = NOW + 7 * 86400 }))
  B3.login()
  eq("alt rolls over on its own login", B3.char().weekId, WK + 1)
  eq("alt weekly deaths re-based", B3.mine().dWeekly, 0)
  eq("alt death total kept", B3.mine().dTotal, 1)
  B3.hk = 15; B3.fire("PLAYER_PVP_KILLS_CHANGED"); B3.advance(11)
  eq("alt weekly kills from its own new base", B3.mine().weekly, 3)
end

do -- /gpvp reset only re-bases the character that typed it
  local shared = {}
  local A = newWorld({ db = shared })
  A.login(); A.fire("PLAYER_DEAD"); A.fire("PLAYER_DEAD"); A.advance(11)
  local B = newWorld(as(ALT, { db = shared }))
  B.login(); B.fire("PLAYER_DEAD"); B.advance(11)
  eq("alt weekly deaths before reset", B.mine().dWeekly, 1)
  B.slash("reset")
  eq("reset: alt weekly deaths 0", B.mine().dWeekly, 0)
  eq("reset: alt death total kept", B.mine().dTotal, 1)
  eq("reset: shared board cleared as before", shared.members["Sephya Moon"], nil)
  eq("reset: main's death base untouched", shared.chars["Sephya Moon"].dWeekBase, 0)
  local A2 = newWorld({ db = shared })
  A2.login()
  eq("main's weekly deaths survive the alt's reset", A2.mine().dWeekly, 2)
end

do -- /gpvp source is account-wide: another character re-bases its kills on its next login
  local shared = {}
  local B = newWorld(as(ALT, { db = shared, hk = 50 }))
  B.login()
  local A = newWorld({ db = shared, hk = 100 })
  A.login()
  A.slash("source log")
  eq("source switched for the account", shared.source, "log")
  local B2 = newWorld(as(ALT, { db = shared, hk = 50 }))
  B2.login()
  eq("alt total from its log count", B2.mine().total, 0)
  B2.fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Grunt Zog dies, honorable kill Rank: Scout (Estimated Honor Points: 12)")
  B2.advance(11)
  eq("alt weekly kills count from a log base (not the API base of 50)", B2.mine().weekly, 1)
end

do -- the shared board keeps its shape for Guild Sync, the uploader and the bot
  local shared = oldDb()
  local A = newWorld({ db = shared, hk = 100 })
  A.login()
  local B = newWorld(as(ALT, { db = shared, hk = 40 }))
  B.login()
  B.addon(string.format("50:7:%d:WARRIOR:12:3:990000", WK), "Bob Smith")
  eq("main row keys unchanged", rowKeys(shared.members["Sephya Moon"]), ROW_KEYS)
  eq("alt row keys unchanged", rowKeys(shared.members["Alty Moon"]), ROW_KEYS)
  eq("guildmate row keys unchanged", rowKeys(shared.members["Bob Smith"]), ROW_KEYS)
  eq("no stray rows (members = main, alt, Bob)", (function() local n = 0; for _ in pairs(shared.members) do n = n + 1 end; return n end)(), 3)
  B.fire("PLAYER_DEAD"); B.advance(11)
  eq("alt broadcast carries the alt's own counts", B.stats()[1], string.format("0:0:%d:HUNTER:1:1:123456", WK))
end

---------------------------------------------------------------------------------------------------
-- Gold
---------------------------------------------------------------------------------------------------
do
  local W = newWorld({ money = 5000000 })
  W.login()
  eq("gold shared by default", W.mine().gold, 5000000)
  for _ = 1, 6 do W.money = W.money + 1; W.fire("PLAYER_MONEY") end
  W.advance(2)
  eq("money spam: nothing sent before 3 s", #W.stats(), 0)
  W.advance(10)
  eq("money spam: one broadcast", #W.stats(), 1)
  W.sent = {}
  W.slash("gold off")
  local s = W.stats()
  eq("gold off broadcasts at once", #s, 1)
  ok("gold off sends -1", s[1]:find(":%-1$") ~= nil)
  eq("hidden gold not kept in own saved entry (uploader would leak it)", W.mine().gold, -1)
  W.slash("gold on")
  eq("gold on shares again", W.mine().gold, 5000006)
  W.sent = {}
  W.money = 1; W.fire("PLAYER_MONEY")
  W.advance(1); W.money = 2; W.fire("PLAYER_MONEY")
  W.advance(20)
  eq("second money change inside the wait does not schedule twice", #W.stats(), 1)
end

---------------------------------------------------------------------------------------------------
-- Comm
---------------------------------------------------------------------------------------------------
do
  local W = newWorld()
  W.login()
  local wk = weekOf(W.server())
  W.addon(string.format("50:7:%d:WARRIOR:12:3:990000", wk), "Bob Smith-Forever")
  local b = W.db().members["Bob Smith"]
  ok("sender with surname + realm stored under 'First Surname'", b ~= nil)
  eq("kills", b.total, 50); eq("weekly", b.weekly, 7); eq("week", b.week, wk); eq("class", b.class, "WARRIOR")
  eq("deaths", b.dTotal, 12); eq("dWeekly", b.dWeekly, 3); eq("gold", b.gold, 990000)
  W.addon(string.format("9:1:%d:MAGE", wk), "Carl Stone")
  local c = W.db().members["Carl Stone"]
  eq("old client: deaths default 0", c.dTotal, 0)
  eq("old client: gold default hidden", c.gold, -1)
  W.addon(string.format("9:1:%d:MAGE:1:1:-1", wk), "Dan Ivy")
  eq("hidden gold -1 stored", W.db().members["Dan Ivy"].gold, -1)
  W.addon("1:1:1:MAGE", "Sephya Moon")
  eq("own echo ignored", W.mine().total, 0)
  W.addon("garbage", "Bob Smith")
  W.addon(string.format("1:1:%d:MAGE", wk), "Evil Eve", "WHISPER")
  eq("non-GUILD channel ignored", W.db().members["Evil Eve"], nil)
  W.fire("CHAT_MSG_ADDON", "OTHER", string.format("1:1:%d:MAGE", wk), "GUILD", "Evil Eve")
  eq("other prefix ignored", W.db().members["Evil Eve"], nil)
  W.addon(string.format("-5:1:%d:MAGE", wk), "Neg Ned")
  eq("negative numbers rejected", W.db().members["Neg Ned"], nil)
  -- REQ replies: staggered 1-9 s, each REQ answered separately
  W.sent = {}
  W.addon("REQ", "Bob Smith")
  W.advance(0.99)
  eq("REQ reply not before 1 s", #W.stats(), 0)
  W.advance(8.02)
  eq("REQ answered within 9 s", #W.stats(), 1)
  W.sent = {}
  W.addon("REQ", "Bob Smith"); W.addon("REQ", "Carl Stone"); W.addon("REQ", "Dan Ivy")
  W.advance(10)
  eq("KNOWN: three REQs, three replies (not coalesced)", #W.stats(), 3)
  -- opening the window asks the guild
  W.sent = {}
  W.frame:Show()
  eq("opening the window sends REQ", #W.sentWith("REQ"), 1)
  W.frame:Hide(); W.frame:Show(); W.frame:Hide(); W.frame:Show()
  eq("KNOWN: every open sends another REQ (no throttle)", #W.sentWith("REQ"), 3)
end

---------------------------------------------------------------------------------------------------
-- Duels
---------------------------------------------------------------------------------------------------
do
  local W = newWorld()
  W.login()
  local wk = weekOf(W.server())
  W.addon(string.format("1:0:%d:WARRIOR:0:0:1", wk), "Bob Smith")
  W.sys("Sephya Moon has defeated Bob Smith in a duel")
  local d = W.db().duels and W.db().duels[1]
  ok("win recorded", d ~= nil)
  eq("winner", d and d.w, "Sephya Moon"); eq("loser", d and d.l, "Bob Smith")
  eq("winner class", d and d.wc, "HUNTER"); eq("loser class from board", d and d.lc, "WARRIOR")
  local D = W.sentWith("D:")
  eq("winner announces", D[1], string.format("D:Sephya Moon:HUNTER:Bob Smith:WARRIOR:%d", W.server()))
  -- the loser's own copy of the same duel comes back over comm: no duplicate
  W.addon(string.format("D:Sephya Moon:HUNTER:Bob Smith:WARRIOR:%d", W.server() + 2), "Bob Smith")
  eq("duel dedupe within 15 s", #W.db().duels, 1)
  W.advance(30)
  -- a retreat, worded loser-first
  W.sent = {}
  W.sys("Bob Smith has fled from Sephya Moon in a duel")
  eq("retreat: I win", W.db().duels[1].w, "Sephya Moon")
  eq("retreat: Bob loses", W.db().duels[1].l, "Bob Smith")
  W.advance(30)
  W.sent = {}
  W.sys("Carl Stone has defeated Sephya Moon in a duel")
  eq("loss recorded", W.db().duels[1].w, "Carl Stone")
  eq("loser does not announce", #W.sentWith("D:"), 0)
  W.advance(30)
  -- chat lines with first names only
  W.sys("Sephya has defeated Dan in a duel")
  eq("first names resolve to full names", W.db().duels[1].l, "Dan Ivy")
  W.advance(30)
  local n = #W.db().duels
  W.sys("Sephya Moon has defeated Random Stranger in a duel")
  eq("non-guild opponent ignored", #W.db().duels, n)
  W.sys("Bob Smith has defeated Carl Stone in a duel")
  eq("other people's duels ignored locally", #W.db().duels, n)
end

do -- two guildmates share a first name
  local W = newWorld({ roster = { "Sephya Moon", "Bob Smith", "Bob Jones" } })
  W.login()
  W.sys("Sephya has defeated Bob in a duel")
  eq("ambiguous first name not recorded", W.db().duels and #W.db().duels or 0, 0)
  W.sys("Sephya Moon has defeated Bob Jones in a duel")
  eq("full names still work", W.db().duels[1].l, "Bob Jones")
end

do -- duel cap
  local W = newWorld()
  W.login()
  for i = 1, 320 do W.addon(string.format("D:Bob Smith:WARRIOR:Carl Stone:MAGE:%d", 1000000 + i * 20), "Bob Smith") end
  eq("duels capped at 300", #W.db().duels, 300)
  eq("newest kept", W.db().duels[1].t, 1000000 + 320 * 20)
end

---------------------------------------------------------------------------------------------------
-- Deathrolls
---------------------------------------------------------------------------------------------------
local function rolls(W) return W.db().rolls or {} end

do -- the second roller loses
  local W = newWorld()
  W.login()
  W.roll("Sephya Moon", 500, 1000); W.roll("Bob Smith", 200, 500)
  W.roll("Sephya Moon", 50, 200); W.roll("Bob Smith", 1, 50)
  eq("deathroll recorded", #rolls(W), 1)
  eq("winner", rolls(W)[1].w, "Sephya Moon"); eq("loser", rolls(W)[1].l, "Bob Smith")
  eq("bet unknown is nil", rolls(W)[1].bet, nil)
  eq("R sent with -1", W.sentWith("R:")[1], string.format("R:Sephya Moon:HUNTER:Bob Smith::%d:-1", W.server()))
end

do -- the opener loses (third roll is the 1)
  local W = newWorld()
  W.login()
  W.roll("Sephya Moon", 500, 1000); W.roll("Bob Smith", 200, 500); W.roll("Sephya Moon", 1, 200)
  eq("opener's loss recorded", #rolls(W), 1)
  eq("opener loses: winner", rolls(W)[1] and rolls(W)[1].w, "Bob Smith")
  eq("opener loses: loser", rolls(W)[1] and rolls(W)[1].l, "Sephya Moon")
end

do -- the opener loses later in a long chain, guildmates on both sides, me only watching
  local W = newWorld()
  W.login()
  W.roll("Bob Smith", 800, 1000); W.roll("Carl Stone", 400, 800); W.roll("Bob Smith", 300, 400)
  W.roll("Carl Stone", 20, 300); W.roll("Bob Smith", 1, 20)
  eq("bystander records it", #rolls(W), 1)
  eq("long chain: winner", rolls(W)[1] and rolls(W)[1].w, "Carl Stone")
end

do -- butting in, lone 1, non-guild, re-roll
  local W = newWorld()
  W.login()
  W.roll("Sephya Moon", 500, 1000); W.roll("Bob Smith", 200, 500); W.roll("Carl Stone", 1, 200)
  eq("third player's 1 ignored", #rolls(W), 0)
  W.roll("Dan Ivy", 1, 100)
  eq("lone opening 1 ignored", #rolls(W), 0)
  W.roll("Sephya Moon", 50, 100); W.roll("Random Stranger", 1, 50)
  eq("non-guild loser ignored", #rolls(W), 0)
  W.roll("Sephya Moon", 1, 100)
  eq("roll 1-100 without a chain ignored", #rolls(W), 0)
  W.roll("Sephya Moon", 70, 100); W.roll("Sephya Moon", 60, 100); W.roll("Bob Smith", 1, 60)
  eq("re-rolled opener counts", #rolls(W), 1)
  W.advance(181)
  W.roll("Carl Stone", 30, 1000); W.advance(200); W.roll("Dan Ivy", 1, 30)
  eq("chain quiet over 180 s dropped", #rolls(W), 1)
end

do -- rolls before the roster is known are dropped
  local W = newWorld({ roster = {} })
  W.login()
  W.roll("Sephya Moon", 500, 1000); W.roll("Bob Smith", 1, 500)
  eq("no roster: not recorded", #rolls(W), 0)
end

do -- bets from the trade window
  local W = newWorld()
  W.login()
  W.roll("Sephya Moon", 500, 1000); W.roll("Bob Smith", 1, 500)
  W.advance(20)
  W.sent = {}
  W.npc = "Bob Smith"; W.tradeGet = 50000
  W.fire("TRADE_SHOW")
  W.fire("TRADE_ACCEPT_UPDATE", 1, 0)
  W.fire("TRADE_ACCEPT_UPDATE", 1, 1)
  W.sys("Trade complete.")
  W.fire("TRADE_CLOSED"); W.fire("TRADE_CLOSED"); W.advance(2)
  eq("bet from gold received", rolls(W)[1].bet, 50000)
  eq("one R update sent", #W.sentWith("R:"), 1)
  ok("R update carries bet", W.sentWith("R:")[1]:find(":50000$") ~= nil)
  eq("chat line printed (existing behaviour)", #W.printed, 1)
  -- I lose to Carl, pay him
  W.advance(10)
  W.roll("Carl Stone", 500, 1000); W.roll("Sephya Moon", 1, 500)
  W.npc = "Carl Stone"; W.tradeGet = 0; W.tradeGive = 30000
  W.fire("TRADE_SHOW"); W.fire("TRADE_ACCEPT_UPDATE", true, true)
  W.fire("TRADE_CLOSED"); W.advance(2) -- no "Trade complete." line: TRADE_CLOSED fallback
  eq("bet from gold paid (fallback path)", rolls(W)[1].bet, 30000)
  eq("loser stored right", rolls(W)[1].l, "Sephya Moon")
  -- trade with no matching roll, cancelled trade
  W.npc = "Dan Ivy"; W.tradeGive = 100
  W.fire("TRADE_SHOW"); W.fire("TRADE_ACCEPT_UPDATE", 1, 1); W.sys("Trade complete.")
  eq("trade with no roll changes nothing", #rolls(W), 2)
  W.roll("Sephya Moon", 500, 1000); W.roll("Dan Ivy", 1, 500)
  W.fire("TRADE_SHOW"); W.tradeGet = 900; W.tradeGive = 0
  W.fire("TRADE_ACCEPT_UPDATE", 1, 1); W.fire("TRADE_ACCEPT_UPDATE", 0, 0); W.fire("TRADE_CLOSED"); W.advance(2)
  eq("cancelled trade sets no bet", rolls(W)[1].bet, nil)
  -- partner is someone outside the guild
  W.npc = "Random Stranger"
  W.fire("TRADE_SHOW"); W.fire("TRADE_ACCEPT_UPDATE", 1, 1); W.sys("Trade complete.")
  eq("non-guild partner ignored", rolls(W)[1].bet, nil)
end

do -- 30-minute window, and an older record received later sitting on top
  local W = newWorld()
  W.login()
  W.roll("Sephya Moon", 500, 1000); W.roll("Bob Smith", 1, 500)
  W.advance(1801)
  W.npc = "Bob Smith"; W.tradeGet = 777
  W.fire("TRADE_SHOW"); W.fire("TRADE_ACCEPT_UPDATE", 1, 1); W.sys("Trade complete.")
  eq("trade after 30 min sets no bet", rolls(W)[1].bet, nil)

  W.roll("Sephya Moon", 500, 1000); W.roll("Bob Smith", 1, 500)
  W.advance(60)
  -- a guildmate's bet update for a deathroll 40 minutes old we never saw: inserted at the top
  W.addon(string.format("R:Carl Stone:MAGE:Dan Ivy::%d:5000", W.server() - 2400), "Carl Stone")
  eq("old received roll sits first", rolls(W)[1].w, "Carl Stone")
  W.fire("TRADE_SHOW"); W.tradeGet = 4242; W.fire("TRADE_ACCEPT_UPDATE", 1, 1); W.sys("Trade complete.")
  eq("bet still found behind an older record", rolls(W)[2].bet, 4242)
end

do -- R messages: -1, update, dedupe, cap
  local W = newWorld()
  W.login()
  local t = 2000000000
  W.addon(string.format("R:Carl Stone:MAGE:Dan Ivy:ROGUE:%d:-1", t), "Carl Stone")
  eq("R -1 stored as nil", rolls(W)[1].bet, nil)
  W.addon(string.format("R:Carl Stone:MAGE:Dan Ivy:ROGUE:%d:-1", t + 2), "Dan Ivy")
  eq("R dedupe within 5 s", #rolls(W), 1)
  W.addon(string.format("R:Carl Stone:MAGE:Dan Ivy:ROGUE:%d:2500", t + 1), "Carl Stone")
  eq("R bet update fills the bet", rolls(W)[1].bet, 2500)
  W.addon(string.format("R:Carl Stone:MAGE:Dan Ivy:ROGUE:%d:9999", t), "Evil Eve")
  eq("known bet not overwritten", rolls(W)[1].bet, 2500)
  W.addon(string.format("R:Carl Stone:MAGE:Dan Ivy:ROGUE:%d:-1", t + 6), "Carl Stone")
  eq("6 s apart is a new deathroll", #rolls(W), 2)
  for i = 1, 520 do W.addon(string.format("R:Bob Smith:WARRIOR:Dan Ivy::%d:-1", t + 100 + i * 10), "Bob Smith") end
  eq("rolls capped at 500", #rolls(W), 500)
end

---------------------------------------------------------------------------------------------------
-- /gpvp reset, UI smoke test
---------------------------------------------------------------------------------------------------
do
  local W = newWorld({ hk = 10 })
  W.login()
  W.addon(string.format("1:0:%d:WARRIOR", weekOf(W.server())), "Bob Smith")
  W.hk = 15; W.fire("PLAYER_DEAD"); W.advance(11)
  W.roll("Sephya Moon", 500, 1000); W.roll("Bob Smith", 1, 500)
  W.sent = {}
  W.slash("reset")
  eq("reset drops other members", W.db().members["Bob Smith"], nil)
  eq("reset re-adds me", W.mine().total, 5)
  eq("reset zeroes my weekly kills", W.mine().weekly, 0)
  eq("reset zeroes my weekly deaths", W.mine().dWeekly, 0)
  eq("reset keeps my death total", W.mine().dTotal, 1)
  eq("reset keeps deathrolls", #rolls(W), 1)
  eq("KNOWN: reset does not ask the guild (no REQ)", #W.sentWith("REQ"), 0)
end

do
  local W = newWorld()
  W.login()
  local wk = weekOf(W.server())
  W.addon(string.format("50:7:%d:WARRIOR:12:3:990000", wk), "Bob Smith")
  W.addon(string.format("9:1:%d:MAGE:1:1:-1", wk - 1), "Carl Stone")
  W.sys("Sephya Moon has defeated Bob Smith in a duel")
  W.roll("Sephya Moon", 500, 1000); W.roll("Bob Smith", 1, 500)
  local fine = pcall(function() W.frame:Show() end)
  ok("window opens with data", fine)
  local clicked = 0
  for _, f in ipairs(W.frames) do
    local fs = rawget(f, "fs")
    if type(fs) == "table" and rawget(fs, "text") and f.scripts.OnClick and f.parent == W.frame then
      local okc, err = pcall(f.scripts.OnClick, f)
      if not okc then print("click error: " .. tostring(err)) end
      clicked = clicked + (okc and 1 or 0)
    end
  end
  ok("tabs / theme / hide buttons click without errors", clicked >= 7)
  ok("resize handler runs", pcall(W.frame.scripts.OnSizeChanged, W.frame, 700, 600))
end

---------------------------------------------------------------------------------------------------
-- Cross-check: GFoA Guild Sync's L.leaderboardRows reads the addon's saved data the same way
---------------------------------------------------------------------------------------------------
do
  local chunk = loadfile(here .. "/../../GFoAGuildSync/Logic.lua")
  if not chunk then
    print("SKIP cross-check: GFoAGuildSync/Logic.lua not found")
  else
    local ns = {}
    chunk("GFoAGuildSync", ns)
    local L = ns.logic
    local W = newWorld({ hk = 100, money = 4000000 })
    W.login()
    local now = W.server()
    local wk = weekOf(now)
    eq("Logic week id = addon week id", L.lbWeekId(now), wk)
    eq("Logic week id boundary", L.lbWeekId(TUE_1500) - L.lbWeekId(TUE_1459), 1)
    W.hk = 104; W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(11)
    W.addon(string.format("50:7:%d:WARRIOR:12:3:990000", wk), "Bob Smith")
    W.addon(string.format("90:9:%d:MAGE:1:1:-1", wk - 1), "Carl Stone") -- last seen last week, gold hidden
    local function find(rows, name) for _, r in ipairs(rows) do if r.name == name then return r end end end
    local pw = L.leaderboardRows(W.db(), "pvpWeek", now)
    eq("pvpWeek: my weekly", find(pw, "Sephya Moon").value, 4)
    eq("pvpWeek: Bob weekly", find(pw, "Bob Smith").value, 7)
    eq("pvpWeek: stale week counts 0", find(pw, "Carl Stone").value, 0)
    eq("pvpTotal: stale week keeps total", find(L.leaderboardRows(W.db(), "pvpTotal", now), "Carl Stone").value, 90)
    eq("deathsWeek field", find(L.leaderboardRows(W.db(), "deathsWeek", now), "Bob Smith").value, 3)
    local g = L.leaderboardRows(W.db(), "gold", now)
    eq("gold: hidden left out", find(g, "Carl Stone"), nil)
    eq("gold: shared value", find(g, "Bob Smith").value, 990000)
    W.slash("gold off")
    eq("gold: my hidden gold left out of Guild Sync's board too", find(L.leaderboardRows(W.db(), "gold", now), "Sephya Moon"), nil)
    W.roll("Sephya Moon", 500, 1000); W.roll("Bob Smith", 1, 500)
    W.npc = "Bob Smith"; W.tradeGet = 25000
    W.fire("TRADE_SHOW"); W.fire("TRADE_ACCEPT_UPDATE", 1, 1); W.sys("Trade complete.")
    W.addon(string.format("R:Carl Stone:MAGE:Dan Ivy::%d:-1", now - 100), "Carl Stone")
    local r = L.leaderboardRows(W.db(), "rolls", now)
    eq("rolls: net from bet", find(r, "Sephya Moon").net, 25000)
    eq("rolls: loser net", find(r, "Bob Smith").net, -25000)
    eq("rolls: unknown bet (nil) counts 0", find(r, "Carl Stone").net, 0)
    W.sys("Sephya Moon has defeated Bob Smith in a duel")
    local d = L.leaderboardRows(W.db(), "duels", now)
    eq("duels: wins", find(d, "Sephya Moon").wins, 1)
    eq("duels: losses", find(d, "Bob Smith").losses, 1)
  end
end

do -- GFoA: battleground kills never count, world PvP kills do
  local W = newWorld({ hk = 100 })
  W.login()
  W.hk = 102; W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(11)
  eq("world kills counted", W.mine().total, 2)
  -- zone into Warsong Gulch, get 10 kills
  W.instance = "pvp"; W.fire("PLAYER_ENTERING_WORLD", false, false)
  W.hk = 112; W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(11)
  eq("BG kills not counted", W.mine().total, 2)
  eq("BG kills not in weekly", W.mine().weekly, 2)
  -- the API catches up only after the loading screen out of the BG: still BG kills
  W.hk = 115; W.instance = nil; W.fire("PLAYER_ENTERING_WORLD", false, false); W.advance(11)
  eq("late BG kills read on the way out not counted", W.mine().total, 2)
  W.hk = 116; W.fire("PLAYER_PVP_KILLS_CHANGED"); W.advance(11)
  eq("back in the world: counting again", W.mine().total, 3)
  -- a world kill read on the loading screen into a BG belongs to the world
  W.hk = 117; W.instance = "pvp"; W.fire("PLAYER_ENTERING_WORLD", false, false); W.advance(11)
  eq("world kill read on the way into a BG counted", W.char().worldKills, 4)
  eq("debug runs", pcall(W.slash, "debug"), true)
end

do -- GFoA: honor-line fallback skips battleground kills too
  local W = newWorld({ noApi = true })
  W.login()
  local line = "Grunt Zog dies, honorable kill Rank: Scout (Estimated Honor Points: 12)"
  W.fire("CHAT_MSG_COMBAT_HONOR_GAIN", line)
  W.instance = "pvp"
  W.fire("CHAT_MSG_COMBAT_HONOR_GAIN", line); W.fire("CHAT_MSG_COMBAT_HONOR_GAIN", line)
  W.advance(11)
  eq("log: only the world kill counts", W.mine().total, 1)
  eq("log: all honor lines still in logKills", W.char().logKills, 3)
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
