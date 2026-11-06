-- GFoA Guild Sync: guild addon sync (members' addons -> officer addons), automatic, hidden addon messages only.
--   Every addon sends its logged-in character (same payload as /gf export) on the GUILD addon channel on login,
--   level-up, profession change and in reply to an officer hello. Officer-mode addons store what they receive in
--   GFoAGuildSyncDB.guildSync. Addon messages are invisible to players; nothing is ever typed into chat.
--   At most 1 message per second leaves this client.
--   1.2.0 adds "Ask guild crafters" requests (R, only after the player clicks) and profession cooldown sharing
--   (C / Q: the logged-in character's cooldown recipes and when they're ready, nothing else).
--   1.2.1 puts the addon version first in C messages ("C:@1.2.1;...") and remembers the highest version heard
--   (from C messages and officers' received payloads) for a passive "new version is out" line.
--   1.4.0 adds the account's Discord link code and chosen main (top-level `link` / `main`, docs "Link codes") to the
--   payload; officers keep them when they re-encode what they received.
local _, ns = ...
local L = ns.logic

local PREFIX = L.COMM_PREFIX
local queue = {}          -- outgoing messages, one per second
local pending = {}        -- officer: sender:msgId -> chunk set
local cache               -- { msgId, data, acked, t } our last payload
local lastSent = 0        -- time our last payload was queued
local lastHello = 0       -- officer: time we last broadcast H
local profSig             -- profession signature, to send on change

-- ---------------------------------------------------------------------------
-- Officer mode
-- ---------------------------------------------------------------------------

function ns.canViewOfficerNote()
  if ns.api("C_GuildInfo.CanViewOfficerNote") then return ns.call("C_GuildInfo.CanViewOfficerNote") and true or false end
  if ns.api("CanViewOfficerNote") then return ns.call("CanViewOfficerNote") and true or false end
  return false
end

-- /gf officer on|off overrides; otherwise on when this character can read officer notes.
function ns.officerMode()
  local v = ns.settings and ns.settings.officerMode
  if v == true or v == false then return v end
  return ns.canViewOfficerNote()
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

local registered = false
local function registerPrefix()
  if registered then return true end
  if ns.api("C_ChatInfo.RegisterAddonMessagePrefix") then
    registered = ns.call("C_ChatInfo.RegisterAddonMessagePrefix", PREFIX) ~= false
  elseif ns.api("RegisterAddonMessagePrefix") then
    registered = ns.call("RegisterAddonMessagePrefix", PREFIX) ~= false
  end
  return registered
end
ns.registerCommPrefix = registerPrefix   -- BotRelay.lua

-- Short hidden messages from other files (Games.lua scores) share the one-per-second queue.
function ns.queueComm(msg)
  table.insert(queue, msg)
end

local function rawSend(msg)
  if not ns.call("IsInGuild") then return end
  if ns.api("C_ChatInfo.SendAddonMessage") then
    ns.call("C_ChatInfo.SendAddonMessage", PREFIX, msg, "GUILD")
  elseif ns.api("SendAddonMessage") then
    ns.call("SendAddonMessage", PREFIX, msg, "GUILD")
  end
end

-- One message per second in all: guild sync first, the bot data relay (BotRelay.lua) only when this queue is empty.
local function pump()
  local msg = table.remove(queue, 1)
  if msg then
    rawSend(msg)
  elseif ns.relayPump then
    ns.relayPump()
  end
  L.expirePending(pending, ns.now(), 60)
end

local function enqueueData(msgId, data)
  -- A newer payload replaces chunks of an older one still waiting.
  for i = #queue, 1, -1 do
    if string.sub(queue[i], 1, 2) == "D:" then table.remove(queue, i) end
  end
  for _, m in ipairs(L.chunkMessages(data, msgId)) do table.insert(queue, m) end
end

local function buildPayload()
  local me = ns.call("UnitName", "player")
  local c = me and ns.db.characters[me]
  if type(c) ~= "table" then return nil end
  local extra = { link = ns.db.link, main = ns.db.main }
  local payload = L.exportPayload({ [me] = c }, ns.now(), ns.call("GetRealmName"), ns.ADDON_VERSION, true, extra)
  local data = L.encodeExport(payload)
  if #data > L.EXPORT_MAX then
    data = L.encodeExport(L.exportPayload({ [me] = c }, ns.now(), ns.call("GetRealmName"), ns.ADDON_VERSION, false,
      extra))
  end
  if #data > L.EXPORT_MAX then return nil end
  return data
end

-- Builds a fresh payload of the logged-in character and queues it.
function ns.sendSync(reason)
  if not ns.opt("guildSync", true) or not ns.call("IsInGuild") or not registerPrefix() then return end
  if ns.refreshCharacter then ns.refreshCharacter() end
  local data = buildPayload()
  if not data then return end
  cache = { msgId = L.messageId(math.random), data = data, acked = false, t = ns.now(), reason = reason }
  lastSent = ns.now()
  enqueueData(cache.msgId, data)
end

local function resendCached()
  if not cache then return end
  lastSent = ns.now()
  enqueueData(cache.msgId, cache.data)
end

local function sayHello()
  if not ns.officerMode() or not registerPrefix() then return end
  local t = ns.now()
  if t - lastHello < 900 then return end
  lastHello = t
  table.insert(queue, "H")
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

-- Remembers the highest addon version heard from guildmates (shown only in /gf and on the Options page).
function ns.heardVersion(version, from)
  if not ns.db then return end
  ns.db.newestSeen = L.noteVersion(ns.db.newestSeen, version, from, ns.now(), ns.ADDON_VERSION)
end

-- The passive "new version is out" line, or nil.
function ns.updateNotice()
  return ns.db and L.updateNotice(ns.db.newestSeen, ns.ADDON_VERSION)
end

local function store(sender, data, msgId)
  local payload = L.decodeExport(data)
  if not payload then return end
  ns.heardVersion(payload.addon, sender)
  local _, kept = L.filterSender(payload, sender)
  if kept == 0 then return end
  -- link / main stay in the re-encoded payload (the bot reads them); drop anything that isn't valid.
  payload.link = L.normalizeLinkCode(payload.link)
  payload.main = L.cleanMainName(payload.main)
  ns.db.guildSync = type(ns.db.guildSync) == "table" and ns.db.guildSync or {}
  ns.db.guildSync[sender] = { sender = sender, t = ns.now(), data = L.encodeExport(payload) }
  table.insert(queue, "A:" .. msgId)
  if ns.updateUI then ns.updateUI() end
end

-- ---------------------------------------------------------------------------
-- Craft requests ("Ask guild crafters", docs "Craft requests over guild sync"): explicit click only
-- ---------------------------------------------------------------------------

local function asks()
  ns.settings.asks = type(ns.settings.asks) == "table" and ns.settings.asks or {}
  return ns.settings.asks
end

local function storeCraftRequest(sender, itemId, item)
  ns.db.craftRequests = type(ns.db.craftRequests) == "table" and ns.db.craftRequests or {}
  L.addCraftRequest(ns.db.craftRequests, { t = ns.now(), sender = sender, itemId = itemId, item = item })
end

-- The ask for itemId on this character ({ t, msgId, acked, item }) or nil.
function ns.askState(itemId)
  local a = ns.settings and type(ns.settings.asks) == "table" and ns.settings.asks[itemId]
  if type(a) == "table" and ns.now() - (a.t or 0) < 7 * 86400 then return a end
  return nil
end

-- Queues R:<msgId>:<itemId>:<name> for officers' addons. Returns true, or false + reason.
function ns.askCrafters(itemId, item)
  itemId = tonumber(itemId)
  if not itemId or type(item) ~= "string" or item == "" then return false, "no item" end
  if not ns.call("IsInGuild") then return false, "this character is not in a guild" end
  if not registerPrefix() then return false, "addon messages not available" end
  local prev = ns.askState(itemId)
  if prev and math.floor(prev.t / 86400) == math.floor(ns.now() / 86400) then
    return false, "already asked today"
  end
  local msgId = L.messageId(math.random)
  asks()[itemId] = { t = ns.now(), msgId = msgId, acked = false, item = item }
  table.insert(queue, L.craftRequestMessage(msgId, itemId, item))
  if ns.officerMode() then
    storeCraftRequest(ns.call("UnitName", "player"), itemId, L.utf8Cut(item, L.ITEM_NAME_MAX))
    asks()[itemId].acked = true
  end
  return true
end

local function resendAsks()
  for itemId, a in pairs(asks()) do
    if type(a) ~= "table" or ns.now() - (a.t or 0) >= 7 * 86400 then
      asks()[itemId] = nil
    elseif not a.acked and a.msgId then
      table.insert(queue, L.craftRequestMessage(a.msgId, itemId, a.item))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Guildmates' profession cooldowns (C / Q, hidden addon messages, own logged-in character only)
-- ---------------------------------------------------------------------------

local lastCdSig, lastCdSent, lastQuery = nil, 0, 0

local function myCooldowns()
  local c = ns.myChar and ns.myChar()
  return L.cooldownState(c, ns.now(), ns.cache and ns.cache.cdNames)
end

local function sendCooldowns(force)
  if not ns.opt("shareCooldowns", true) or not ns.call("IsInGuild") or not registerPrefix() then return end
  local list = myCooldowns()
  if #list == 0 then return end
  local msg = L.cooldownMessage(list, ns.now(), nil, ns.ADDON_VERSION)
  local sig = string.gsub(msg, "=%d+", function(v) return v == "=0" and "=0" or "=1" end)
  if not force and sig == lastCdSig then return end
  if force and ns.now() - lastCdSent < 600 then return end
  lastCdSig, lastCdSent = sig, ns.now()
  table.insert(queue, msg)
end

function ns.cooldownsChanged()
  ns.after(15, "cdShare", function() sendCooldowns(false) end)
end

-- Asks online guildmates' addons for their cooldowns (when the cooldown window opens; at most every 5 min).
function ns.queryCooldowns()
  if not ns.opt("shareCooldowns", true) or not ns.call("IsInGuild") or not registerPrefix() then return end
  if ns.now() - lastQuery < 300 then return end
  lastQuery = ns.now()
  table.insert(queue, "Q")
end

-- { { name, t, list = { { name, readyAt } } } } of guildmates heard from in the last 3 days, by name.
function ns.peerCooldowns()
  local out = {}
  local peers = ns.cache and type(ns.cache.peerCd) == "table" and ns.cache.peerCd or {}
  for who, e in pairs(peers) do
    if type(e) ~= "table" or ns.now() - (e.t or 0) > 3 * 86400 then
      peers[who] = nil
    else
      table.insert(out, { name = who, t = e.t, list = e.list or {} })
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

local function onMessage(_, prefix, msg, channel, sender)
  if prefix ~= PREFIX or channel ~= "GUILD" or type(msg) ~= "string" or ns.isSecret(msg) then return end
  local who = ns.shortName(sender)
  local me = ns.call("UnitName", "player")
  if not who or who == me then return end
  local kind, a, b, c, d = L.parseMessage(msg)
  if kind == "H" then
    if not cache or ns.now() - lastSent >= 600 then
      ns.sendSync("hello")
    elseif not cache.acked then
      resendCached()
    end
    resendAsks()
  elseif kind == "A" then
    if cache and cache.msgId == a then cache.acked = true end
    for _, ask in pairs(asks()) do
      if type(ask) == "table" and ask.msgId == a then ask.acked = true end
    end
  elseif kind == "D" and ns.officerMode() then
    local data = L.addChunk(pending, who .. ":" .. a, b, c, d, ns.now())
    if data then store(who, data, a) end
  elseif kind == "R" and ns.officerMode() then
    storeCraftRequest(who, b, L.utf8Cut(c, L.ITEM_NAME_MAX))
    table.insert(queue, "A:" .. a)
    if ns.updateUI then ns.updateUI() end
  elseif kind == "C" then
    if ns.cache then
      ns.cache.peerCd = type(ns.cache.peerCd) == "table" and ns.cache.peerCd or {}
      ns.cache.peerCd[who] = { t = ns.now(), list = L.parseCooldowns(a, ns.now()) }
    end
    ns.heardVersion(L.cooldownVersion(a), who)
    if ns.refreshCooldowns then ns.refreshCooldowns() end
  elseif kind == "Q" then
    ns.after(2 + math.random(0, 8), "cdReply", function() sendCooldowns(true) end)
  end
end

function ns.syncStatus()
  local gs = ns.db and ns.db.guildSync
  local parts = {
    "guild sync " .. (ns.opt("guildSync", true) and "on" or "off"),
    "officer mode " .. (ns.officerMode() and "on" or "off"),
  }
  if cache then
    table.insert(parts, "last sent " .. ns.ago(cache.t) .. (cache.acked and " (acked)" or " (not acked yet)"))
  end
  if ns.officerMode() then table.insert(parts, "received from " .. ns.count(gs) .. " members") end
  if ns.officerMode() and type(ns.db.craftRequests) == "table" then
    table.insert(parts, #ns.db.craftRequests .. " craft requests (7 days)")
  end
  if #queue > 0 then table.insert(parts, #queue .. " queued") end
  return table.concat(parts, ", ")
end

ns.commands["officer"] = function(arg)
  arg = string.lower(arg or "")
  if arg == "on" then
    ns.settings.officerMode = true
  elseif arg == "off" then
    ns.settings.officerMode = false
  elseif arg == "auto" then
    ns.settings.officerMode = nil
  else
    ns.print("usage: /gf officer on | off | auto (auto = on when you can read officer notes)")
  end
  ns.print(ns.syncStatus())
  if ns.officerMode() then
    lastHello = 0
    sayHello()
  end
end

ns.commands["sync"] = function(arg)
  if arg == "now" then
    ns.sendSync("manual")
    ns.print("sending this character to officers' addons")
  end
  ns.print(ns.syncStatus())
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

-- Profession names, and names with skill. A new/dropped profession sends now; skill-ups at most every 10 min.
local function professionSignature()
  local c = ns.myChar and ns.myChar()
  if not c or type(c.professions) ~= "table" then return nil end
  local names, skills = {}, {}
  for _, p in ipairs(c.professions) do
    table.insert(names, tostring(p.name))
    table.insert(skills, tostring(p.name) .. "=" .. tostring(p.skill))
  end
  return { names = table.concat(names, ","), skills = table.concat(skills, ",") }
end

ns.on("CHAT_MSG_ADDON", onMessage)

ns.on("PLAYER_LOGIN", function()
  registerPrefix()
  local delay = 10 + math.random(0, 20)
  ns.after(delay, "syncLogin", function()
    ns.sendSync("login")
    profSig = professionSignature()
  end)
  ns.after(45 + math.random(0, 30), "cdLogin", function() sendCooldowns(false) end)
  ns.after(40, "syncHello", sayHello)
end)

ns.on("PLAYER_LEVEL_UP", function() ns.after(5, "syncLevel", function() ns.sendSync("level") end) end)

ns.on("SKILL_LINES_CHANGED", function()
  ns.after(10, "syncProf", function()
    local sig = professionSignature()
    if profSig and sig then
      if sig.names ~= profSig.names then
        ns.sendSync("profession")
      elseif sig.skills ~= profSig.skills and ns.now() - lastSent >= 600 then
        ns.sendSync("skill")
      else
        return   -- keep the old signature so the skill change is sent later
      end
    end
    profSig = sig or profSig
  end)
end)

ns.every(1, "commQueue", pump)
ns.every(900, "syncHelloTimer", sayHello)
