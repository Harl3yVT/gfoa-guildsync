-- GFoA Guild Sync: guild roster snapshot.
local _, ns = ...

local lastScan = 0
local lastRequest = 0
local restoreOffline = false

-- Puts the player's "Show Offline Members" setting back if we turned it on.
local function restoreShowOffline()
  if restoreOffline then
    restoreOffline = false
    ns.call("SetGuildRosterShowOffline", false)
  end
end

-- true while the player is looking at a Blizzard guild list (then their filter is left exactly as it is).
local function guildListOpen()
  for _, fname in ipairs({ "GuildFrame", "CommunitiesFrame" }) do
    local f = _G[fname]
    if f and f.IsVisible and f:IsVisible() then return true end
  end
  return false
end

local function requestRoster()
  local t = ns.now()
  if t - lastRequest < 10 then return end   -- the server throttles faster requests anyway
  lastRequest = t
  -- Offline members are only listed while "Show Offline Members" is on; turn it on for the scan and
  -- put the player's setting back right after (at the latest 30 s later, even if no scan happens).
  if ns.api("GetGuildRosterShowOffline") and ns.api("SetGuildRosterShowOffline") and not guildListOpen() then
    if not ns.call("GetGuildRosterShowOffline") then
      ns.call("SetGuildRosterShowOffline", true)
      restoreOffline = true
      ns.after(30, "rosterRestoreOffline", restoreShowOffline)
    end
  end
  if ns.api("C_GuildInfo.GuildRoster") then
    ns.call("C_GuildInfo.GuildRoster")
  else
    ns.call("GuildRoster")
  end
end

local function lastOnlineDays(i, online)
  if online then return 0.0 end
  if not ns.api("GetGuildRosterLastOnline") then return nil end
  local years, months, days, hours = ns.call("GetGuildRosterLastOnline", i)
  if not (years or months or days or hours) then return nil end
  local d = (years or 0) * 365 + (months or 0) * 30 + (days or 0) + (hours or 0) / 24
  return math.floor(d * 10 + 0.5) / 10
end

local function scan()
  local inGuild = ns.call("IsInGuild")
  if not inGuild then return end
  local guildName = ns.call("GetGuildInfo", "player")
  if not guildName then return end   -- guild info not loaded yet
  local total = ns.call("GetNumGuildMembers")
  if not total or total == 0 then return end
  local canOfficer = false   -- never assume officer permissions
  if ns.api("C_GuildInfo.CanViewOfficerNote") then
    canOfficer = ns.call("C_GuildInfo.CanViewOfficerNote") and true or false
  elseif ns.api("CanViewOfficerNote") then
    canOfficer = ns.call("CanViewOfficerNote") and true or false
  end

  local members = {}
  for i = 1, total do
    local name, rank, rankIndex, level, _, zone, note, officerNote, online, _, classFile =
      ns.call("GetGuildRosterInfo", i)
    if name then
      local _, realm = ns.logic.splitName(name)
      local m = {
        name = ns.shortName(name),
        fullName = string.match(string.match(name, "^([^%-]*)") or name, "^%s*(.-)%s*$"),
        realm = realm,
        level = level,
        class = classFile,
        rank = rank,
        rankIndex = rankIndex,
        zone = zone,
        note = note or "",
        online = online and true or false,
        lastOnlineDays = lastOnlineDays(i, online),
      }
      -- Leave officerNote out (not "") when this character can't read officer notes,
      -- so it is not read as a cleared note.
      if canOfficer then m.officerNote = officerNote or "" end
      table.insert(members, m)
    end
  end

  restoreShowOffline()

  if #members == 0 then return end
  -- Pick each own-realm name the way the bot does (registered "Minusculedog" for "Minuscule Dog").
  local fulls = {}
  for i, m in ipairs(members) do fulls[i] = m.fullName end
  local names = ns.logic.rosterNames(fulls, ns.discordData and ns.discordData() or nil)
  local kept = {}
  for i, m in ipairs(members) do
    if names[i] and (not m.realm or m.realm == ns.realmKey()) then m.name = names[i] end
    m.realm = nil
    if m.name then kept[#kept + 1] = m end
  end
  members = kept
  local oldLevels = type(ns.db.guild) == "table" and ns.logic.levelMap(ns.db.guild.members) or nil
  ns.db.guild = { name = guildName, updated = ns.now(), members = members }
  if ns.onRosterScan then ns.safe("rosterScan", ns.onRosterScan, oldLevels, members) end
  if ns.cache then
    ns.cache.levelHistory = type(ns.cache.levelHistory) == "table" and ns.cache.levelHistory or {}
    ns.logic.recordLevels(ns.cache.levelHistory, members, math.floor(ns.now() / 86400))
  end
  lastScan = ns.now()
  if ns.updateUI then ns.updateUI() end
end

-- "First Surname" for display (keys stay first names). The surname map is rebuilt only when the roster scan or
-- the saved data or the bot's Discord data table changes, or after ns.resetDisplayNames() (own surname learned).
local surnames, surnamesGuild, surnamesDB, surnamesDiscord

function ns.resetDisplayNames() surnames = nil end

function ns.displayName(name)
  local db = ns.db
  if not db then return name end
  local discord = ns.discordData and ns.discordData() or nil
  if not surnames or surnamesGuild ~= db.guild or surnamesDB ~= db or surnamesDiscord ~= discord then
    surnames = ns.logic.surnameMap(db.guild and db.guild.members, db.characters, discord)
    surnamesGuild, surnamesDB, surnamesDiscord = db.guild, db, discord
  end
  return ns.logic.displayName(name, surnames)
end

-- Scans now if allowed, otherwise once the minute is up.
local function scanThrottled()
  local wait = ns.config.rosterInterval - (ns.now() - lastScan)
  if wait <= 0 then
    scan()
  else
    ns.after(wait, "rosterScan", scan)
  end
end

-- force = true (from /gf roster): request now and scan on the next update, ignoring the throttle.
function ns.refreshRoster(force)
  if not ns.call("IsInGuild") then
    if force then ns.print("this character is not in a guild") end
    return
  end
  if force then
    lastScan = 0
    lastRequest = 0
    ns.print("requesting guild roster")
  end
  requestRoster()
end

ns.on("GUILD_ROSTER_UPDATE", function() scanThrottled() end)

ns.on("PLAYER_LOGIN", function()
  ns.after(10, "rosterFirst", function() requestRoster() end)
end)

ns.every(ns.config.rosterInterval, "rosterRequest", function()
  if ns.call("IsInGuild") then requestRoster() end
end)
