---------------------------------------------------------------------
-- Gay Furries of Azeroth Leaderboard
-- Three guild leaderboards: PvP kills (new kills count in world PvP only: no battlegrounds, no raid groups; kills
-- made before 0.3.1 are kept),
-- deaths (weekly + lifetime), gold.
-- Target: WoW Forever client 1.60.1 (Classic-style API, Interface 16001)
---------------------------------------------------------------------
local PREFIX = "GPVPLB"

-- Weekly reset: Tuesday at this UTC hour. Adjust to match your region's reset.
local RESET_HOUR_UTC = 15
local RESET_OFFSET = 5 * 86400 + RESET_HOUR_UTC * 3600 -- epoch 0 was a Thursday

-- GFoA: PvP kill season. The board KEEPS everyone's kills (Harley: never reset players' stats), so a season does not
-- zero the total: c.keptKills (the 1.8.4 total, frozen once) + c.seasonKills (world kills since). Older copies'
-- totals are on the same scale, so they are shown as-is.
-- 0.3.2 (addon 1.8.6, Harley's call): season 2 = a FULL reset. Everyone's kills restart at 0 and only world PvP
-- kills count from here; entries from older versions/seasons show 0 kills until they update.
local KILLS_SEASON = 2

local SendAddonMessage = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or _G.SendAddonMessage
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or _G.RegisterAddonMessagePrefix

-- GFoA: coin letters in the game's gold / silver / copper colors; only the letter, not the number. resume: the
-- color code to go back to after the letter, for amounts inside colored text (|r would end that color too).
local COIN_COLOR = { g = "|cffffd700", s = "|cffc7c7cf", c = "|cffeda55f" }
local function Coin(n, letter, resume)
    return n .. COIN_COLOR[letter] .. letter .. (resume or "|r")
end

-- On WoW: Forever every character has a first name AND a surname. UnitName() only
-- hands back the first name (its second value is the surname, not a realm), so build
-- the full "First Surname" name from GetUnitName, the same form guildmates show up
-- under in the guild roster, chat and addon messages.
local function MyName()
    if GetUnitName then
        local n = GetUnitName("player", false)
        if n and n ~= "" then return n end
    end
    return (UnitName("player"))
end

local db
local ready = false
local board = "pvp" -- "pvp", "deaths" or "gold"
local sortKey = "weekly"
local sortAsc = false
local Refresh -- forward declaration

---------------------------------------------------------------------
-- Stats
---------------------------------------------------------------------
local function CurrentWeekId()
    return math.floor((GetServerTime() - RESET_OFFSET) / 604800)
end

local function ApiLifetimeKills()
    if GetPVPLifetimeStats then
        local hk = GetPVPLifetimeStats()
        if type(hk) == "number" then return hk end
    end
    return nil
end

-- GFoA: per-character counters. GayFurriesLeaderboardDB is account-wide (## SavedVariables), so these counters used to
-- be shared by every character on the account: an alt's deaths landed on the main's total and alts got wrong weekly
-- kills. They now live in db.chars["First Surname"]; the shared board (members, duels, rolls) and settings stay top-level.
-- Migration: the first character to log in after this update takes over the old top-level values (it owns the old
-- totals); every other character starts at 0 with its own baselines. The old top-level fields are left in place, unused,
-- so an older copy of the addon can still read the file; db.migratedChars = true marks that the hand-over happened.
local CHAR_FIELDS = { "deaths", "logKills", "weekId", "weekBase", "dWeekBase" }
local function Char()
    local me = MyName() or "?"
    db.chars = db.chars or {}
    local c = db.chars[me]
    if not c then
        local first = UnitName("player")
        if first and first ~= me and db.chars[first] then -- made while only the first name was known
            c, db.chars[first] = db.chars[first], nil
        else
            c = { baseSource = db.source }
            if not db.migratedChars then
                for _, k in ipairs(CHAR_FIELDS) do c[k] = db[k] end
            end
        end
        db.migratedChars = true
        db.chars[me] = c
    end
    if c.ks ~= KILLS_SEASON then -- new kill season: count new world kills from 0 on top of the kept total
        c.ks = KILLS_SEASON
        c.seasonKills = 0
        c.keptKills = 0 -- full reset: nothing kept (also stops SyncKills freezing an old total)
        c.weekBase = 0
    end
    return c
end

-- GFoA: the PvP board counts world PvP kills only, never battleground kills. GetPVPLifetimeStats() includes BG
-- kills and can't be split, so the board keeps its own per-character counters that only grow outside a BG:
--   c.worldKills  - increases of the API lifetime count seen outside a BG (c.apiSeen = last API value seen)
--   c.logWorld    - honorable-kill chat lines seen outside a BG (fallback / "/gpvp source log")
-- c.logKills still counts every honor line. Kills made before the switch can't be told apart (the game only gives one
-- lifetime number), so everyone KEEPS them: the first sync seeds the world counters with the old totals and only kills
-- after that skip battlegrounds. c.killsV = 3 marks that seed. Version 2 (addon 1.8.3) wrongly restarted totals at 0;
-- version 3 puts the lifetime count back and keeps this week's count where it was.
local KILLS_VERSION = 3
local wasBG = false -- were we in a battleground at the last kill sync (this session)

local function InBattleground()
    if UnitInBattleground and UnitInBattleground("player") then return true end
    if IsInInstance then
        local inInstance, kind = IsInInstance()
        if inInstance and (kind == "pvp" or kind == "arena") then return true end
    end
    return false
end

-- GFoA kill season (0.3.0, kept-kills fix 0.3.1): kills made before are KEPT, not restarted at 0. Season kills are counted
-- one by one from the honorable-kill chat line, at the moment of the kill, and only outside battlegrounds and raid
-- groups. (The API lifetime count can't be used: it can't be split by where a kill happened, and an increase can show
-- up after you've left the BG.) 0.3.1: the board total is c.keptKills + c.seasonKills; c.keptKills is the old kept
-- total (c.worldKills / c.logWorld), frozen at the first sync on this version.
local function InRaidGroup()
    if IsInRaid then return IsInRaid() and true or false end
    if GetNumRaidMembers then return (GetNumRaidMembers() or 0) > 0 end
    return false
end

local function KillCounts()
    return not InBattleground() and not InRaidGroup()
end

-- Folds new API kills into c.worldKills unless they were made in a BG. zoneChange = true for loading screens:
-- kills read then belong to the zone we just left (wasBG), not the one we arrived in.
-- GFoA: the board's kills come from two signals that can both fire for the same kill, in either order: the
-- honorable-kill chat line (never reaches addons on some clients, e.g. WoW: Forever) and a rise in the game's lifetime
-- kill count. c.logPending holds kills the chat line counted that the lifetime count hasn't shown yet (it can update
-- late); c.apiPending holds kills the lifetime count counted in the last minute, so a chat line for the same kill
-- doesn't count it again. counts: the kill is world PvP (not in a battleground or a raid group).
local function KillFromApi(c, d, counts)
    local match = math.min(d, c.logPending or 0)
    c.logPending = (c.logPending or 0) - match
    local extra = d - match
    if extra <= 0 then return end
    c.apiPending, c.apiPendingAt = (c.apiPending or 0) + extra, time()
    if counts then c.seasonKills = (c.seasonKills or 0) + extra end
end

local function KillFromLog(c, counts)
    if (c.apiPending or 0) > 0 and time() - (c.apiPendingAt or 0) <= 60 then
        c.apiPending = c.apiPending - 1 -- already counted from the lifetime count
        return
    end
    c.apiPending = 0
    c.logPending = (c.logPending or 0) + 1
    if counts then c.seasonKills = (c.seasonKills or 0) + 1 end
end

local function SyncKills(zoneChange)
    if not db or not ready then return end -- honor stats can read 0 for a moment after login
    local c = Char()
    local nowBG = InBattleground()
    local inBG = wasBG or (not zoneChange and nowBG)
    local api = ApiLifetimeKills()
    if c.killsV ~= KILLS_VERSION then -- one-time seed: keep every kill made before the switch
        local logMode = db.source == "log" or not api
        -- GFoA fix: a 0 here is usually a bad read (honor stats load late). Seeding on it set apiSeen = 0, so the next
        -- real reading was added on top of the kept kills. Wait for a real number; a character with truly 0 kills
        -- seeds on its first kill instead.
        if api == 0 and not logMode then wasBG = nowBG; return end
        local old -- the number this week's base was measured against
        if c.killsV == 2 then
            old = logMode and (c.logWorld or 0) or (c.worldKills or 0)
        else
            old = logMode and (c.logKills or 0) or api
        end
        if api then
            c.worldKills = math.max(c.worldKills or 0, api)
            c.apiSeen = api
        end
        c.logWorld = math.max(c.logWorld or 0, c.logKills or 0)
        c.killsV = KILLS_VERSION
        local new = logMode and c.logWorld or c.worldKills
        if c.weekBase then c.weekBase = c.weekBase + (new - old) end -- this week's count stays the same
        if c.keptKills == nil then c.keptKills = math.max(0, new - (c.seasonKills or 0)) end -- GFoA: freeze kept total
        wasBG = nowBG
        return
    end
    if c.keptKills == nil then -- GFoA: freeze the kept total (before folding in new kills, which seasonKills counts)
        -- (logWorld already holds honor lines seen before this first sync, which seasonKills counted too)
        c.keptKills = (db.source == "log" or not api) and math.max(0, (c.logWorld or 0) - (c.seasonKills or 0))
            or (c.worldKills or 0)
    end
    if api then
        if c.apiSeen == nil then
            c.apiSeen = api -- first reading: baseline only
        elseif api > c.apiSeen then
            if not inBG then c.worldKills = (c.worldKills or 0) + (api - c.apiSeen) end
            KillFromApi(c, api - c.apiSeen, not inBG and not InRaidGroup()) -- GFoA: the board's count
            c.apiSeen = api
        end -- a lower reading is a bad read (the lifetime count never drops): ignore it
    end
    wasBG = nowBG
end

local function CurrentKills()
    return Char().seasonKills or 0 -- GFoA: this kill season's world kills only (full reset in season 2)
end

-- Updates and returns the player's own entry.
local function UpdateOwn()
    local c = Char() -- GFoA: per character (was db.*)
    SyncKills()
    local wk = CurrentWeekId()
    local kills = CurrentKills()
    local deaths = c.deaths or 0

    if c.weekId ~= wk then -- new week: re-baseline both weekly counters
        c.weekId = wk
        c.weekBase = kills
        c.dWeekBase = deaths
    end
    if not c.weekBase then c.weekBase = kills end
    if not c.dWeekBase then c.dWeekBase = deaths end
    -- GFoA fix: a lower kill count (another character on this account-wide DB, or a bad read) used to lower the
    -- base, so the next normal reading counted the whole difference as this week's kills. Clamp at 0 instead.
    if deaths < c.dWeekBase then c.dWeekBase = deaths end

    local _, class = UnitClass("player")
    local m = {
        total = kills, weekly = math.max(0, kills - c.weekBase),
        dTotal = deaths, dWeekly = deaths - c.dWeekBase,
        -- GFoA fix: Hidden Mode also hides your own saved entry (SavedVariables get uploaded to the guild Discord)
        gold = (db.shareGold == false) and -1 or (GetMoney() or 0),
        week = wk, class = class or "", updated = time(), ks = KILLS_SEASON,
    }
    local me = MyName()
    local first = UnitName("player")
    if first and first ~= me then db.members[first] = nil end -- old first-name-only entry
    db.members[me] = m
    return m
end

---------------------------------------------------------------------
-- Duels (guild members only)
---------------------------------------------------------------------
local guildSet = {}
local lastRoster = 0

-- GFoA Guild Sync (shipped in the same download) already asks for the roster every minute, and
-- GUILD_ROSTER_UPDATE reaches both addons, so only ask ourselves when it isn't running.
local function GuildSyncLoaded()
    if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded("GFoAGuildSync") end
    return IsAddOnLoaded and IsAddOnLoaded("GFoAGuildSync")
end

local function RequestRoster()
    if GuildSyncLoaded() then return end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

local function RebuildGuildSet()
    local set = {}
    for i = 1, (GetNumGuildMembers() or 0) do
        local name = GetGuildRosterInfo(i)
        if name then set[Ambiguate(name, "short")] = true end
    end
    if next(set) then guildSet = set end
end

-- Finds the full "First Surname" of a guild member. If only a first name is given,
-- it is matched when exactly one guild member has that first name.
local function ResolveGuildName(name)
    if guildSet[name] then return name end
    local found
    for full in pairs(guildSet) do
        if full:match("^(%S+)") == name then
            if found then return nil end -- more than one guildmate shares that first name
            found = full
        end
    end
    return found
end

-- Turns a game string like "%1$s has defeated %2$s in a duel." into a Lua pattern.
-- Returns the pattern and whether the two captures come in (loser, winner) order.
-- The game always passes (winner, loser); translations just reorder the text.
local function BuildDuelPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local i1 = fmt:find("%1$s", 1, true)
    local i2 = fmt:find("%2$s", 1, true)
    if not i1 or not i2 then return nil end
    local pat = fmt:gsub("%%1%$s", "\1"):gsub("%%2%$s", "\2")
    pat = pat:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
    pat = pat:gsub("\1", "(.+)"):gsub("\2", "(.+)")
    return "^" .. pat .. "$", i2 < i1
end

local duelPatterns
local function ParseDuel(msg)
    if not duelPatterns then
        duelPatterns = {}
        for _, fmt in ipairs({ DUEL_WINNER_KNOCKOUT, DUEL_WINNER_RETREAT }) do
            local pat, swap = BuildDuelPattern(fmt)
            if pat then duelPatterns[#duelPatterns + 1] = { pat, swap } end
        end
        if #duelPatterns == 0 then
            duelPatterns[1] = { "^(.+) has defeated (.+) in a duel%.?$", false }
        end
    end
    for _, e in ipairs(duelPatterns) do
        local a, b = msg:match(e[1])
        if a and b then
            if e[2] then a, b = b, a end
            return a, b -- winner, loser
        end
    end
end

-- returns true if this was a new duel (not a duplicate)
local function RecordDuel(w, l, wc, lc, t)
    db.duels = db.duels or {}
    for _, d in ipairs(db.duels) do
        if d.w == w and d.l == l and math.abs(d.t - t) <= 15 then return false end
    end
    table.insert(db.duels, 1, { w = w, l = l, wc = wc or "", lc = lc or "", t = t })
    while #db.duels > 300 do table.remove(db.duels) end
    return true
end

---------------------------------------------------------------------
-- GFoA: Overall board (class, level, /played time, two main professions, highest single hit)
---------------------------------------------------------------------
-- Main professions. Read three ways, first one that finds any wins (clients differ in which of these work):
--   1. the skill list, matching profession names anywhere in it (no reliance on section headings)
--   2. GetProfessions(): its first two slots are the main professions (cooking/fishing have their own slots)
--   3. the profession spells you know (Apprentice to Artisan of each)
-- Cooking, Fishing, First Aid and Poisons never count.
local MAIN_PROFESSIONS = {
    Alchemy = true, Blacksmithing = true, Enchanting = true, Engineering = true, Herbalism = true,
    Leatherworking = true, Mining = true, Skinning = true, Tailoring = true, Jewelcrafting = true, Inscription = true,
}
local NOT_MAIN_PROFESSION = { ["Cooking"] = true, ["Fishing"] = true, ["First Aid"] = true, ["Poisons"] = true }
-- Profession rank spells (Apprentice, Journeyman, Expert, Artisan).
local PROFESSION_SPELLS = {
    Alchemy = { 2259, 3101, 3464, 11611 },        Blacksmithing = { 2018, 3100, 3538, 9785 },
    Enchanting = { 7411, 7412, 7413, 13920 },     Engineering = { 4036, 4037, 4038, 12656 },
    Herbalism = { 2366, 2368, 3570, 11993 },      Leatherworking = { 2108, 3104, 3811, 10662 },
    Mining = { 2575, 2576, 3564, 10248 },         Skinning = { 8613, 8617, 8618, 10768 },
    Tailoring = { 3908, 3909, 3910, 12180 },
}
-- Short names, used on the Overall board when both full names don't fit.
local PROF_SHORT = {
    Alchemy = "Alch", Blacksmithing = "BS", Enchanting = "Ench", Engineering = "Eng", Herbalism = "Herb",
    Leatherworking = "LW", Mining = "Mine", Skinning = "Skin", Tailoring = "Tailor", Jewelcrafting = "JC",
}
local profSource = "none" -- which method found them last (for /gpvp debug)

local function ProfsFromSkillLines()
    if not GetNumSkillLines or not GetSkillLineInfo then return {} end
    local out = {}
    for i = 1, GetNumSkillLines() or 0 do
        local name, isHeader = GetSkillLineInfo(i)
        if not isHeader and MAIN_PROFESSIONS[name or ""] and #out < 2 then out[#out + 1] = name end
    end
    return out
end

local function ProfsFromGetProfessions()
    if not GetProfessions or not GetProfessionInfo then return {} end
    local ok, p1, p2 = pcall(GetProfessions)
    if not ok then return {} end
    local out = {}
    for _, idx in ipairs({ p1 or false, p2 or false }) do
        if idx then
            local name = GetProfessionInfo(idx)
            if type(name) == "string" and name ~= "" and not NOT_MAIN_PROFESSION[name] then out[#out + 1] = name end
        end
    end
    return out
end

local function KnowsSpell(id)
    if IsPlayerSpell then return IsPlayerSpell(id) end
    if IsSpellKnown then return IsSpellKnown(id) end
    return false
end

local function ProfsFromSpells()
    local out = {}
    for name, ids in pairs(PROFESSION_SPELLS) do
        for _, id in ipairs(ids) do
            local ok, known = pcall(KnowsSpell, id)
            if ok and known then out[#out + 1] = name; break end
        end
    end
    table.sort(out)
    while #out > 2 do table.remove(out) end
    return out
end

-- This character's main professions (up to 2), or nil when none could be read right now: keep the saved ones then.
local function ReadMainProfessions()
    for _, m in ipairs({
        { "skill list", ProfsFromSkillLines }, { "GetProfessions", ProfsFromGetProfessions }, { "spells", ProfsFromSpells },
    }) do
        local ok, out = pcall(m[2])
        if ok and type(out) == "table" and #out > 0 then
            profSource = m[1]
            return out
        end
    end
    profSource = "none found"
    return nil
end

-- Played time comes only from /played (typed by the player; the addon never asks, so chat stays quiet). After that
-- it keeps counting while this character is online: c.played at c.playedAt, folded in on logout.
local playedSession = false
local function PlayedNow(c)
    if type(c.played) ~= "number" then return nil end
    if type(c.playedAt) ~= "number" then return c.played end
    return c.played + math.max(0, time() - c.playedAt)
end

-- Highest single hit: from your own combat chat lines (the combat log is off limits to addons here), parsed with
-- the client's own global strings so they match its language; English " for N" as the fallback.
local HIT_STRINGS = {
    "COMBATHITSELFOTHER", "COMBATHITCRITSELFOTHER", "COMBATHITSCHOOLSELFOTHER", "COMBATHITCRITSCHOOLSELFOTHER",
    "SPELLLOGSELFOTHER", "SPELLLOGCRITSELFOTHER", "SPELLLOGSCHOOLSELFOTHER", "SPELLLOGCRITSCHOOLSELFOTHER",
}
local hitPatterns
local function BuildHitPatterns()
    hitPatterns = {}
    for _, key in ipairs(HIT_STRINGS) do
        local fmt = _G[key]
        if type(fmt) == "string" then
            local pos, amountPos = 0, nil
            local p = fmt:gsub("%%%d*%$?([sd])", function(k)
                pos = pos + 1
                if k == "d" and not amountPos then amountPos = pos end
                return (k == "d") and "\2" or "\1"
            end)
            if amountPos then
                p = p:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
                p = p:gsub("\1", "(.-)"):gsub("\2", "(%%d+)")
                hitPatterns[#hitPatterns + 1] = { pattern = "^" .. p, amount = amountPos }
            end
        end
    end
end

local function HitAmount(msg)
    if type(msg) ~= "string" then return nil end
    if issecretvalue and issecretvalue(msg) then return nil end
    if not hitPatterns then BuildHitPatterns() end
    for _, h in ipairs(hitPatterns) do
        local caps = { msg:match(h.pattern) }
        if caps[1] then return tonumber(caps[h.amount]) end
    end
    return tonumber(msg:match("^Your? .- for (%d+)"))
end
local hitEvents = 0 -- how many of the two combat chat events this client has (for /gpvp debug)

-- Second source for the top hit, for clients where those chat lines never reach addons: UNIT_COMBAT, the damage
-- your target takes. It can't tell whose hit it was, so it only counts while you're solo (no party or raid), on
-- a target you can attack. Secret amounts (hidden from addons) are skipped.
local targetDamage = "none seen yet" -- for /gpvp debug: "readable", "secret (hidden from addons)" or "none seen yet"
local function Solo()
    if IsInGroup then return not IsInGroup() end
    if GetNumGroupMembers then return (GetNumGroupMembers() or 0) == 0 end
    return (GetNumPartyMembers and GetNumPartyMembers() or 0) == 0 and (GetNumRaidMembers and GetNumRaidMembers() or 0) == 0
end
local function TargetHitAmount(unit, action, amount)
    if unit ~= "target" then return nil end
    if issecretvalue and issecretvalue(action) then targetDamage = "secret (hidden from addons)"; return nil end
    if action ~= "WOUND" then return nil end
    if issecretvalue and issecretvalue(amount) then targetDamage = "secret (hidden from addons)"; return nil end
    if type(amount) ~= "number" or amount <= 0 then return nil end
    targetDamage = "readable"
    if not Solo() or not UnitCanAttack or not UnitCanAttack("player", "target") then return nil end
    return amount
end

-- Sends (and saves) this character's Overall board line.
-- Message: O:level:played:topHit:profession1:profession2 (played -1 until /played was typed; professions may be empty)
local function SendOverall()
    local c = Char()
    local profs = ReadMainProfessions()
    if profs then c.profs = profs end
    local p = c.profs or {}
    local played = PlayedNow(c)
    local o = {
        level = UnitLevel("player") or 0, played = played and math.floor(played) or -1, hit = c.topHit or 0,
        p1 = p[1] or "", p2 = p[2] or "", updated = time(),
    }
    db.overall = db.overall or {}
    db.overall[MyName()] = o
    SendAddonMessage(PREFIX, string.format("O:%d:%d:%d:%s:%s", o.level, o.played, o.hit, o.p1, o.p2), "GUILD")
end

---------------------------------------------------------------------
-- Networking
-- Message: kills:killsWeekly:weekId:CLASS:deaths:deathsWeekly:copper
-- copper is -1 if the player chose not to share their gold.
-- GFoA: followed by "S:season" (kill season, see KILLS_SEASON). Sent separately so older clients, whose parser
-- expects exactly the fields above, still read the main message; they ignore the S line.
---------------------------------------------------------------------
local lastSend, pending = 0, false

local function Broadcast()
    if not ready or not IsInGuild() then return end
    local m = UpdateOwn()
    SendOverall() -- GFoA: the Overall board line ("O:..."), ignored by older clients
    local gold = (db.shareGold == false) and -1 or m.gold
    SendAddonMessage(PREFIX, string.format("%d:%d:%d:%s:%d:%d:%.0f",
        m.total, m.weekly, m.week, m.class, m.dTotal, m.dWeekly, gold), "GUILD")
    SendAddonMessage(PREFIX, "S:" .. KILLS_SEASON, "GUILD")
    lastSend = GetTime()
    if Refresh then Refresh() end
end

local function ScheduleBroadcast()
    if pending then return end
    pending = true
    local wait = math.max(3, 10 - (GetTime() - lastSend))
    C_Timer.After(wait, function()
        pending = false
        Broadcast()
    end)
end

-- your own duels, from the system chat message
local function OnSystemMessage(msg)
    if not db or type(msg) ~= "string" then return end
    local w, l = ParseDuel(msg)
    if not w then return end
    w, l = Ambiguate(w, "short"), Ambiguate(l, "short")
    local me = MyName()
    local myFirst = UnitName("player")
    if w == myFirst then w = me end -- the chat line may use first names only
    if l == myFirst then l = me end
    if w ~= me and l ~= me then return end
    local opp = ResolveGuildName((w == me) and l or w)
    if not opp then return end -- guild members only
    if w == me then l = opp else w = opp end

    local _, myClass = UnitClass("player")
    myClass = myClass or ""
    local oppClass = (db.members[opp] and db.members[opp].class) or ""
    local wc = (w == me) and myClass or oppClass
    local lc = (l == me) and myClass or oppClass
    local t = GetServerTime()
    RecordDuel(w, l, wc, lc, t)
    if w == me and IsInGuild() then -- the winner announces it; everyone else just receives it
        SendAddonMessage(PREFIX, string.format("D:%s:%s:%s:%s:%d", w, wc, l, lc, t), "GUILD")
    end
    if Refresh then Refresh() end
end

---------------------------------------------------------------------
-- Deathrolls (guild members only)
-- A deathroll is a chain of /roll messages: A rolls 1-N, B rolls 1-(A's result), and so
-- on until someone rolls a 1 and loses. The bet is read from the gold the loser trades
-- to the winner afterwards (trade window), so it only needs one of the two to run this.
---------------------------------------------------------------------
-- returns "new", "updated" or false
local function RecordRoll(w, l, wc, lc, t, bet)
    db.rolls = db.rolls or {}
    for _, d in ipairs(db.rolls) do
        if d.w == w and d.l == l and math.abs(d.t - t) <= 5 then
            if bet and bet >= 0 and (not d.bet or d.bet < 0) then
                d.bet = bet
                return "updated"
            end
            return false
        end
    end
    table.insert(db.rolls, 1, { w = w, l = l, wc = wc or "", lc = lc or "", t = t, bet = (bet and bet >= 0) and bet or nil })
    while #db.rolls > 500 do table.remove(db.rolls) end
    return "new"
end

local function SendRoll(d)
    if IsInGuild() then
        SendAddonMessage(PREFIX, string.format("R:%s:%s:%s:%s:%d:%.0f", d.w, d.wc or "", d.l, d.lc or "", d.t, d.bet or -1), "GUILD")
    end
end

-- "%s rolls %d (%d-%d)" as a Lua pattern, keeping track of the argument order
local rollPattern, rollOrder
local function ParseRoll(msg)
    if not rollPattern then
        local fmt = RANDOM_ROLL_RESULT
        if type(fmt) == "string" and fmt:find("%%") then
            local order = {}
            local tmp = fmt:gsub("%%(%d*)%$?([sd])", function(n, k)
                order[#order + 1] = tonumber(n) or (#order + 1)
                return (k == "s") and "\1" or "\2"
            end)
            tmp = tmp:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
            tmp = tmp:gsub("\1", "(.+)"):gsub("\2", "(%%d+)")
            if #order == 4 then rollPattern, rollOrder = "^" .. tmp .. "$", order end
        end
        if not rollPattern then
            rollPattern, rollOrder = "^(.+) rolls (%d+) %((%d+)%-(%d+)%)$", { 1, 2, 3, 4 }
        end
    end
    local c = { msg:match(rollPattern) }
    if #c < 4 then return end
    local a = {}
    for i = 1, 4 do a[rollOrder[i]] = c[i] end
    return a[1], tonumber(a[2]), tonumber(a[3]), tonumber(a[4]) -- name, result, min, max
end

-- who is this roller? a guild member's full name, or the plain name for anyone else
local function NormalizeRoller(name)
    name = Ambiguate(name, "short")
    local me, myFirst = MyName(), UnitName("player")
    if name == me or name == myFirst then return me end
    return ResolveGuildName(name) or name
end

local function IsGuildie(name)
    return name == MyName() or guildSet[name] == true
end

local rollChains = {}

local function FinishDeathroll(winner, loser)
    if not next(guildSet) then return end                 -- roster not loaded yet
    if not (IsGuildie(winner) and IsGuildie(loser)) then return end -- guild members only
    local function classOf(n)
        if n == MyName() then local _, c = UnitClass("player"); return c or "" end
        return (db.members[n] and db.members[n].class) or ""
    end
    local d = { w = winner, l = loser, wc = classOf(winner), lc = classOf(loser), t = GetServerTime() }
    if RecordRoll(d.w, d.l, d.wc, d.lc, d.t) == "new" then
        SendRoll(d)
        if Refresh then Refresh() end
    end
end

local function OnRollMessage(msg)
    if not db or type(msg) ~= "string" then return end
    local name, result, mn, mx = ParseRoll(msg)
    if not name or not result or mn ~= 1 or not mx or mx < 2 then return end
    local who = NormalizeRoller(name)
    local now = GetTime()

    for i = #rollChains, 1, -1 do -- forget chains that went quiet
        if now - rollChains[i].time > 180 then table.remove(rollChains, i) end
    end

    for i, c in ipairs(rollChains) do
        -- GFoA fix: the opener (c.first) may continue the chain too; before, a 1 rolled by the opener was never matched
        if c.last == mx and c.lastBy ~= who and (not c.second or c.second == who or c.first == who) then
            c.second = c.second or who
            c.lastBy, c.last, c.time, c.n = who, result, now, c.n + 1
            if result == 1 then -- this player lost
                table.remove(rollChains, i)
                local winner = (c.first == who) and c.second or c.first
                if c.n >= 2 then FinishDeathroll(winner, who) end
            end
            return
        end
    end

    if result == 1 then return end -- a lone 1 on the opening roll isn't a deathroll
    for i = #rollChains, 1, -1 do   -- a re-rolled opening roll replaces the old one
        if rollChains[i].lastBy == who and rollChains[i].n == 1 then table.remove(rollChains, i) end
    end
    rollChains[#rollChains + 1] = { first = who, last = result, lastBy = who, n = 1, time = now }
    while #rollChains > 30 do table.remove(rollChains, 1) end
end

-- the bet: gold the loser trades to the winner shortly after a deathroll
local trade = { partner = nil, agreed = false, give = 0, get = 0, done = false }

local function TradePartnerName()
    local n = GetUnitName and GetUnitName("NPC", false)
    if not n or n == "" then n = UnitName("NPC") end
    if (not n or n == "") and TradeFrameRecipientNameText then n = TradeFrameRecipientNameText:GetText() end
    return n
end

local function CommitTrade()
    if trade.done or not trade.agreed or not db then return end
    trade.done = true
    local partner = trade.partner and ResolveGuildName(Ambiguate(trade.partner, "short"))
    if not partner then return end                      -- guild members only
    local net = (trade.get or 0) - (trade.give or 0)    -- >0: I received gold, <0: I paid
    if net == 0 then return end
    local me, now = MyName(), GetServerTime()
    for _, d in ipairs(db.rolls or {}) do
        -- GFoA fix: skip old rows instead of stopping; a late-received older roll can sit above newer ones
        if now - d.t <= 1800 and not d.bet then
            local ok
            if net > 0 then ok = (d.w == me and d.l == partner) else ok = (d.l == me and d.w == partner) end
            if ok then
                d.bet = math.abs(net)
                SendRoll(d)
                print("|cff33ff99GayFurriesLeaderboard:|r deathroll bet recorded: " .. ((GetCoinTextureString and GetCoinTextureString(d.bet)) or Coin(math.floor(d.bet / 10000), "g"))
                    .. " (" .. d.w .. " beat " .. d.l .. ")")
                if Refresh then Refresh() end
                return
            end
        end
    end
end

local function OnTradeEvent(event, ...)
    if event == "TRADE_SHOW" then
        trade = { partner = TradePartnerName(), agreed = false, give = 0, get = 0, done = false }
    elseif event == "TRADE_ACCEPT_UPDATE" then
        local mine, theirs = ...
        if (mine == 1 or mine == true) and (theirs == 1 or theirs == true) then
            trade.partner = trade.partner or TradePartnerName()
            trade.give = GetPlayerTradeMoney and GetPlayerTradeMoney() or 0
            trade.get = GetTargetTradeMoney and GetTargetTradeMoney() or 0
            trade.agreed = true
        else
            trade.agreed = false
        end
    elseif event == "TRADE_CLOSED" then
        -- fallback if the "Trade complete." message isn't seen: commit unless it was cancelled
        C_Timer.After(1.5, function() if trade.agreed and not trade.cancelled then CommitTrade() end end)
    end
end

local function OnTradeSystemMessage(msg)
    if type(msg) ~= "string" then return end
    if msg == (ERR_TRADE_COMPLETE or "Trade complete.") then
        CommitTrade()
    elseif msg == (ERR_TRADE_CANCELLED or "Trade cancelled.") then
        trade.agreed = false
    end
end

local function OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= PREFIX or channel ~= "GUILD" then return end
    local name = Ambiguate(sender, "short")
    -- GFoA fix: guild addon messages come back to the sender, sometimes under the first name only
    if name == MyName() or name == UnitName("player") then return end

    -- GFoA Overall board: O:level:played:topHit:profession1:profession2
    local ol, op, oh, p1, p2 = text:match("^O:(%d+):(%-?%d+):(%d+):([^:]*):([^:]*)$")
    if ol then
        db.overall = db.overall or {}
        db.overall[name] = {
            level = tonumber(ol), played = tonumber(op), hit = tonumber(oh), p1 = p1, p2 = p2, updated = time(),
        }
        if Refresh then Refresh() end
        return
    end

    if text == "REQ" then
        -- stagger replies so the whole guild doesn't answer at once
        C_Timer.After(1 + math.random() * 8, Broadcast)
        return
    end

    -- GFoA kill season, sent right after the sender's stats message
    local ks = text:match("^S:(%d+)$")
    if ks then
        local m = db.members[name]
        if m then m.ks = tonumber(ks); if Refresh then Refresh() end end
        return
    end

    -- duel result: D:winner:WINNERCLASS:loser:LOSERCLASS:time
    local dw, dwc, dl, dlc, dt = text:match("^D:([^:]+):(%u*):([^:]+):(%u*):(%d+)$")
    if dw then
        if RecordDuel(dw, dl, dwc, dlc, tonumber(dt)) and Refresh then Refresh() end
        return
    end

    -- deathroll: R:winner:WINNERCLASS:loser:LOSERCLASS:time:bet (bet is -1 until known)
    local rw, rwc, rl, rlc, rt, rb = text:match("^R:([^:]+):(%u*):([^:]+):(%u*):(%d+):(-?%d+)$")
    if rw then
        if RecordRoll(rw, rl, rwc, rlc, tonumber(rt), tonumber(rb)) and Refresh then Refresh() end
        return
    end

    local k, kw, wk, class, rest = text:match("^(%d+):(%d+):(%d+):(%u*)(.*)$")
    if not k then return end
    local d, dw, g = rest:match("^:(%d+):(%d+):(-?%d+)$") -- older clients don't send these
    db.members[name] = {
        total = tonumber(k), weekly = tonumber(kw), week = tonumber(wk), class = class,
        dTotal = tonumber(d) or 0, dWeekly = tonumber(dw) or 0, gold = tonumber(g) or -1,
        updated = time(),
    }
    if Refresh then Refresh() end
end

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------
local ROW_H = 18

-- pastel rainbow
local RAINBOW = {
    { 1, 0.68, 0.68 }, { 1, 0.84, 0.65 }, { 0.99, 1, 0.71 },
    { 0.79, 1, 0.75 }, { 0.61, 0.96, 1 }, { 0.74, 0.70, 1 },
}
local GRAYS = {
    { 0.78, 0.78, 0.78 }, { 0.70, 0.70, 0.70 }, { 0.62, 0.62, 0.62 },
    { 0.54, 0.54, 0.54 }, { 0.46, 0.46, 0.46 }, { 0.38, 0.38, 0.38 },
}
local HEX_DEEP = { "ff7eb6", "ffa05c", "e8c32a", "5fcf8c", "5db7ff", "a784ff" } -- readable on light backgrounds
local HEX_BRIGHT = { "ffadad", "ffd6a5", "fdffb6", "caffbf", "9bf6ff", "bdb2ff" } -- for dark backgrounds (tooltip)

local HEX_CAT = { "c77dff", "9d4edd", "e0aaff", "b392f0", "7b2cbf", "d0a2ff" } -- purple title for the cat look
local PURPLES = {
    { 0.30, 0.08, 0.52 }, { 0.40, 0.12, 0.65 }, { 0.52, 0.20, 0.78 },
    { 0.64, 0.32, 0.88 }, { 0.76, 0.48, 0.94 }, { 0.86, 0.64, 0.98 },
}
local HEX_BLUE = { "1e6fd9", "3b8cf0", "0f4fb5", "5aa0f5", "2a5fc4", "4d8de8" } -- title for the blue look
local BLUES = {
    { 0.75, 0.87, 1.00 }, { 0.60, 0.78, 1.00 }, { 0.45, 0.68, 0.98 },
    { 0.30, 0.56, 0.95 }, { 0.20, 0.45, 0.88 }, { 0.12, 0.33, 0.75 },
}
local HEX_BERRII = { "e64980", "d6336c", "f06595", "c2255c", "ff6b9d", "e0457f" } -- pinks for the berrii title
local PINKS = { -- candy stripes: pink / white
    { 1.00, 0.62, 0.78 }, { 1.00, 0.97, 0.99 }, { 1.00, 0.62, 0.78 },
    { 1.00, 0.97, 0.99 }, { 1.00, 0.62, 0.78 }, { 1.00, 0.97, 0.99 },
}
local CAT_ON = { 0.62, 0.32, 0.92 } -- (kept for the cat theme's track color)

local function RainbowText(str, bright)
    local hex = (type(bright) == "table") and bright or (bright and HEX_BRIGHT or HEX_DEEP)
    local out = {}
    for i = 1, #str do
        out[#out + 1] = "|cff" .. hex[(i - 1) % 6 + 1] .. str:sub(i, i) .. "|r"
    end
    return table.concat(out)
end

-- cute prefixes, cutest first. Rank 1 = "The Cutest <name>"
local CUTE = {
    "The Cutest", "The Sparkliest", "The Fluffiest", "The Sweetest", "The Cuddliest",
    "The Snuggliest", "The Dreamiest", "The Bubbliest", "The Coziest", "The Sleepiest",
    "The Wobbliest", "The Tiniest",
}
local CUTE_FALLBACK = "Cute"

local function FormatMoney(c)
    if not c or c < 0 then return "Hidden" end
    if GetCoinTextureString then return GetCoinTextureString(c) end
    local g = math.floor(c / 10000)
    local s = math.floor((c % 10000) / 100)
    return Coin(g, "g") .. " " .. Coin(s, "s") .. " " .. Coin(c % 100, "c")
end

-- compact money text: 1,250g 50s
local function ShortMoney(c, resume)
    c = math.abs(c or 0)
    local g, s, cp = math.floor(c / 10000), math.floor((c % 10000) / 100), c % 100
    if g > 0 then
        local str = tostring(g):reverse():gsub("(%d%d%d)", "%1,"):reverse()
        str = str:gsub("^,", "")
        return Coin(str, "g", resume) .. (s > 0 and (" " .. Coin(s, "s", resume)) or "")
    elseif s > 0 then
        return Coin(s, "s", resume) .. (cp > 0 and (" " .. Coin(cp, "c", resume)) or "")
    end
    return Coin(cp, "c", resume)
end

-- +green / -red net amount
local function NetText(c)
    if c > 0 then return "|cff2fb35a+" .. ShortMoney(c, "|cff2fb35a") .. "|r" end
    if c < 0 then return "|cffe0443e-" .. ShortMoney(c, "|cffe0443e") .. "|r" end
    return Coin(0, "g")
end

local function Hex(c)
    return string.format("%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

local function ClassColored(name, class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not c then return name end
    return string.format("|cff%02x%02x%02x%s|r", math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5), name)
end

local function TimeAgo(sec)
    if sec < 60 then return "just now" end
    if sec < 3600 then return math.floor(sec / 60) .. "m ago" end
    if sec < 86400 then return math.floor(sec / 3600) .. "h ago" end
    return math.floor(sec / 86400) .. "d ago"
end

-- the leaderboards
local BOARD_ORDER = { "overall", "pvp", "deaths", "gold", "duels", "rolls", "rollrank" }
local BOARDS = {
    pvp = { label = "PvP Kills", subtitle = "PvP Leaderboard", defaultSort = "weekly",
        cols = { { key = "weekly", label = "Weekly" }, { key = "total", label = "Total" } } },
    deaths = { label = "Deaths", subtitle = "Death Leaderboard", defaultSort = "dWeekly",
        cols = { { key = "dWeekly", label = "Weekly" }, { key = "dTotal", label = "Total" } } },
    gold = { label = "Gold", subtitle = "Wealth Leaderboard", defaultSort = "gold",
        cols = { { key = "gold", label = "Total Wealth" } } },
    duels = { label = "Duels", subtitle = "Duel Log", defaultSort = "weekly", cols = {} },
    rolls = { label = "Deathroll", subtitle = "Deathroll History", defaultSort = "weekly", cols = {} },
    rollrank = { label = "Roll Ranks", subtitle = "Deathroll Rankings", defaultSort = "net",
        cols = { { key = "wins", label = "Record" }, { key = "net", label = "Net Gold" } } },
    -- GFoA: class, level, name, played time, main professions, highest single hit
    overall = { label = "Overall", subtitle = "Overall Leaderboard", defaultSort = "level", cols = {} },
}

-- two looks: the default pastel one, and the "straight" gray one
local THEMES = {
    gay = {
        bg = { 0.98, 0.93, 0.99, 0.98 }, border = { 1, 0.72, 0.86, 1 },
        stripes = RAINBOW,
        text = { 0.30, 0.15, 0.40 }, header = { 0.65, 0.32, 0.65 }, sub = { 0.78, 0.4, 0.78 },
        label = { 0.55, 0.25, 0.60 }, shadow = { 0.3, 0.1, 0.4, 0.55 }, prefix = "d6609a", menuBg = { 0.93, 0.85, 0.97, 1 },
        alt = 0.4, trackOff = { 0.86, 0.72, 0.92 }, trackOn = { 0.45, 0.45, 0.45 },
        tabOn = { 1, 0.72, 0.86, 1 }, tabOff = { 0.92, 0.84, 0.96, 1 },
        tabTextOn = { 0.30, 0.15, 0.40 }, tabTextOff = { 0.55, 0.30, 0.60 },
    },
    straight = {
        bg = { 0, 0, 0, 0.10 }, border = { 0.72, 0.72, 0.72, 1 }, -- 90% transparent black
        stripes = GRAYS,
        text = { 0.85, 0.85, 0.85 }, header = { 0.65, 0.65, 0.65 }, sub = { 0.65, 0.65, 0.65 },
        label = { 0.80, 0.80, 0.80 }, shadow = { 0, 0, 0, 0.8 }, prefix = "d6609a", menuBg = { 0.13, 0.13, 0.13, 0.98 },
        alt = 0.06, trackOff = { 0.86, 0.72, 0.92 }, trackOn = { 0.45, 0.45, 0.45 },
        tabOn = { 0.40, 0.40, 0.40, 0.95 }, tabOff = { 0.10, 0.10, 0.10, 0.55 },
        tabTextOn = { 1, 1, 1 }, tabTextOff = { 0.70, 0.70, 0.70 },
    },
}
-- purple and black "cat" look
THEMES.cat = {
    bg = { 0.06, 0.02, 0.11, 0.97 }, border = { 0.62, 0.32, 0.92, 1 },
    stripes = PURPLES,
    text = { 0.88, 0.78, 1.00 }, header = { 0.72, 0.50, 0.95 }, sub = { 0.78, 0.60, 1.00 },
    label = { 0.82, 0.72, 0.97 }, shadow = { 0, 0, 0, 0.85 }, prefix = "c77dff", menuBg = { 0.12, 0.06, 0.20, 1 },
    alt = 0.07, trackOff = { 0.30, 0.18, 0.45 }, trackOn = CAT_ON,
    tabOn = { 0.50, 0.22, 0.80, 1 }, tabOff = { 0.16, 0.08, 0.27, 1 },
    tabTextOn = { 1, 1, 1 }, tabTextOff = { 0.72, 0.56, 0.92 },
}

-- white and blue look (with the husky pup in the background)
THEMES.blue = {
    bg = { 0.95, 0.97, 1.00, 0.98 }, border = { 0.25, 0.50, 0.90, 1 },
    stripes = BLUES,
    text = { 0.10, 0.20, 0.45 }, header = { 0.20, 0.40, 0.75 }, sub = { 0.25, 0.50, 0.90 },
    label = { 0.15, 0.35, 0.70 }, shadow = { 0.1, 0.2, 0.4, 0.35 }, prefix = "3a7bd5", menuBg = { 0.86, 0.92, 1.00, 1 },
    alt = 0.55, trackOff = { 0.70, 0.82, 0.98 }, trackOn = { 0.25, 0.50, 0.90 },
    tabOn = { 0.30, 0.55, 0.95, 1 }, tabOff = { 0.86, 0.92, 1.00, 1 },
    tabTextOn = { 1, 1, 1 }, tabTextOff = { 0.20, 0.40, 0.75 },
}

-- pink and white look with the berrii cat photo behind a frosted veil
THEMES.berrii = {
    bg = { 1.00, 0.93, 0.96, 1 }, border = { 1.00, 0.52, 0.74, 1 },
    stripes = PINKS,
    text = { 0.36, 0.05, 0.24 }, header = { 0.58, 0.10, 0.38 }, sub = { 0.62, 0.14, 0.42 },
    label = { 0.45, 0.07, 0.30 }, shadow = { 1, 1, 1, 0.95 }, prefix = "d6336c", menuBg = { 1.00, 0.90, 0.95, 1 },
    alt = 0.35, trackOff = { 1.00, 0.80, 0.90 }, trackOn = { 0.90, 0.30, 0.55 },
    tabOn = { 1.00, 0.45, 0.70, 1 }, tabOff = { 1.00, 0.94, 0.97, 0.92 },
    tabTextOn = { 1, 1, 1 }, tabTextOff = { 0.58, 0.10, 0.38 },
}

-- db.theme is "gay", "straight", "cat", "blue" or "berrii"
local function Theme()
    return THEMES[(db and db.theme) or "gay"] or THEMES.gay
end

-- pastel mode: thin flat border. Straight mode: thick classic WoW dialog border.
local BD_GAY = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 2,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
}
local BD_BERRII = { -- chunky pink border (a white line is drawn just inside it)
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 5,
    insets = { left = 5, right = 5, top = 5, bottom = 5 },
}
local BD_STRAIGHT = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    edgeSize = 32,
    insets = { left = 11, right = 11, top = 11, bottom = 11 },
}

local frame = CreateFrame("Frame", "GayFurriesLeaderboardFrame", UIParent, "BackdropTemplate")
frame:SetSize(480, 480)
frame:SetPoint("CENTER")
frame:SetBackdrop(BD_GAY)
frame:SetBackdropColor(0.98, 0.93, 0.99, 0.98)
frame:SetBackdropBorderColor(1, 0.72, 0.86, 1)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetFrameStrata("DIALOG")
frame:SetClampedToScreen(true)
frame:SetResizable(true)
if frame.SetResizeBounds then
    frame:SetResizeBounds(460, 360, 900, 900)
elseif frame.SetMinResize then
    frame:SetMinResize(460, 360)
    if frame.SetMaxResize then frame:SetMaxResize(900, 900) end
end
frame:Hide()
tinsert(UISpecialFrames, "GayFurriesLeaderboardFrame") -- close with Esc

-- resize grip: drag the little triangle at the bottom right
local grip = CreateFrame("Button", nil, frame)
grip:SetSize(16, 16)
grip:SetPoint("BOTTOMRIGHT", -8, 8)
grip:SetFrameLevel(frame:GetFrameLevel() + 40)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
grip:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    if db then
        db.width, db.height = math.floor(frame:GetWidth() + 0.5), math.floor(frame:GetHeight() + 0.5)
    end
end)

-- background art: unicorn (default) or cat. Both .tga files ship in the addon folder.
local UNICORN_ART = "Interface\\AddOns\\GayFurriesLeaderboard\\unicorn.tga"
local CAT_ART = "Interface\\AddOns\\GayFurriesLeaderboard\\cat.tga"
local PUP_ART = "Interface\\AddOns\\GayFurriesLeaderboard\\pup.tga"
local THEME_ART = { gay = UNICORN_ART, cat = CAT_ART, blue = PUP_ART }
local THEME_TITLE_HEX = { cat = HEX_CAT, blue = HEX_BLUE, berrii = HEX_BERRII }
local unicorn = frame:CreateTexture(nil, "BORDER")
unicorn:SetTexture(UNICORN_ART)
unicorn:SetSize(230, 230)
unicorn:SetPoint("BOTTOMRIGHT", -14, 12)
unicorn:SetAlpha(0.6)

-- berrii theme: the cat photo fills the window, covered by a frosted pink-white veil so text stays readable
local BERRII_ART = "Interface\\AddOns\\GayFurriesLeaderboard\\berrii.tga"
local bgPic = frame:CreateTexture(nil, "BORDER", nil, -1)
bgPic:SetTexture(BERRII_ART)
bgPic:SetPoint("TOPLEFT", 7, -7)
bgPic:SetPoint("BOTTOMRIGHT", -7, 7)
local bgVeil = frame:CreateTexture(nil, "BORDER", nil, 1)
bgVeil:SetPoint("TOPLEFT", 7, -7)
bgVeil:SetPoint("BOTTOMRIGHT", -7, 7)
bgVeil:SetColorTexture(1, 0.94, 0.97, 0.52)
local berriiLines = {} -- white line just inside the pink border
for i = 1, 4 do
    local t = frame:CreateTexture(nil, "BORDER", nil, 2)
    t:SetColorTexture(1, 1, 1, 1)
    berriiLines[i] = t
end
berriiLines[1]:SetPoint("TOPLEFT", 5, -5);     berriiLines[1]:SetPoint("TOPRIGHT", -5, -5);     berriiLines[1]:SetHeight(2)
berriiLines[2]:SetPoint("BOTTOMLEFT", 5, 5);   berriiLines[2]:SetPoint("BOTTOMRIGHT", -5, 5);   berriiLines[2]:SetHeight(2)
berriiLines[3]:SetPoint("TOPLEFT", 5, -5);     berriiLines[3]:SetPoint("BOTTOMLEFT", 5, 5);     berriiLines[3]:SetWidth(2)
berriiLines[4]:SetPoint("TOPRIGHT", -5, -5);   berriiLines[4]:SetPoint("BOTTOMRIGHT", -5, 5);   berriiLines[4]:SetWidth(2)

-- four little strawberries with different faces, one near each corner (berries.tga is a 2x2 sheet)
local BERRIES_ART = "Interface\\AddOns\\GayFurriesLeaderboard\\berries.tga"
local berries = {}
do
    local spots = { -- sheet cell, anchor, x, y
        { 1, "TOPLEFT", -6, 6 }, { 2, "TOPRIGHT", 6, 10 },
        { 3, "BOTTOMLEFT", -6, -6 }, { 4, "BOTTOMRIGHT", -28, -4 }, -- kept clear of the resize grip
    }
    local cells = { { 0, 0.5, 0, 0.5 }, { 0.5, 1, 0, 0.5 }, { 0, 0.5, 0.5, 1 }, { 0.5, 1, 0.5, 1 } }
    for _, sp in ipairs(spots) do
        local t = frame:CreateTexture(nil, "OVERLAY", nil, 6)
        t:SetTexture(BERRIES_ART)
        local c = cells[sp[1]]
        t:SetTexCoord(c[1], c[2], c[3], c[4])
        t:SetSize(38, 38)
        t:SetPoint(sp[2], frame, sp[2], sp[3], sp[4])
        berries[#berries + 1] = t
    end
end

-- crop the (square) photo like "background-size: cover" so it never stretches
local function LayoutBerrii()
    local w, h = frame:GetWidth() - 14, frame:GetHeight() - 14
    if w <= 0 or h <= 0 then return end
    local r = w / h
    if r >= 1 then
        local half = 0.5 / r
        bgPic:SetTexCoord(0, 1, 0.5 - half, 0.5 + half)
    else
        local half = 0.5 * r
        bgPic:SetTexCoord(0.5 - half, 0.5 + half, 0, 1)
    end
end
local function ShowBerrii(on)
    for _, t in ipairs({ bgPic, bgVeil, berriiLines[1], berriiLines[2], berriiLines[3], berriiLines[4] }) do
        if on then t:Show() else t:Hide() end
    end
    for _, t in ipairs(berries) do
        if on then t:Show() else t:Hide() end
    end
    if on then LayoutBerrii() end
end
ShowBerrii(false)

-- band across the top (pastel rainbow; hidden in straight mode)
local stripeTex = {}
for i, c in ipairs(RAINBOW) do
    local t = frame:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(c[1], c[2], c[3], 1)
    t:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 4)
    t:SetPoint("TOPRIGHT", -2, -2 - (i - 1) * 4)
    t:SetHeight(4)
    stripeTex[i] = t
end

-- classic dialog title plaque (straight mode only)
local plaque = frame:CreateTexture(nil, "OVERLAY")
plaque:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
plaque:SetSize(340, 64)
plaque:SetPoint("TOP", 0, 12)
plaque:SetVertexColor(0.8, 0.8, 0.8)
plaque:Hide()

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -34)

local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
subtitle:SetPoint("TOP", title, "BOTTOM", 0, -4)

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -4, -24)

-- the tab buttons across the top (GFoA: sized so all of them fit the narrowest window)
local SetBoard -- forward declaration
local tabs = {}
local TAB_W, TAB_STEP = 60, 63
for i, id in ipairs(BOARD_ORDER) do
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(TAB_W, 22)
    b:SetPoint("TOPLEFT", frame, "TOP", -(#BOARD_ORDER * TAB_STEP - (TAB_STEP - TAB_W)) / 2 + (i - 1) * TAB_STEP, -76)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(1, 1, 1, 1)
    b.fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.fs:SetPoint("CENTER")
    b.fs:SetText(BOARDS[id].label)
    b:SetScript("OnClick", function() SetBoard(id) end)
    tabs[id] = b
end

-- column headers: click a sortable header to sort; click again to flip high/low
local headerFS = {}
local function StaticHeader(text, x, w, justify)
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", x, -106)
    fs:SetWidth(w)
    fs:SetJustifyH(justify)
    fs:SetText(text)
    headerFS[#headerFS + 1] = fs
    return fs
end

local function StaticHeaderR(text, rightOffset, w)
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPRIGHT", frame, "TOPRIGHT", rightOffset, -106)
    fs:SetWidth(w)
    fs:SetJustifyH("RIGHT")
    fs:SetText(text)
    headerFS[#headerFS + 1] = fs
    return fs
end

local sortHeaders = {}
local function SortHeader(x, w, left) -- left: x from the frame's left edge, text left-aligned (GFoA)
    local h = {}
    h.btn = CreateFrame("Button", nil, frame)
    if left then
        h.btn:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -104)
    else
        h.btn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", x, -104)
    end
    h.btn:SetSize(w, 16)
    h.fs = h.btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h.fs:SetPoint(left and "LEFT" or "RIGHT", 0, 0)
    headerFS[#headerFS + 1] = h.fs
    h.arrow = h.btn:CreateTexture(nil, "OVERLAY")
    h.arrow:SetSize(9, 8)
    if left then
        h.arrow:SetPoint("LEFT", h.fs, "RIGHT", 3, 0)
    else
        h.arrow:SetPoint("RIGHT", h.fs, "LEFT", -3, 0)
    end
    h.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    h.arrow:Hide()
    h.btn:SetScript("OnClick", function()
        if sortKey == h.key then
            sortAsc = not sortAsc
        else
            sortKey = h.key
            sortAsc = false
        end
        Refresh()
    end)
    h.btn:SetScript("OnEnter", function() local c = Theme().text; h.fs:SetTextColor(c[1], c[2], c[3]) end)
    h.btn:SetScript("OnLeave", function() local c = Theme().header; h.fs:SetTextColor(c[1], c[2], c[3]) end)
    sortHeaders[#sortHeaders + 1] = h
    return h
end
local hdrRank = StaticHeader("#", 24, 24, "LEFT")
local hdrName = StaticHeader("Name", 70, 182, "LEFT")
local hdrDuel = StaticHeader("Duel", 28, 280, "LEFT")
local hdrWhen = StaticHeaderR("When", -108, 62)
local hdrRecord = StaticHeaderR("Record", -50, 52)
local hdrBet = StaticHeaderR("Bet", -180, 70)
SortHeader(-130, 70)  -- 1: weekly column
SortHeader(-50, 80)  -- 2: total column
SortHeader(-50, 160) -- 3: wide column (gold board)
-- GFoA Overall board: Class | Lvl | Name | Played | Professions | Top Hit
local hdrClass = StaticHeader("Class", 26, 34, "LEFT")
local hdrProfs = StaticHeaderR("Professions", -102, 124)
hdrProfs:SetJustifyH("LEFT")
local overallHeaders = {
    SortHeader(58, 40, true), -- level
    SortHeader(-234, 60),     -- played
    SortHeader(-46, 56),      -- top hit
}
overallHeaders[1].fs:SetText("Lvl")
overallHeaders[2].fs:SetText("Played")
overallHeaders[3].fs:SetText("Top Hit")

local scroll = CreateFrame("ScrollFrame", "GayFurriesLeaderboardScroll", frame, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 20, -124)
scroll:SetPoint("BOTTOMRIGHT", -34, 46)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(420, 1)
scroll:SetScrollChild(content)

-- theme dropdown, bottom left
local ApplyTheme -- forward declaration
local THEME_ORDER = { "gay", "straight", "cat", "blue", "berrii" }
local THEME_NAMES = { gay = "Gay Theme", straight = "Straight Theme", cat = "Cat Theme", blue = "Dog Theme", berrii = "Berrii Theme" }

local themeBtn = CreateFrame("Button", nil, frame)
themeBtn:SetSize(150, 22)
themeBtn:SetPoint("BOTTOMLEFT", 20, 14)
themeBtn.bg = themeBtn:CreateTexture(nil, "BACKGROUND")
themeBtn.bg:SetAllPoints()
themeBtn.bg:SetColorTexture(1, 1, 1, 1)
themeBtn.fs = themeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
themeBtn.fs:SetPoint("LEFT", 8, 0)
themeBtn.arrow = themeBtn:CreateTexture(nil, "OVERLAY")
themeBtn.arrow:SetSize(9, 8)
themeBtn.arrow:SetPoint("RIGHT", -8, 0)
themeBtn.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
themeBtn.arrow:SetTexCoord(0, 0.5625, 1, 0) -- points up: the list opens upward

local themeMenu = CreateFrame("Frame", nil, frame)
themeMenu:SetSize(150, #THEME_ORDER * 22 + 2)
themeMenu:SetPoint("BOTTOMLEFT", themeBtn, "TOPLEFT", 0, 2)
themeMenu:SetFrameLevel(frame:GetFrameLevel() + 30)
themeMenu.bg = themeMenu:CreateTexture(nil, "BACKGROUND")
themeMenu.bg:SetAllPoints()
themeMenu.bg:SetColorTexture(0, 0, 0, 1)
themeMenu.items = {}
for i, id in ipairs(THEME_ORDER) do
    local it = CreateFrame("Button", nil, themeMenu)
    it:SetSize(148, 22)
    it:SetPoint("TOPLEFT", 1, -(i - 1) * 22 - 1)
    it.bg = it:CreateTexture(nil, "BACKGROUND")
    it.bg:SetAllPoints()
    it.bg:SetColorTexture(1, 1, 1, 1)
    it.fs = it:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    it.fs:SetPoint("LEFT", 8, 0)
    it.fs:SetText(THEME_NAMES[id])
    it:SetScript("OnClick", function()
        if not db then return end
        db.theme = id
        themeMenu:Hide()
        ApplyTheme()
    end)
    themeMenu.items[id] = it
end
themeMenu:Hide()

themeBtn:SetScript("OnClick", function()
    if themeMenu:IsShown() then themeMenu:Hide() else themeMenu:Show() end
end)
frame:HookScript("OnHide", function() themeMenu:Hide() end)

local function UpdateThemeUI()
    local th = Theme()
    local cur = (db and db.theme) or "gay"
    themeBtn.bg:SetColorTexture(th.menuBg[1], th.menuBg[2], th.menuBg[3], th.menuBg[4])
    themeBtn.fs:SetText("Theme: " .. THEME_NAMES[cur]:gsub(" Theme", ""))
    themeBtn.fs:SetTextColor(th.tabTextOn[1], th.tabTextOn[2], th.tabTextOn[3])
    if cur == "gay" or cur == "blue" or cur == "berrii" then -- these need their own text color on the button
        themeBtn.fs:SetTextColor(th.text[1], th.text[2], th.text[3])
    end
    themeMenu.bg:SetColorTexture(th.border[1], th.border[2], th.border[3], 1)
    for id, it in pairs(themeMenu.items) do
        local on = (id == cur)
        local bg = on and th.tabOn or th.menuBg
        local tx = on and th.tabTextOn or th.tabTextOff
        it.bg:SetColorTexture(bg[1], bg[2], bg[3], 1)
        it.fs:SetTextColor(tx[1], tx[2], tx[3])
    end
end

-- "Hidden Mode" button, bottom right (gold board only)
local hideBtn = CreateFrame("Button", nil, frame)
hideBtn:SetSize(140, 22)
hideBtn:SetPoint("BOTTOMRIGHT", -32, 14)
hideBtn.bg = hideBtn:CreateTexture(nil, "BACKGROUND")
hideBtn.bg:SetAllPoints()
hideBtn.bg:SetColorTexture(1, 1, 1, 1)
hideBtn.fs = hideBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
hideBtn.fs:SetPoint("CENTER")

local function UpdateHideButton()
    local th = Theme()
    local hidden = db and db.shareGold == false
    local bg = hidden and th.tabOn or th.tabOff
    local tx = hidden and th.tabTextOn or th.tabTextOff
    hideBtn.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    hideBtn.fs:SetTextColor(tx[1], tx[2], tx[3])
    hideBtn.fs:SetText(hidden and "Hidden Mode: ON" or "Hidden Mode: OFF")
end

local emptyFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
emptyFS:SetPoint("CENTER", scroll, "CENTER", 0, 20)
emptyFS:SetWidth(300)
emptyFS:SetText("No guild duels yet.\nChallenge a guildmate!")
emptyFS:Hide()

local rowWidth = 420
local function LayoutRow(r)
    r:SetWidth(rowWidth)
    local function put(f, x, w)
        f:ClearAllPoints()
        f:SetPoint("LEFT", r, "LEFT", x, 0)
        if w then f:SetWidth(w) end
    end
    put(r.name, 52, rowWidth - 230)
    put(r.weekly, rowWidth - 170)
    put(r.total, rowWidth - 90)
    put(r.gold, rowWidth - 170)
    put(r.duel, 8, rowWidth - 140)
    put(r.when, rowWidth - 130)
    put(r.rec, rowWidth - 62, 52)
    put(r.bet, rowWidth - 210, 70)
    -- GFoA Overall board columns: hidden here, shown by RefreshOverall
    put(r.lvl, 38, 24)
    put(r.played, rowWidth - 250, 56)
    put(r.profs, rowWidth - 186, 124)
    put(r.hit, rowWidth - 58, 52)
    r.lvl:Hide(); r.played:Hide(); r.profs:Hide(); r.hit:Hide()
    r.icon:ClearAllPoints()
    r.icon:SetPoint("LEFT", 32, 0)
end

local rows = {}
local function GetRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, content)
    r:SetSize(420, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetSize(3, ROW_H - 2)
    r.bar:SetPoint("LEFT", 0, 0)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(14, 14)
    r.icon:SetPoint("LEFT", 32, 0)
    r.icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
    local function fs(x, w, j)
        local f = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f:SetPoint("LEFT", x, 0)
        f:SetWidth(w)
        f:SetJustifyH(j)
        return f
    end
    r.rank = fs(8, 24, "LEFT")
    r.name = fs(52, 190, "LEFT")
    if r.name.SetWordWrap then r.name:SetWordWrap(false) end
    r.weekly = fs(250, 70, "RIGHT")
    r.total = fs(330, 80, "RIGHT")
    r.gold = fs(250, 160, "RIGHT")
    -- duel log fields (outlined so class colors stay readable on any background)
    r.duel = fs(8, 280, "LEFT")
    r.when = fs(290, 62, "RIGHT")
    r.rec = fs(358, 52, "RIGHT")
    r.bet = fs(220, 70, "RIGHT")
    r.bet:Hide()
    -- GFoA Overall board fields
    r.lvl = fs(38, 24, "LEFT")
    r.played = fs(170, 56, "RIGHT")
    r.profs = fs(234, 124, "LEFT")
    r.hit = fs(362, 52, "RIGHT")
    if r.profs.SetWordWrap then r.profs:SetWordWrap(false) end
    if r.bet.SetWordWrap then r.bet:SetWordWrap(false) end
    if r.rec.SetWordWrap then r.rec:SetWordWrap(false) end
    if r.duel.SetWordWrap then r.duel:SetWordWrap(false) end
    local path, size = r.duel:GetFont()
    r.duel:SetFont(path, size, "OUTLINE")
    r.duel:Hide()
    r.when:Hide()
    r.rec:Hide()
    LayoutRow(r)
    rows[i] = r
    return r
end

local function ClassOf(name, fallback)
    local m = db.members[name]
    if m and m.class and m.class ~= "" then return m.class end
    return fallback or ""
end

local function RefreshDuels(th)
    local now = GetServerTime()
    local all = db.duels or {}
    local wins = {}
    for _, d in ipairs(all) do
        local k = d.w .. ">" .. d.l
        wins[k] = (wins[k] or 0) + 1
    end
    local duels = {}
    for _, d in ipairs(all) do duels[#duels + 1] = d end
    table.sort(duels, function(a, b) return a.t > b.t end)

    local n = math.min(#duels, 100)
    local textHex = Hex(th.text)
    for i = 1, n do
        local d = duels[i]
        local r = GetRow(i)
        LayoutRow(r)
        r.bet:Hide()
        local c = th.stripes[(i - 1) % 6 + 1]
        r.bar:SetColorTexture(c[1], c[2], c[3], 1)
        r.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and th.alt or 0)
        r.rank:Hide(); r.icon:Hide(); r.name:Hide()
        r.weekly:Hide(); r.total:Hide(); r.gold:Hide()
        r.duel:Show(); r.when:Show(); r.rec:Show()
        r.duel:SetText(ClassColored(d.w, ClassOf(d.w, d.wc)) .. " |cff" .. textHex .. "defeated|r "
            .. ClassColored(d.l, ClassOf(d.l, d.lc)))
        r.when:SetText(TimeAgo(math.max(0, now - d.t)))
        -- head-to-head record from the winner's point of view
        r.rec:SetText((wins[d.w .. ">" .. d.l] or 0) .. "-" .. (wins[d.l .. ">" .. d.w] or 0))
        r.when:SetTextColor(th.text[1], th.text[2], th.text[3])
        r.rec:SetTextColor(th.text[1], th.text[2], th.text[3])
        r:Show()
    end
    for i = n + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, n * ROW_H))
    if n == 0 then
        emptyFS:SetText("No guild duels yet.\nChallenge a guildmate!")
        emptyFS:SetTextColor(th.header[1], th.header[2], th.header[3])
        emptyFS:Show()
    else
        emptyFS:Hide()
    end
    for _, h in ipairs(sortHeaders) do h.arrow:Hide() end
end

local function RefreshRolls(th)
    local now = GetServerTime()
    local all = db.rolls or {}
    local h2h = {} -- total gold won by x against y
    for _, d in ipairs(all) do
        local k = d.w .. ">" .. d.l
        h2h[k] = (h2h[k] or 0) + (d.bet or 0)
    end
    local list = {}
    for _, d in ipairs(all) do list[#list + 1] = d end
    table.sort(list, function(a, b) return a.t > b.t end)

    local n = math.min(#list, 150)
    local textHex = Hex(th.text)
    for i = 1, n do
        local d = list[i]
        local r = GetRow(i)
        LayoutRow(r)
        r.duel:SetWidth(math.max(60, rowWidth - 222))
        r.rec:ClearAllPoints(); r.rec:SetPoint("LEFT", r, "LEFT", rowWidth - 66, 0); r.rec:SetWidth(56)
        local c = th.stripes[(i - 1) % 6 + 1]
        r.bar:SetColorTexture(c[1], c[2], c[3], 1)
        r.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and th.alt or 0)
        r.rank:Hide(); r.icon:Hide(); r.name:Hide()
        r.weekly:Hide(); r.total:Hide(); r.gold:Hide()
        r.duel:Show(); r.when:Show(); r.rec:Show(); r.bet:Show()
        r.duel:SetText(ClassColored(d.w, ClassOf(d.w, d.wc)) .. " |cff" .. textHex .. "beat|r "
            .. ClassColored(d.l, ClassOf(d.l, d.lc)))
        r.bet:SetText(d.bet and ShortMoney(d.bet) or "?")
        r.when:SetText(TimeAgo(math.max(0, now - d.t)))
        -- how much the winner is up (or down) overall against this opponent
        r.rec:SetText(NetText((h2h[d.w .. ">" .. d.l] or 0) - (h2h[d.l .. ">" .. d.w] or 0)))
        r.bet:SetTextColor(th.text[1], th.text[2], th.text[3])
        r.when:SetTextColor(th.text[1], th.text[2], th.text[3])
        r.rec:SetTextColor(th.text[1], th.text[2], th.text[3])
        r:Show()
    end
    for i = n + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, n * ROW_H))
    if n == 0 then
        emptyFS:SetText("No guild deathrolls yet.\nDeathroll a guildmate, then trade\nthe winner the bet!")
        emptyFS:SetTextColor(th.header[1], th.header[2], th.header[3])
        emptyFS:Show()
    else
        emptyFS:Hide()
    end
    for _, h in ipairs(sortHeaders) do h.arrow:Hide() end
end

-- per-player deathroll totals for the rankings tab
local function RollStats()
    local stats = {}
    local function get(name, class)
        local e = stats[name]
        if not e then e = { name = name, class = "", wins = 0, losses = 0, net = 0 }; stats[name] = e end
        if class and class ~= "" then e.class = class end
        return e
    end
    for _, d in ipairs(db.rolls or {}) do
        local w, l = get(d.w, d.wc), get(d.l, d.lc)
        w.wins = w.wins + 1; w.net = w.net + (d.bet or 0)
        l.losses = l.losses + 1; l.net = l.net - (d.bet or 0)
    end
    local list = {}
    for _, e in pairs(stats) do
        local m = db.members[e.name]
        if m and m.class and m.class ~= "" then e.class = m.class end
        list[#list + 1] = e
    end
    return list
end

-- GFoA: Overall board helpers
local function PlayedText(sec)
    if type(sec) ~= "number" or sec < 0 then return "?" end
    local d, h, m = math.floor(sec / 86400), math.floor(sec % 86400 / 3600), math.floor(sec % 3600 / 60)
    if d > 0 then return d .. "d " .. h .. "h" end
    if h > 0 then return h .. "h " .. m .. "m" end
    return m .. "m"
end

local function SetProfText(f, p1, p2)
    local function join(a, b)
        if a ~= "" and b ~= "" then return a .. " / " .. b end
        return (a ~= "" and a) or b
    end
    local full = join(p1, p2)
    if full == "" then f:SetText("-"); return end
    f:SetText(full)
    if f:GetStringWidth() > f:GetWidth() - 2 then f:SetText(join(PROF_SHORT[p1] or p1, PROF_SHORT[p2] or p2)) end
end

local function RefreshOverall(th, straight)
    emptyFS:Hide()
    db.overall = db.overall or {}
    local list = {}
    for name, m in pairs(db.members) do
        local o = db.overall[name] or {} -- guildmates on an older version: "?" until they update
        list[#list + 1] = {
            name = name, class = m.class, level = o.level or -1, played = o.played or -1, hit = o.hit or -1,
            p1 = o.p1 or "", p2 = o.p2 or "",
        }
    end
    table.sort(list, function(a, b)
        if a[sortKey] ~= b[sortKey] then
            if sortAsc then return a[sortKey] < b[sortKey] end
            return a[sortKey] > b[sortKey]
        end
        return a.name < b.name
    end)
    for i, e in ipairs(list) do
        local r = GetRow(i)
        local c = th.stripes[(i - 1) % 6 + 1]
        r.bar:SetColorTexture(c[1], c[2], c[3], 1)
        r.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and th.alt or 0)
        LayoutRow(r)
        r.duel:Hide(); r.when:Hide(); r.rec:Hide(); r.bet:Hide()
        r.rank:Hide(); r.weekly:Hide(); r.total:Hide(); r.gold:Hide()
        r.icon:ClearAllPoints()
        r.icon:SetPoint("LEFT", 12, 0)
        local tc = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[e.class]
        if tc then
            r.icon:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
            r.icon:Show()
        else
            r.icon:Hide()
        end
        r.name:ClearAllPoints()
        r.name:SetPoint("LEFT", r, "LEFT", 66, 0)
        r.name:SetWidth(math.max(60, rowWidth - 66 - 254))
        r.name:Show()
        if straight then
            r.name:SetText(e.name)
        else
            r.name:SetText("|cff" .. th.prefix .. (CUTE[i] or CUTE_FALLBACK) .. "|r " .. e.name)
            if r.name:GetStringWidth() > (r.name:GetWidth() - 2) then r.name:SetText(e.name) end
        end
        r.lvl:SetText(e.level > 0 and tostring(e.level) or "?")
        r.played:SetText(PlayedText(e.played))
        SetProfText(r.profs, e.p1, e.p2)
        r.hit:SetText(e.hit > 0 and tostring(e.hit) or (e.hit == 0 and "-" or "?"))
        for _, f in ipairs({ r.name, r.lvl, r.played, r.profs, r.hit }) do
            f:SetTextColor(th.text[1], th.text[2], th.text[3])
            f:Show()
        end
        r:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, #list * ROW_H))
    if #list == 0 then
        emptyFS:SetText("No guildmates yet.\nThey show up once their\naddon sends its stats.")
        emptyFS:SetTextColor(th.header[1], th.header[2], th.header[3])
        emptyFS:Show()
    end
    for _, h in ipairs(sortHeaders) do
        if h.btn:IsShown() and h.key == sortKey then
            h.arrow:Show()
            h.arrow:SetTexCoord(0, 0.5625, sortAsc and 1 or 0, sortAsc and 0 or 1)
        else
            h.arrow:Hide()
        end
    end
end

function Refresh()
    if not frame:IsShown() or not db then return end
    local th = Theme()
    local straight = (db.theme == "straight")
    if board == "duels" then
        RefreshDuels(th)
        return
    elseif board == "rolls" then
        RefreshRolls(th)
        return
    elseif board == "overall" then
        RefreshOverall(th, straight)
        return
    end
    emptyFS:Hide()
    local wk = CurrentWeekId()
    local list = {}
    if board == "rollrank" then
        list = RollStats()
        if #list == 0 then
            emptyFS:SetText("No guild deathrolls yet.\nDeathroll a guildmate, then trade\nthe winner the bet!")
            emptyFS:SetTextColor(th.header[1], th.header[2], th.header[3])
            emptyFS:Show()
        end
    else
    for name, m in pairs(db.members) do
        local cur = (m.week == wk) -- a stale week counts as 0
        local season = (m.ks == KILLS_SEASON) -- GFoA: kills from an older kill season or version count as 0
        list[#list + 1] = {
            name = name, class = m.class,
            total = season and (m.total or 0) or 0, weekly = (season and cur) and (m.weekly or 0) or 0,
            dTotal = m.dTotal or 0, dWeekly = cur and (m.dWeekly or 0) or 0,
            gold = m.gold or -1,
        }
    end
    end
    table.sort(list, function(a, b)
        if a[sortKey] ~= b[sortKey] then
            if sortAsc then return a[sortKey] < b[sortKey] end
            return a[sortKey] > b[sortKey]
        end
        return a.name < b.name
    end)

    local cfg = BOARDS[board]
    for i, e in ipairs(list) do
        local r = GetRow(i)
        local c = th.stripes[(i - 1) % 6 + 1]
        r.bar:SetColorTexture(c[1], c[2], c[3], 1)
        r.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and th.alt or 0)
        LayoutRow(r)
        r.duel:Hide(); r.when:Hide(); r.rec:Hide(); r.bet:Hide()
        r.rank:Show(); r.name:Show()
        r.rank:SetText(i)
        local tc = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[e.class]
        if tc then
            r.icon:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
            r.icon:Show()
        else
            r.icon:Hide() -- class unknown (e.g. older saved data)
        end
        if straight then
            r.name:SetText(e.name)
        else
            r.name:SetText("|cff" .. th.prefix .. (CUTE[i] or CUTE_FALLBACK) .. "|r " .. e.name)
            if r.name:GetStringWidth() > (r.name:GetWidth() - 2) then r.name:SetText(e.name) end -- long names: drop the cute prefix
        end

        if board == "gold" then
            r.weekly:Hide()
            r.total:Hide()
            r.gold:Show()
            r.gold:SetText(FormatMoney(e.gold))
        elseif board == "rollrank" then
            r.gold:Hide()
            r.weekly:Show()
            r.total:Show()
            r.weekly:SetText(e.wins .. "-" .. e.losses)
            r.total:SetText(NetText(e.net))
        else
            r.gold:Hide()
            r.weekly:Show()
            r.total:Show()
            r.weekly:SetText(e[cfg.cols[1].key])
            r.total:SetText(e[cfg.cols[2].key])
        end
        for _, f in ipairs({ r.rank, r.name, r.weekly, r.total, r.gold }) do
            f:SetTextColor(th.text[1], th.text[2], th.text[3])
        end
        r:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, #list * ROW_H))

    for _, h in ipairs(sortHeaders) do
        if h.btn:IsShown() and h.key == sortKey then
            h.arrow:Show()
            if sortAsc then
                h.arrow:SetTexCoord(0, 0.5625, 1, 0) -- pointing up: lowest first
            else
                h.arrow:SetTexCoord(0, 0.5625, 0, 1) -- pointing down: highest first
            end
        else
            h.arrow:Hide()
        end
    end
end

-- set up the column headers and subtitle for the current board
local function ConfigureBoard()
    local cfg = BOARDS[board]
    local isRolls = (board == "rolls")
    local isLog = (board == "duels") or isRolls
    for _, h in ipairs(sortHeaders) do h.btn:Hide() end
    hdrClass:Hide(); hdrProfs:Hide() -- GFoA Overall board headers
    hdrName:ClearAllPoints()
    hdrName:SetPoint("TOPLEFT", board == "overall" and 86 or 70, -106)
    if isLog then
        hdrRank:Hide(); hdrName:Hide()
        hdrDuel:SetText(isRolls and "Deathroll" or "Duel")
        hdrRecord:SetText(isRolls and "Net vs." or "Record")
        hdrRecord:SetWidth(isRolls and 70 or 52)
        hdrDuel:Show(); hdrWhen:Show(); hdrRecord:Show()
        if isRolls then hdrBet:Show() else hdrBet:Hide() end
    else
        hdrRank:Show(); hdrName:Show()
        hdrDuel:Hide(); hdrWhen:Hide(); hdrRecord:Hide(); hdrBet:Hide()
        if board == "overall" then
            hdrRank:Hide(); hdrClass:Show(); hdrProfs:Show()
            for i, key in ipairs({ "level", "played", "hit" }) do
                overallHeaders[i].key = key
                overallHeaders[i].btn:Show()
            end
        elseif board == "gold" then
            local h = sortHeaders[3]
            h.key = "gold"
            h.fs:SetText("Total Wealth")
            h.btn:Show()
        else
            for i = 1, 2 do
                local h = sortHeaders[i]
                h.key = cfg.cols[i].key
                h.fs:SetText(cfg.cols[i].label)
                h.btn:Show()
            end
        end
    end
    subtitle:SetText(cfg.subtitle)
    if board == "gold" then hideBtn:Show() else hideBtn:Hide() end
    UpdateHideButton()
end

local function UpdateTabs()
    local th = Theme()
    for id, b in pairs(tabs) do
        local on = (id == board)
        local bg = on and th.tabOn or th.tabOff
        local tx = on and th.tabTextOn or th.tabTextOff
        b.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
        b.fs:SetTextColor(tx[1], tx[2], tx[3])
    end
end

function ApplyTheme()
    local th = Theme()
    local mode = (db and db.theme) or "gay"
    local straight = (mode == "straight")
    local cat = (mode == "cat")

    frame:SetBackdrop(straight and BD_STRAIGHT or ((mode == "berrii") and BD_BERRII or BD_GAY))
    frame:SetBackdropColor(th.bg[1], th.bg[2], th.bg[3], th.bg[4])
    frame:SetBackdropBorderColor(th.border[1], th.border[2], th.border[3], th.border[4])
    for i, t in ipairs(stripeTex) do
        local c = th.stripes[i]
        t:SetColorTexture(c[1], c[2], c[3], 1)
        if straight then t:Hide() else t:Show() end
    end

    if straight or mode == "berrii" then
        unicorn:Hide()
    else
        unicorn:SetTexture(THEME_ART[mode] or UNICORN_ART)
        unicorn:Show()
    end
    ShowBerrii(mode == "berrii")

    title:ClearAllPoints()
    subtitle:ClearAllPoints()
    close:ClearAllPoints()
    title:SetShadowColor(th.shadow[1], th.shadow[2], th.shadow[3], th.shadow[4])
    title:SetShadowOffset(1, -1)
    if straight then
        plaque:Show()
        title:SetFontObject(GameFontNormal)
        title:SetPoint("TOP", frame, "TOP", 0, -2)
        title:SetText("Straight Furries of Azeroth")
        title:SetTextColor(0.95, 0.95, 0.95)
        subtitle:SetPoint("TOP", frame, "TOP", 0, -50)
        close:SetPoint("TOPRIGHT", -6, -6)
    else
        plaque:Hide()
        title:SetFontObject(GameFontNormalLarge)
        title:SetPoint("TOP", 0, -34)
        title:SetText(RainbowText("Gay Furries of Azeroth", THEME_TITLE_HEX[mode]))
        subtitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
        close:SetPoint("TOPRIGHT", -4, -24)
    end
    subtitle:SetTextColor(th.sub[1], th.sub[2], th.sub[3])
    for _, fs in ipairs(headerFS) do
        fs:SetTextColor(th.header[1], th.header[2], th.header[3])
    end

    UpdateThemeUI()
    local gt = grip:GetNormalTexture()
    if gt then gt:SetVertexColor(th.header[1], th.header[2], th.header[3]) end

    UpdateTabs()
    UpdateHideButton()
    Refresh()
end

function SetBoard(id)
    board = id
    sortKey = BOARDS[id].defaultSort
    sortAsc = false
    ConfigureBoard()
    UpdateTabs()
    Refresh()
end

hideBtn:SetScript("OnClick", function()
    if not db then return end
    db.shareGold = (db.shareGold == false) -- nil/true -> hidden, false -> shared
    UpdateHideButton()
    Broadcast()
end)
hideBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Hidden Mode")
    GameTooltip:AddLine("When ON, guildmates see \"Hidden\" instead of your gold.", 1, 1, 1, true)
    GameTooltip:Show()
end)
hideBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

frame:SetScript("OnSizeChanged", function(_, w)
    rowWidth = w - 60
    content:SetWidth(rowWidth)
    hdrDuel:SetWidth(math.max(100, w - 200))
    for _, r in ipairs(rows) do LayoutRow(r) end
    if db and db.theme == "berrii" then LayoutBerrii() end
    Refresh()
end)

frame:SetScript("OnShow", function()
    if ready and IsInGuild() then SendAddonMessage(PREFIX, "REQ", "GUILD") end
    Refresh()
end)

ConfigureBoard()

local function ToggleBoard()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

---------------------------------------------------------------------
-- Minimap button (drag it around the minimap edge)
---------------------------------------------------------------------
local mini = CreateFrame("Button", "GayFurriesLeaderboardMinimapButton", Minimap)
mini:SetSize(31, 31)
mini:SetFrameStrata("MEDIUM")
mini:SetFrameLevel(8)
mini:RegisterForClicks("LeftButtonUp")
mini:RegisterForDrag("LeftButton")
mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local miniIcon = mini:CreateTexture(nil, "BACKGROUND")
miniIcon:SetSize(22, 22)
miniIcon:SetPoint("CENTER", 0, 1)
miniIcon:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

local miniText = mini:CreateFontString(nil, "OVERLAY")
miniText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
miniText:SetPoint("CENTER", 0, 1)
miniText:SetText("|cffFFADADG|r|cffFDFFB6A|r|cff9BF6FFY|r")

local miniBorder = mini:CreateTexture(nil, "OVERLAY")
miniBorder:SetSize(53, 53)
miniBorder:SetPoint("TOPLEFT")
miniBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local function PlaceMini()
    local a = math.rad((db and db.miniAngle) or 200)
    local r = Minimap:GetWidth() / 2 + 5
    mini:ClearAllPoints()
    mini:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

mini:SetScript("OnClick", ToggleBoard)
mini:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local s = Minimap:GetEffectiveScale()
        db.miniAngle = math.deg(math.atan2(cy / s - my, cx / s - mx))
        PlaceMini()
    end)
end)
mini:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
mini:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(RainbowText("Gay Furries of Azeroth", true))
    GameTooltip:AddLine("PvP, Death and Gold Leaderboards", 1, 0.75, 0.9)
    GameTooltip:AddLine("Click to open or close", 1, 1, 1)
    GameTooltip:AddLine("Drag to move this icon", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
PlaceMini()

---------------------------------------------------------------------
-- Honorable-kill chat line (fallback kill counter; the combat log is off limits to addons here)
---------------------------------------------------------------------
local honorPattern
local honorLines = 0 -- honorable-kill chat lines seen this session (for /gpvp debug)
local function IsHonorKillMessage(msg)
    if type(msg) ~= "string" then return false end
    if honorPattern == nil then
        honorPattern = false
        if type(COMBATLOG_HONORGAIN) == "string" then
            local p = COMBATLOG_HONORGAIN:gsub("%%%d*%$?[sd]", "\1")
            p = p:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
            p = p:gsub("\1", ".+")
            honorPattern = "^" .. p .. "$"
        end
    end
    if honorPattern and msg:find(honorPattern) then return true end
    if msg:find("dishonorable", 1, true) then return false end -- GFoA fix: "dishonorable kill" contains "honorable kill"
    return msg:find("honorable kill", 1, true) ~= nil
end

---------------------------------------------------------------------
-- Events
---------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("PLAYER_DEAD")
ev:RegisterEvent("PLAYER_MONEY")
ev:RegisterEvent("CHAT_MSG_SYSTEM")
ev:RegisterEvent("GUILD_ROSTER_UPDATE")

-- GFoA Top Hit, main source: the game's own Combat Log chat tab. Addons can't read the combat log on this client,
-- but its tab prints it, and lines starting "Your ..." are always your own hits, in any content (solo, group, raid):
--   "Your Eviscerate hit Twilight Neophyte 303 Physical."  "Your Melee hit Twilight Neophyte 40 Physical."
--   "Your Sinister Strike hit Twilight Neophyte 10 Physical. (111 Overkill)"
-- The shown amount leaves out the overkill, so the full hit is the two added up (121 there).
local combatLogLines = "none seen yet" -- for /gpvp debug: "readable", "secret (hidden from addons)", "none seen yet"
local combatLogSeen = false           -- a hit was read from the tab: the solo-only UNIT_COMBAT source is ignored

local function RecordHit(amount)
    if not db or type(amount) ~= "number" or amount <= 0 then return end
    local c = Char()
    if amount > (c.topHit or 0) then
        c.topHit = amount
        if ready then ScheduleBroadcast() end
    end
end

local function PlainText(t)
    t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    t = t:gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", ""):gsub("|A.-|a", "")
    return t
end

local LOG_VERBS = { "hit", "hits", "crit", "crits" }
local function CombatLogHitAmount(text)
    if type(text) ~= "string" then return nil end
    if issecretvalue and issecretvalue(text) then combatLogLines = "secret (hidden from addons)"; return nil end
    combatLogLines = "readable"
    if not text:find("You", 1, true) then return nil end -- cheap skip: only "Your ..." / "You ..." lines are yours
    local t = PlainText(text):gsub("^[%d/:%.%s]+", "") -- an optional timestamp
    t = t:gsub("[%[%]]", "")                         -- optional [brackets] around names
    for _, verb in ipairs(LOG_VERBS) do
        local target, amount = t:match("^Your .- " .. verb .. " (.-) (%d+)")
        if not amount then target, amount = t:match("^You " .. verb .. " (.-) (%d+)") end
        if amount and target ~= "you" and target ~= "yourself" then
            return tonumber(amount) + (tonumber(t:match("%((%d+) [Oo]verkill%)")) or 0)
        end
    end
    return nil
end

local hookedCombatLog = false
local function HookCombatLog()
    local f = _G.COMBATLOG -- set by the game's Blizzard_CombatLog to the Combat Log tab's chat frame
    if type(f) ~= "table" and GetChatWindowInfo then -- else the chat tab named "Combat Log"
        for i = 1, (NUM_CHAT_WINDOWS or 10) do
            local name = GetChatWindowInfo(i)
            if name and (name == (COMBAT_LOG or "Combat Log") or name == "Combat Log") then f = _G["ChatFrame" .. i]; break end
        end
    end
    if hookedCombatLog or type(f) ~= "table" or type(f.AddMessage) ~= "function" or not hooksecurefunc then return end
    hookedCombatLog = true
    hooksecurefunc(f, "AddMessage", function(_, text)
        local amount = CombatLogHitAmount(text)
        if amount then
            combatLogSeen = true
            RecordHit(amount)
        end
    end)
end

-- these may not exist on every client; don't error if they don't
pcall(ev.RegisterEvent, ev, "PLAYER_PVP_KILLS_CHANGED")
pcall(ev.RegisterEvent, ev, "CHAT_MSG_COMBAT_HONOR_GAIN")
pcall(ev.RegisterEvent, ev, "ZONE_CHANGED_NEW_AREA")
-- GFoA Overall board
for _, e in ipairs({ "CHAT_MSG_COMBAT_SELF_HITS", "CHAT_MSG_SPELL_SELF_DAMAGE" }) do
    if pcall(ev.RegisterEvent, ev, e) and (not ev.IsEventRegistered or ev:IsEventRegistered(e)) then
        hitEvents = hitEvents + 1
    end
end
-- only the target's UNIT_COMBAT is used: where the client can, don't wake up for every party/raid member's
if not (ev.RegisterUnitEvent and pcall(ev.RegisterUnitEvent, ev, "UNIT_COMBAT", "target")) then
    pcall(ev.RegisterEvent, ev, "UNIT_COMBAT")
end
pcall(ev.RegisterEvent, ev, "TIME_PLAYED_MSG")
pcall(ev.RegisterEvent, ev, "PLAYER_LOGOUT")
pcall(ev.RegisterEvent, ev, "PLAYER_LEVEL_UP")
pcall(ev.RegisterEvent, ev, "TRADE_SHOW")
pcall(ev.RegisterEvent, ev, "TRADE_ACCEPT_UPDATE")
pcall(ev.RegisterEvent, ev, "TRADE_CLOSED")

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == "Blizzard_CombatLog" then HookCombatLog(); return end -- GFoA Top Hit
        if ... ~= "GayFurriesLeaderboard" then return end
        GayFurriesLeaderboardDB = GayFurriesLeaderboardDB or {}
        db = GayFurriesLeaderboardDB
        db.members = db.members or {}
        db.overall = db.overall or {} -- GFoA: Overall board lines, by name
        db.source = db.source or "api"
        db.killSeason = KILLS_SEASON -- GFoA: read by GFoA Guild Sync's Leaderboards view (zeroes older seasons)
        -- GFoA: db.deaths is no longer defaulted here; deaths are per character in db.chars (see Char())
        if not db.theme then -- migrate from the old toggles
            db.theme = db.straight and "straight" or (db.cat and "cat" or "gay")
        end
        if not THEMES[db.theme] or db.theme == "kyy" then db.theme = "gay" end -- the removed Kyy theme
        if RegisterPrefix then RegisterPrefix(PREFIX) end
        if db.width and db.height then frame:SetSize(db.width, db.height) end
        PlaceMini()
        ApplyTheme()

    elseif event == "PLAYER_ENTERING_WORLD" then
        HookCombatLog() -- GFoA Top Hit (if the Combat Log tab loaded before this addon)
        SyncKills(true) -- GFoA: kills read now belong to the zone we left (entering or leaving a BG)
        if db and not playedSession then -- GFoA: played time counts again from this login
            playedSession = true
            local c = Char()
            if c.played then c.playedAt = time() end
        end
        -- wait a moment so honor stats and money are loaded before the first snapshot
        C_Timer.After(5, function()
            if ready then return end
            ready = true
            Broadcast()
            if IsInGuild() then SendAddonMessage(PREFIX, "REQ", "GUILD") end
            RequestRoster()
            C_Timer.After(3, RebuildGuildSet)
            C_Timer.NewTicker(300, function() RequestRoster(); Broadcast() end)
            C_Timer.NewTicker(30, function() -- keep the "x minutes ago" column fresh
                if board == "duels" or board == "rolls" then Refresh() end
            end)
        end)

    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)

    elseif event == "CHAT_MSG_SYSTEM" then
        OnSystemMessage(...)
        OnRollMessage((...))
        OnTradeSystemMessage((...))

    elseif event == "TRADE_SHOW" or event == "TRADE_ACCEPT_UPDATE" or event == "TRADE_CLOSED" then
        OnTradeEvent(event, ...)

    elseif event == "GUILD_ROSTER_UPDATE" then
        local now = GetTime()
        if now - lastRoster > 5 then
            lastRoster = now
            RebuildGuildSet()
        end

    elseif event == "PLAYER_DEAD" then
        if not db then return end
        local c = Char() -- GFoA: per character
        c.deaths = (c.deaths or 0) + 1
        if ready then ScheduleBroadcast() end

    elseif event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
        -- the "X dies, honorable kill" chat line: used for the fallback kill counter
        if db and IsHonorKillMessage((...)) then
            local c = Char() -- GFoA: per character
            c.logKills = (c.logKills or 0) + 1
            if not InBattleground() then c.logWorld = (c.logWorld or 0) + 1 end -- GFoA: world PvP only
            KillFromLog(c, KillCounts()) -- GFoA: the board's count (once per kill, see KillFromApi)
            honorLines = honorLines + 1
        end
        SyncKills()
        if ready then ScheduleBroadcast() end

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        SyncKills(true)

    elseif event == "CHAT_MSG_COMBAT_SELF_HITS" or event == "CHAT_MSG_SPELL_SELF_DAMAGE" or event == "UNIT_COMBAT" then
        -- GFoA: highest single hit for the Overall board
        if not db then return end
        local amount
        if event == "UNIT_COMBAT" then
            local unit, action, _, dmg = ...
            amount = TargetHitAmount(unit, action, dmg)
            if combatLogSeen then amount = nil end -- the Combat Log tab is the better source when it works
        else
            amount = HitAmount((...))
        end
        if amount then
            local c = Char()
            if amount > (c.topHit or 0) then
                c.topHit = amount
                if ready then ScheduleBroadcast() end
            end
        end

    elseif event == "TIME_PLAYED_MSG" then
        -- GFoA: /played (typed by the player) gives the Overall board's played time
        local total = ...
        if db and type(total) == "number" then
            local c = Char()
            c.played, c.playedAt = math.floor(total), time()
            if ready then ScheduleBroadcast() end
        end

    elseif event == "PLAYER_LOGOUT" then
        if db then -- GFoA: fold this session's online time into the played time
            local c = Char()
            local p = PlayedNow(c)
            if p then c.played = math.floor(p) end
            c.playedAt = nil
        end

    elseif event == "PLAYER_LEVEL_UP" then
        if ready then ScheduleBroadcast() end

    else -- PLAYER_MONEY / PLAYER_PVP_KILLS_CHANGED
        if event == "PLAYER_PVP_KILLS_CHANGED" then SyncKills() end
        if ready then ScheduleBroadcast() end
    end
end)

---------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------
SLASH_GUILDPVPBOARD1 = "/gpvp"
SLASH_GUILDPVPBOARD2 = "/pvplb"
SLASH_GUILDPVPBOARD3 = "/gayleaderboard"
SLASH_GUILDPVPBOARD4 = "/gayfurries"
SlashCmdList["GUILDPVPBOARD"] = function(msg)
    msg = (msg or ""):lower()
    if msg == "reset" then
        db.members = {}
        local c = Char() -- GFoA: re-baselines this character's weeks only; the other characters keep theirs
        c.weekBase = nil
        c.dWeekBase = nil
        print("|cff33ff99GayFurriesLeaderboard:|r data cleared.")
        Broadcast()
    elseif msg == "debug" then
        local api = ApiLifetimeKills()
        local c = Char() -- GFoA: this character's counters
        print("|cff33ff99GayFurriesLeaderboard debug|r")
        print("  my full name:", MyName(), "| UnitName:", tostring((UnitName("player"))), "second value:", tostring((select(2, UnitName("player")))))
        print("  GetPVPLifetimeStats exists:", GetPVPLifetimeStats ~= nil, "value:", tostring(api))
        print("  kills counted from honor messages:", c.logKills or 0, "outside BGs:", c.logWorld or 0)
        print("  world PvP kills (no BGs):", c.worldKills or 0, "| in a BG now:", tostring(InBattleground()))
        print("  source in use:", db.source)
        print("  deaths counted:", c.deaths or 0, "weekly base:", tostring(c.dWeekBase))
        print("  sharing gold:", tostring(db.shareGold ~= false))
        local profs = ReadMainProfessions() or c.profs or {}
        print("  overall: level", tostring(UnitLevel("player")), "| played", PlayedText(PlayedNow(c) or -1),
            "| professions", (profs[1] or "-") .. " / " .. (profs[2] or "-") .. " (from " .. profSource .. ")", "| top hit", c.topHit or 0,
            "| combat log tab", combatLogLines .. (hookedCombatLog and "" or " (tab not found)"),
            "| combat chat events", hitEvents .. "/2", "| target damage", targetDamage)
        local gs = 0
        for _ in pairs(guildSet) do gs = gs + 1 end
        print("  duels saved:", #(db.duels or {}), "deathrolls saved:", #(db.rolls or {}), "guild roster names known:", gs)
        print("  week id:", CurrentWeekId(), "kill week base:", tostring(c.weekBase))
        print("  kill season:", KILLS_SEASON, "kept kills:", tostring(c.keptKills), "season kills (no BGs, no raid groups):", c.seasonKills or 0,
            "| in a raid group now:", tostring(InRaidGroup()))
        print("  kill signals: lifetime count", tostring(ApiLifetimeKills()), "| honor lines this session", honorLines,
            "| pending: chat", c.logPending or 0, "lifetime", c.apiPending or 0)
    elseif msg == "source api" or msg == "source log" then
        db.source = msg:match("source (%a+)")
        print("|cff33ff99GayFurriesLeaderboard:|r kill source set to", db.source,
            "(debug only: the board always counts honorable-kill messages outside BGs and raid groups)")
    elseif msg == "clearduels" then
        db.duels = {}
        print("|cff33ff99GayFurriesLeaderboard:|r duel log cleared.")
        Refresh()
    elseif msg == "clearrolls" then
        db.rolls = {}
        print("|cff33ff99GayFurriesLeaderboard:|r deathroll history cleared.")
        Refresh()
    elseif msg == "gold off" or msg == "gold on" then
        db.shareGold = (msg == "gold on")
        print("|cff33ff99GayFurriesLeaderboard:|r gold sharing is now", db.shareGold and "ON" or "OFF (guildmates see Hidden)")
        UpdateHideButton()
        Broadcast()
    else
        ToggleBoard()
    end
end
