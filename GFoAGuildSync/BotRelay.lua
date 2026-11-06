-- GFoA Guild Sync: bot data relay (docs/sync-format.md "Bot data relay"). Members who play on a PC without the
-- uploader get the Discord data (check marks, alts, mains, roles, crafters, surnames, link status) from an officer's
-- addon. Hidden addon messages only, nothing in chat, no pop-ups.
--   G:<generated>   GUILD, from an addon whose newest copy is missing or over 12 h old (20 s after login, then at
--                   most every 30 min). <generated> is the copy it has, 0 for none.
--   B:<msgId>:<i>/<n>:<chunk>   WHISPER reply from a holder: an addon whose GFoAGuildSyncBotData came from the
--                   uploader file and is newer. Relayed copies never answer, so there are no loops.
-- Replies go out only when the guild sync queue (Comm.lua) is empty, sharing its one message per second.
-- Received copies live in GFoAGuildSyncCache.botData (account-wide, never uploaded).
local _, ns = ...
local L = ns.logic

local PREFIX = L.COMM_PREFIX
local QUEUE_MAX = 300            -- queued reply messages at most (about 5 minutes of sending)
local outbox = {}                -- { channel, target, msg }
local pending = {}               -- sender:msgId -> chunk set
local answered = {}              -- requester -> time we last queued a reply
local whispering = {}            -- whisper target -> time of the last chunk (for the offline system message)
local replyCache                 -- { generated, msgs, dropped } of our file
local served = 0

-- The uploader file's table (holders only answer from this, never from a relayed copy).
local function fileData()
  local d = GFoAGuildSyncBotData
  if L.botDataGenerated(d) > 0 then return d end
  return nil
end

local function enabled()
  return ns.opt("botDataRelay", true) and ns.call("IsInGuild") and true or false
end

local function members()
  return ns.db and type(ns.db.guild) == "table" and ns.db.guild.members or nil
end

local function send(e)
  if ns.api("C_ChatInfo.SendAddonMessage") then
    ns.call("C_ChatInfo.SendAddonMessage", PREFIX, e.msg, e.channel, e.target)
  elseif ns.api("SendAddonMessage") then
    ns.call("SendAddonMessage", PREFIX, e.msg, e.channel, e.target)
  end
end

local function dropTarget(target)
  for i = #outbox, 1, -1 do
    if outbox[i].target == target then table.remove(outbox, i) end
  end
end

-- Called by Comm.lua's pump when its own queue is empty: sends at most one message.
function ns.relayPump()
  local t = ns.now()
  L.expirePending(pending, t, 120)
  while #outbox > 0 do
    local e = table.remove(outbox, 1)
    if e.channel == "WHISPER" then
      -- Skip requesters the last roster scan shows offline (a whisper to them prints a system line).
      local m = L.rosterMember(members(), e.target)
      if m and m.online == false then
        dropTarget(e.target)
      else
        whispering[e.target] = t
        send(e)
        return
      end
    elseif ns.call("IsInGuild") then
      send(e)
      return
    end
  end
end

-- "No player named X is currently playing." after a whisper to someone who just logged off: hide it while we are
-- sending to them, and stop the rest of that reply.
local function systemFilter(_, _, msg, ...)
  if type(msg) ~= "string" or type(ERR_CHAT_PLAYER_NOT_FOUND_S) ~= "string" then return false, msg, ... end
  for target, t in pairs(whispering) do
    if ns.now() - t > 30 then
      whispering[target] = nil
    elseif msg == string.format(ERR_CHAT_PLAYER_NOT_FOUND_S, target)
        or msg == string.format(ERR_CHAT_PLAYER_NOT_FOUND_S, string.match(target, "^[^%-]+") or target) then
      dropTarget(target)
      return true
    end
  end
  return false, msg, ...
end

-- ---------------------------------------------------------------------------
-- Asking (any member)
-- ---------------------------------------------------------------------------

