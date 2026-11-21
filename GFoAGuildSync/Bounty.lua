-- Bounty board (docs/bounties.md): enemies the guild posted on the Discord bounty board.
--   * tooltip line on a bounty target (or anyone in a bounty guild), through Discord.lua's unit tooltip;
--   * optional alert (off by default) when you target, mouse over or see the nameplate of a bounty target;
--   * kill claims: an honor-kill line naming a bounty target is saved and sent to the bot (guild sync `bk`, and the
--     uploader's `bountyKills`), which posts it on the bounty board.
-- Read only and local: nothing here sends a chat message. Pure logic is in Logic.lua (L.bounty*).
local _, ns = ...
local L = ns.logic

local cachedFrom, cachedAt, cached = nil, 0, {}
local alertSeen = {}

-- Live bounties from the bot data (file or relayed copy), re-cleaned at most once a minute.
function ns.bounties()
  local d = ns.discordData()
  local raw = d and d.bounties or nil
  local now = ns.now()
  if raw ~= cachedFrom or now - cachedAt >= 60 then
    cached = L.cleanBounties(raw, now)
    cachedFrom, cachedAt = raw, now
  end
  return cached
end

local function unitGuild(unit)
  local g = ns.call("GetGuildInfo", unit)
  if type(g) ~= "string" or g == "" or ns.isSecret(g) then return nil end
  return g
end

local function lookup(unit, name, surname)
  if not ns.opt("bountyShow", true) then return nil end
  local list = ns.bounties()
  if #list == 0 then return nil end
  return L.bountyFor(list, name, surname, unitGuild(unit))
end

-- Discord.lua calls this for player tooltips: headline, reason (or nil, nil).
function ns.bountyTooltip(unit, name, surname)
  local b, how = lookup(unit, name, surname)
  if not b then return nil end
  return L.bountyLines(b, how, surname == nil)
end

-- --- alert ------------------------------------------------------------------------------------

local function inPvpInstance()
  local inside, kind = ns.call("IsInInstance")
  return inside and (kind == "pvp" or kind == "arena")
end

local function alertFor(unit)
  if not ns.opt("bountyAlert", false) or inPvpInstance() then return end
  if not unit or ns.isSecret(unit) or not ns.call("UnitIsPlayer", unit) then return end
  local name, surname = ns.unitName(unit)
  if type(name) ~= "string" then return end
  local b, how = lookup(unit, name, surname)
  if not b or not L.bountyAlertDue(alertSeen, string.lower(L.fullName(name, surname) or name), ns.now()) then
    return
  end
  local who = L.fullName(name, surname) or name
  local text = how == "guild" and ("GFoA grudge nearby: " .. who .. " <" .. b.name .. ">")
    or ("Bounty target nearby: " .. who .. (b.reward and (" (" .. b.reward .. ")") or ""))
  ns.print("|cffff5555" .. text .. "|r" .. (b.reason and (" - " .. b.reason) or ""))
  local frame = _G.RaidWarningFrame
  if frame and type(_G.RaidNotice_AddMessage) == "function" and type(_G.ChatTypeInfo) == "table" then
    pcall(_G.RaidNotice_AddMessage, frame, text, _G.ChatTypeInfo["RAID_WARNING"])
  end
  local kit = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT.RAID_WARNING or 8959
  ns.call("PlaySound", kit, "Master")
end

ns.on("PLAYER_TARGET_CHANGED", function() ns.safe("bountyAlert", alertFor, "target") end)
ns.on("UPDATE_MOUSEOVER_UNIT", function() ns.safe("bountyAlert", alertFor, "mouseover") end)
ns.on("NAME_PLATE_UNIT_ADDED", function(_, unit) ns.safe("bountyAlert", alertFor, unit) end)

-- --- kill claims ------------------------------------------------------------------------------

local honorPattern
local function pattern()
  if honorPattern == nil then
    honorPattern = L.honorKillPattern(_G.COMBATLOG_HONORGAIN) or false
  end
  return honorPattern or nil
end

local function kills()
  if not ns.db then return nil end
  if type(ns.db.bountyKills) ~= "table" then ns.db.bountyKills = {} end
  return ns.db.bountyKills
end

-- [[bounty id, time, victim], ...] seen by this character, for its guild sync payload (Comm.lua).
function ns.bountyKillsFor(me)
  local out = {}
  for _, k in ipairs(kills() or {}) do
    if type(k) == "table" and k[4] == me then out[#out + 1] = { k[1], k[2], k[3] } end
  end
  return #out > 0 and out or nil
end

local function onHonorKill(msg)
  if type(msg) ~= "string" or ns.isSecret(msg) then return end
  local first, surname = L.honorKillVictim(msg, pattern())
  if not first then return end
  local b, how = L.bountyFor(ns.bounties(), first, surname, nil)
  if not b or how ~= "player" then return end
  local me = ns.unitName("player")
  local list = kills()
  if not me or not list then return end
  local before = #list
  if not L.addBountyKill(list, b.id, ns.now(), first, ns.now()) then return end
  for i = before + 1, #list do list[i][4] = me end   -- the hunter, for the uploader's own `bountyKills`
  local who = L.fullName(first, surname) or first
  ns.print("|cffff5555Bounty target down: " .. who .. " (#" .. b.id .. ")|r. The kill goes to the bounty board "
    .. "with your next guild sync.")
  if ns.toast then ns.toast("Bounty claimed", who .. (b.reward and (" - " .. b.reward) or "")) end
  if ns.sendSync then ns.sendSync("bounty") end
end

ns.on("CHAT_MSG_COMBAT_HONOR_GAIN", function(_, msg) ns.safe("bountyKill", onHonorKill, msg) end)

-- --- /gf bounties -----------------------------------------------------------------------------

ns.commands = ns.commands or {}
ns.commands["bounties"] = function()
  local list = ns.bounties()
  if #list == 0 then
    ns.print("No live bounties. Post one on the guild Discord's bounty board.")
    return
  end
  ns.print(#list .. " live bounties (most wanted first):")
  for i, r in ipairs(L.bountyRows(list, ns.now())) do
    if i > 15 then
      ns.print("... and " .. (#list - 15) .. " more: /gf lb, board Bounties")
      break
    end
    ns.print(string.format("  #%d %s - %s (%s)", r.id, r.name, r.wanted, r.quip))
  end
end
ns.commands["bounty"] = ns.commands["bounties"]
