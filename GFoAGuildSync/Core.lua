-- GFoA Guild Sync: core (saved data, events, timers, slash commands).
-- Data only: this addon reads game state and writes SavedVariables. It never acts for the player.
-- Every game API is looked up before use: WoW: Forever's API surface is not confirmed, so a missing
-- function just means that piece of data is skipped.
local addonName, ns = ...

ns.name = addonName or "GFoAGuildSync"
ns.DB_VERSION = 1
ns.ADDON_VERSION = "1.8.5"

local frame = CreateFrame("Frame")
ns.frame = frame

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

function ns.now()
  if time then return time() end
  return 0
end

function ns.print(msg)
  local text = "|cffd38cffGFoA Sync|r: " .. tostring(msg)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(text)
  elseif print then
    print(text)
  end
end

-- Calls fn(...) and never lets an error escape. The last error is kept for /gf.
function ns.safe(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    ns.lastError = tostring(label) .. ": " .. tostring(err)
    ns.errorCount = (ns.errorCount or 0) + 1
  end
  return ok
end

-- Returns the global function at a dotted path ("C_GuildInfo.GuildRoster") or nil.
function ns.api(path)
  local obj = _G
  for part in string.gmatch(path, "[^%.]+") do
    if type(obj) ~= "table" then return nil end
    obj = obj[part]
  end
  if type(obj) == "function" then return obj end
  return nil
end

-- Calls an API by dotted path; returns nothing when it doesn't exist or errors.
function ns.call(path, ...)
  local fn = ns.api(path)
  if not fn then return end
  local results = { pcall(fn, ...) }
  if not results[1] then return end
  return unpack(results, 2, table.maxn(results))
end

function ns.realmKey()
  local realm = ns.call("GetNormalizedRealmName")
  if not realm or realm == "" then
    realm = ns.call("GetRealmName") or ""
    realm = string.gsub(realm, "[%s%-]", "")
  end
  return realm
end

-- True on a WoW: Forever client (there UnitName's second value is the surname, not the realm).
function ns.isForever()
  if ns.foreverCached == nil then
    local _, _, _, interface = ns.call("GetBuildInfo")
    ns.foreverCached = ns.logic.isForeverInterface(interface) and true or false
  end
  return ns.foreverCached
end

-- UnitName(unit) as first, surname, realm (surname only on Forever, realm only elsewhere).
function ns.unitName(unit)
  local a, b = ns.call("UnitName", unit)
  return ns.logic.splitUnitName(ns.plain(a), ns.plain(b), ns.isForever())   -- secret names count as missing
end

-- "Name Surname-Realm" -> "Name" (own realm) or "Name-Realm"; Forever's roster adds a surname.
function ns.shortName(full)
  local name, realm = ns.logic.splitName(full)
  if not name then return nil end
  if not realm or realm == ns.realmKey() then return name end
  return name .. "-" .. realm
end

function ns.count(t)
  local n = 0
  if type(t) == "table" then
    for _ in pairs(t) do n = n + 1 end
  end
  return n
end

-- Per-character option with a default (stored in GFoAGuildSyncSettings).
function ns.opt(key, default)
  local s = ns.settings
  if not s or s[key] == nil then return default end
  return s[key]
end

function ns.setOpt(key, value)
  if ns.settings then ns.settings[key] = value end
end

-- Data from the guild Discord (GFoAGuildSyncBotData, an optional file next to the saved data). Read only: never write to it, WoW saves
-- it back unchanged on logout. Returns nil when the file is missing or a version we don't know.
-- A copy relayed by an officer's addon (BotRelay.lua, GFoAGuildSyncCache.botData) is used when it is newer; the same
-- table comes back on every call (the display-name cache in Roster.lua keys on it). Second value: "file" / "relay".
function ns.discordData()
  local relay = ns.cache and ns.opt("botDataRelay", true) and ns.cache.botData or nil
  return ns.logic.newerBotData(GFoAGuildSyncBotData, relay)
end

-- true when v is a Midnight-style "secret" value that addons may not inspect (guarded: the API may not exist).
function ns.isSecret(v)
  if type(issecretvalue) == "function" then
    local ok, r = pcall(issecretvalue, v)
    return ok and r and true or false
  end
  return false
end

-- v, or nil when v is a secret value (safe to compare, concatenate, store and use as a table key afterwards).
function ns.plain(v)
  if ns.isSecret(v) then return nil end
  return v
end

-- Instance info as instanceType ("raid", "party", ... or nil outside), name, maxPlayers, instanceId, difficultyName.
-- GetInstanceInfo first (its type is what WoW: Forever's 10/20/40 raids report), IsInInstance as the fallback.
function ns.instanceInfo()
  local name, giType, _, difficultyName, maxPlayers, _, _, instanceId = ns.call("GetInstanceInfo")
  local inInstance, iiType = ns.call("IsInInstance")
  local kind = ns.logic.instanceType(ns.plain(giType), inInstance, ns.plain(iiType))
  name = ns.plain(name)
  if type(name) ~= "string" or name == "" then name = ns.call("GetRealZoneText") or ns.call("GetZoneText") end
  instanceId = ns.plain(instanceId)
  return kind, ns.plain(name), ns.plain(maxPlayers), type(instanceId) == "number" and instanceId or nil,
    ns.plain(difficultyName)
end

ns.CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"
ns.CROSS = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:0|t"

function ns.ago(t)
  if not t or t == 0 then return "never" end
  local d = ns.now() - t
  if d < 0 then d = 0 end
  if d < 90 then return d .. "s ago" end
  if d < 5400 then return math.floor(d / 60) .. "m ago" end
  if d < 172800 then return math.floor(d / 3600) .. "h ago" end
  return math.floor(d / 86400) .. "d ago"
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local handlers = {}
local registered = {}

local function registerEvent(event)
  if registered[event] then return true end
  -- RegisterEvent errors on events this client doesn't know, so guard it.
  local ok = pcall(frame.RegisterEvent, frame, event)
  registered[event] = ok
  return ok
end

-- Subscribes fn to a game event. Returns false when the client doesn't have that event.
function ns.on(event, fn)
  handlers[event] = handlers[event] or {}
  table.insert(handlers[event], fn)
  return registerEvent(event)
end

function ns.hasEvent(event)
  return registered[event] == true
end

function ns.unregister(event)
  if registered[event] then
    pcall(frame.UnregisterEvent, frame, event)
    registered[event] = nil
  end
end

function ns.reregister(event)
  return registerEvent(event)
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  if not ns.db and event ~= "ADDON_LOADED" then return end
  for i = 1, #list do
    ns.safe(event, list[i], event, ...)
  end
end)

-- ---------------------------------------------------------------------------
-- Timers (one OnUpdate, checked once a second; works without C_Timer)
-- ---------------------------------------------------------------------------

local tasks = {}
local acc = 0

-- Runs fn every `seconds` seconds (first run after `seconds`).
function ns.every(seconds, label, fn)
  table.insert(tasks, { every = seconds, due = ns.now() + seconds, label = label, fn = fn })
end

-- Runs fn once after `seconds` seconds. A later call with the same label replaces the pending one.
function ns.after(seconds, label, fn)
  for i = #tasks, 1, -1 do
    if tasks[i].label == label and not tasks[i].every then table.remove(tasks, i) end
  end
  table.insert(tasks, { due = ns.now() + seconds, label = label, fn = fn })
end

frame:SetScript("OnUpdate", function(_, elapsed)
  acc = acc + (elapsed or 0)
  if acc < 1 then return end
  acc = 0
  if not ns.db then return end
  local t = ns.now()
  local i = 1
  while i <= #tasks do
    local task = tasks[i]
    if t >= task.due then
      if task.every then
        task.due = t + task.every
        i = i + 1
      else
        table.remove(tasks, i)
      end
      ns.safe(task.label, task.fn)
    else
      i = i + 1
    end
  end
end)

-- ---------------------------------------------------------------------------
-- Saved data
-- ---------------------------------------------------------------------------

function ns.newDB()
  return { version = ns.DB_VERSION }
end

-- GFoAGuildSyncDB also holds the account's Discord link code (`link`) and chosen main (`main`), set by /gf link and
-- /gf main. initDB and prune leave them alone; /gf reset yes clears them with everything else.
local function initDB()
  if type(GFoAGuildSyncDB) ~= "table" or GFoAGuildSyncDB.version ~= ns.DB_VERSION then
    GFoAGuildSyncDB = ns.newDB()
  end
  local db = GFoAGuildSyncDB
  -- WoW writes SavedVariables only at /reload or logout, and the code that was running then writes them. After an
  -- update the first /reload loads this version but the file still holds what the old one saved, so say when the
  -- new data will reach Discord (one /reload or logout from now). No API can save earlier.
  if db.addonVersion and db.addonVersion ~= ns.ADDON_VERSION then ns.updatedFrom = db.addonVersion end
  db.addonVersion = ns.ADDON_VERSION
  if type(db.characters) ~= "table" then db.characters = {} end
  if type(db.raids) ~= "table" then db.raids = {} end
  if type(db.loot) ~= "table" then db.loot = {} end
  if db.link ~= nil then db.link = ns.logic.normalizeLinkCode(db.link) end
  if db.main ~= nil then db.main = ns.logic.cleanMainName(db.main) end
  ns.db = db

  if type(GFoAGuildSyncSettings) ~= "table" then GFoAGuildSyncSettings = {} end
  ns.settings = GFoAGuildSyncSettings

  -- Account-wide local cache (reagents, guildmates' cooldowns, roster level history). Never uploaded: the uploader
  -- only reads GFoAGuildSyncDB.
  if type(GFoAGuildSyncCache) ~= "table" then GFoAGuildSyncCache = {} end
  ns.cache = GFoAGuildSyncCache
end

function ns.lootMin()
  local v = ns.settings and ns.settings.lootMin
  if type(v) == "number" then return v end
  return ns.config.lootMinQuality
end

-- Drops raids and loot older than config.keepDays.
function ns.prune()
  local db = ns.db
  if not db then return end
  local cutoff = ns.now() - ns.config.keepDays * 86400
  local raids = {}
  for _, r in ipairs(db.raids or {}) do
    if type(r) == "table" and (r.last or r.start or 0) >= cutoff then table.insert(raids, r) end
  end
  db.raids = raids
  local loot = {}
  for _, l in ipairs(db.loot or {}) do
    if type(l) == "table" and (l.t or 0) >= cutoff then table.insert(loot, l) end
  end
  db.loot = loot
  if type(db.dungeons) == "table" then db.dungeons = ns.logic.pruneByTime(db.dungeons, cutoff) end
  ns.logic.pruneGuildSync(db.guildSync, ns.now() - (ns.config.guildSyncKeepDays or 30) * 86400)
  if type(db.craftRequests) == "table" then
    db.craftRequests = ns.logic.pruneByTime(db.craftRequests, ns.now() - (ns.config.craftRequestKeepDays or 7) * 86400)
  end
end

ns.on("ADDON_LOADED", function(_, loaded)
  if loaded ~= ns.name or ns.db then return end
  initDB()
  -- ADDON_LOADED stays registered: Discord.lua hooks the load-on-demand Blizzard guild UI when it loads.
end)

ns.on("PLAYER_LOGIN", function()
  local db = ns.db
  db.realm = ns.call("GetRealmName") or db.realm
  db.faction = ns.call("UnitFactionGroup", "player") or db.faction
  ns.prune()
  if ns.updatedFrom then
    ns.print("updated " .. ns.updatedFrom .. " -> " .. ns.ADDON_VERSION
      .. ". Your next /reload or logout saves this version's data for Discord.")
    ns.updatedFrom = nil
  end
  -- /gf chatlog on: the client's chat log (Logs\WoWChatLog.txt) feeds tools/gfoa_chat_relay.py. The game turns
  -- logging off every session, so switch it back on at each login.
  if ns.cache and ns.cache.chatlog then ns.call("LoggingChat", true) end
end)

local function chatlogCommand(arg)
  arg = string.lower(arg or "")
  if arg == "on" or arg == "off" then
    ns.cache.chatlog = (arg == "on") or nil
    ns.call("LoggingChat", arg == "on")
  end
  local logging = ns.call("LoggingChat")
  ns.print("chat log to Logs\\WoWChatLog.txt: " .. (logging and "on" or "off")
    .. (ns.cache.chatlog and " (turned on at every login)" or "")
    .. ". Usage: /gf chatlog on|off (feeds the guild chat relay to Discord)")
  ns.print("Guild chat posts to Discord in a batch when you log out (not live, not on /reload). "
    .. "Tell your guild: their guild chat ends up in Discord.")
end

ns.every(3600, "prune", function() ns.prune() end)

-- ---------------------------------------------------------------------------
-- Discord link code (docs "Link codes"): typed once per WoW account, sent with every guild sync payload
-- ---------------------------------------------------------------------------

ns.LINK_HINT = "get your code from the guild Discord panel > Link game account"

-- One line: "Linked: ABC123, main Thrall" or "Not linked: ...".
function ns.linkLine()
  local db = ns.db
  if not db then return "not loaded yet" end
  local main = db.main and (", main " .. db.main) or ", main not set (/gf main)"
  if db.link then return "Linked: " .. db.link .. main end
  return "Not linked: " .. ns.LINK_HINT .. main
end

-- Stores a typed code. Returns true, or false + reason. Sends this character to officers' addons straight away.
function ns.setLink(raw)
  local code = ns.logic.normalizeLinkCode(raw)
  if not code then
    return false, "that isn't a link code (6 letters/digits, e.g. ABC234); " .. ns.LINK_HINT
  end
  ns.db.link = code
  if ns.sendSync then ns.sendSync("link") end
  return true
end

function ns.clearLink()
  ns.db.link = nil
  if ns.sendSync then ns.sendSync("link") end
end

-- Makes the logged-in character the account's main.
function ns.setMain()
  local me = ns.logic.cleanMainName(ns.call("UnitName", "player"))
  if not me then return false, "character name not available yet" end
  ns.db.main = me
  if ns.sendSync then ns.sendSync("link") end
  return true
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

ns.commands = {}

local function status()
  local db = ns.db
  if not db then ns.print("not loaded yet") return end
  local g = db.guild
  ns.print(string.format("guild roster: %d members, scanned %s",
    g and g.members and #g.members or 0, ns.ago(g and g.updated)))
  local me = ns.call("UnitName", "player")
  local c = me and db.characters[me]
  ns.print(string.format("characters: %d (this one updated %s)", ns.count(db.characters), ns.ago(c and c.updated)))
  local raid = ns.currentRaid and ns.currentRaid()
  ns.print(string.format("raids: %d, loot: %d (recording quality >= %d)%s, dungeon runs: %d",
    #db.raids, #db.loot, ns.lootMin(), raid and (", in raid " .. tostring(raid.zone)) or "",
    type(db.dungeons) == "table" and #db.dungeons or 0))
  if ns.xpStatusLine then ns.print(ns.xpStatusLine()) end
  if ns.recipeStatusLine then ns.print(ns.recipeStatusLine()) end
  ns.print("Discord link: " .. ns.linkLine())
  local discord, source = ns.discordData()
  if discord then
    ns.print(string.format("Discord data: %d characters, %d crafted items (from %s%s)",
      ns.count(discord.characters), ns.count(discord.crafters), ns.ago(discord.generated),
      source == "relay" and (", via " .. tostring(ns.cache.botDataFrom) .. "'s addon") or ""))
  else
    ns.print("Discord data: none yet (optional; officers' addons send it, or the guild sync tool after you log out)")
  end
  if ns.botDataRelayLine then ns.print(ns.botDataRelayLine()) end
  local notice = ns.updateNotice and ns.updateNotice()
  if notice then ns.print("|cffffd100" .. notice .. "|r") end
  if ns.lastError then
    ns.print(string.format("|cffff6666%d error(s), last: %s|r", ns.errorCount or 0, ns.lastError))
  end
  ns.print("commands: /gf guild | lb | cd | attune | dungeons | xp [reset] | level | finder | stats | chars | ask ITEM"
    .. " | ready | events | reminders | who ITEM | crafts | toasts on|off"
    .. " | export | link CODE | unlink | main | options | show | minimap [reset] | roster | lootmin N | alts | sync"
    .. " | officer | quest ID | questid | api | chatlog | reset | pegs")
end

ns.commands[""] = status
ns.commands["status"] = status

ns.commands["roster"] = function()
  if ns.refreshRoster then ns.refreshRoster(true) end
end

ns.commands["link"] = function(arg)
  if not arg or arg == "" then
    ns.print("Discord link: " .. ns.linkLine())
    return
  end
  local ok, err = ns.setLink(arg)
  if ok then
    ns.print("Discord link saved for every character on this account: " .. ns.db.link
      .. ". Your characters register themselves after their next guild sync.")
  else
    ns.print(err)
  end
end

ns.commands["unlink"] = function()
  ns.clearLink()
  ns.print("Discord link code removed (characters already registered stay registered)")
end

ns.commands["main"] = function()
  local ok, err = ns.setMain()
  if ok then
    ns.print(ns.db.main .. " is now your main" .. (ns.db.link and "" or " (also set a link code: /gf link CODE)"))
  else
    ns.print(err)
  end
end

ns.commands["lootmin"] = function(arg)
  local n = tonumber(arg)
  if not n or n < 0 or n > 5 then
    ns.print("usage: /gf lootmin 0-5 (3 rare, 4 epic, 5 legendary). Now: " .. ns.lootMin())
    return
  end
  ns.settings.lootMin = math.floor(n)
  ns.print("recording loot of quality " .. ns.settings.lootMin .. " and above (this character)")
end

ns.commands["reset"] = function(arg)
  if arg ~= "yes" then
    ns.print("this deletes all saved GFoA sync data on this PC. Type /gf reset yes to confirm.")
    return
  end
  GFoAGuildSyncDB = ns.newDB()
  ns.db = nil
  initDB()
  ns.print("data reset")
  if ns.refreshCharacter then ns.refreshCharacter() end
  if ns.refreshRoster then ns.refreshRoster(true) end
end

ns.commands["quest"] = function(arg)
  local id = tonumber(arg)
  if not id then ns.print("usage: /gf quest <quest id>") return end
  local done = ns.questDone and ns.questDone(id)
  if done == nil then
    ns.print("quest flag API not available in this client")
  else
    ns.print("quest " .. id .. ": " .. (done and "completed" or "not completed"))
  end
end

ns.commands["chatlog"] = chatlogCommand

SLASH_GFOA1 = "/gf"
SLASH_GFOA2 = "/gfoa"
SlashCmdList["GFOA"] = function(msg)
  ns.safe("slash", function()
    msg = msg or ""
    local cmd, arg = string.match(msg, "^%s*(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")
    local fn = ns.commands[cmd]
    if fn then
      fn(arg)
    else
      ns.print("unknown command: " .. cmd)
      status()
    end
  end)
  if ns.lastError and ns.lastError:find("^slash") then
    ns.print("|cffff6666" .. ns.lastError .. "|r")
    ns.lastError = nil
  end
end