local function ask(force)
  if not enabled() or not ns.cache or (ns.registerCommPrefix and not ns.registerCommPrefix()) then return end
  local have = L.botDataGenerated(ns.discordData())
  local want = L.relayShouldAsk(have, ns.now(), force and 0 or ns.cache.botDataAsked)
  if not want then return end
  ns.cache.botDataAsked = ns.now()
  table.insert(outbox, 1, { channel = "GUILD", msg = L.relayRequestMessage(have) })
end

local function received(who, data)
  local payload = L.decodeExport(data)
  if not payload then return end
  local d = L.botDataFromRelay(payload, ns.now())
  if not d or d.generated <= L.botDataGenerated(ns.discordData()) then return end
  ns.cache.botData = d
  ns.cache.botDataFrom = who
  ns.cache.botDataAt = ns.now()
  if ns.updateUI then ns.updateUI() end
end

-- ---------------------------------------------------------------------------
-- Answering (holders: data from the uploader file)
-- ---------------------------------------------------------------------------

local function replyMessages(file)
  if not replyCache or replyCache.generated ~= file.generated then
    local msgs, dropped = L.relayReplyMessages(file, L.messageId(math.random))
    replyCache = { generated = file.generated, msgs = msgs, dropped = dropped }
  end
  return replyCache.msgs
end

local function answer(who, sender, have)
  local file = fileData()
  if not file or not L.relayShouldAnswer(file.generated, have) then return end
  -- Only when members' addons will trust us (our own rank), and only to someone in our roster scan.
  local me = ns.call("UnitName", "player")
  if not L.relayTrusted(members(), me) or not L.rosterMember(members(), who) then return end
  if ns.now() - (answered[who] or 0) < L.RELAY_ASK_GAP - 300 then return end
  answered[who] = ns.now()
  ns.after(2 + math.random(0, 6), "relayReply:" .. who, function()
    if not enabled() then return end
    local msgs = replyMessages(file)
    if not msgs or #outbox + #msgs > QUEUE_MAX then return end
    dropTarget(sender)
    for _, m in ipairs(msgs) do table.insert(outbox, { channel = "WHISPER", target = sender, msg = m }) end
    served = served + 1
  end)
end

local function onMessage(_, prefix, msg, channel, sender)
  if prefix ~= PREFIX or type(msg) ~= "string" or ns.isSecret(msg) or ns.isSecret(sender) then return end
  local kind, a, b, c, d = L.parseRelayMessage(msg)
  if not kind or not ns.opt("botDataRelay", true) then return end
  local who = ns.shortName(sender)
  if not who or who == ns.call("UnitName", "player") then return end
  if kind == "G" and channel == "GUILD" then
    answer(who, sender, a)
  elseif kind == "B" and channel == "WHISPER" and ns.cache then
    -- Trust rule: the sender is in our last roster scan with guild rank 0..2 (README "What it saves and sends").
    if not L.relayTrusted(members(), who) then return end
    local data = L.addChunk(pending, who .. ":" .. a, b, c, d, ns.now())
    if data then received(who, data) end
  end
end

-- One line for /gf.
function ns.botDataRelayLine()
  if not ns.opt("botDataRelay", true) then return "Discord info from officers' addons: off (Options)" end
  local parts = { "Discord info from officers' addons: on" }
  local file = fileData()
  if file then
    table.insert(parts, "this PC has the file, shares it" .. (served > 0 and (" (" .. served .. " sent)") or ""))
  end
  if ns.cache and ns.cache.botData then
    table.insert(parts, "last copy from " .. tostring(ns.cache.botDataFrom) .. " " .. ns.ago(ns.cache.botDataAt))
  end
  if ns.cache and ns.cache.botDataAsked then table.insert(parts, "asked " .. ns.ago(ns.cache.botDataAsked)) end
  if #outbox > 0 then table.insert(parts, #outbox .. " queued") end
  return table.concat(parts, ", ")
end

ns.on("CHAT_MSG_ADDON", onMessage)

ns.on("PLAYER_LOGIN", function()
  if type(ChatFrame_AddMessageEventFilter) == "function" then
    pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_SYSTEM", systemFilter)
  end
  ns.after(20, "relayAsk", function() ask(false) end)
end)

ns.every(L.RELAY_ASK_GAP, "relayAskTimer", function() ask(false) end)
