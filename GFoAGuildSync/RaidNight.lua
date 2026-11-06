-- GFoA Guild Sync: raid-night panel (/gf ready), the in-game twin of the bot's /raid ready.
-- For your raid group (or the guild members online): who is ready, who isn't 60, who isn't attuned, who has no
-- addon data, plus the tank / healer / DPS count against the raid size. Opened only by the player; reads only what
-- the addon already has (group / roster, your own characters, officers' guild sync payloads, the Discord data).
local _, ns = ...
local L = ns.logic

local source = "group"   -- "group" or "guild"
local raidPick           -- nil = pick from the zone / last choice / group size

-- Decoded guild sync payload characters by first name (officer addons only), rebuilt when guildSync changes.
local syncedChars, syncedSig
local function synced()
  local gs = ns.db and ns.db.guildSync
  if type(gs) ~= "table" then return nil end
  local n, latest = 0, 0
  for _, e in pairs(gs) do
    n = n + 1
    if type(e) == "table" and (e.t or 0) > latest then latest = e.t end
  end
  local sig = n .. ":" .. latest
  if sig ~= syncedSig then
    local out = {}
    for _, e in pairs(gs) do
      local payload = type(e) == "table" and L.decodeExport(e.data)
      for _, c in ipairs(payload and payload.chars or {}) do
        if type(c) == "table" and type(c.n) == "string" then out[c.n] = c end
      end
    end
    syncedChars, syncedSig = out, sig
  end
  return syncedChars
end

local function unitBase(unit)
  if not ns.call("UnitExists", unit) then return nil end
  local name = ns.unitName(unit)
  if type(name) ~= "string" or ns.isSecret(name) then return nil end
  local _, class = ns.call("UnitClass", unit)
  return { name = name, level = ns.plain(ns.call("UnitLevel", unit)), class = ns.plain(class), online = true }
end

-- { { name, level, class } } of the current raid or party, you included. Empty when not in a group.
local function groupMembers()
  local out = {}
  local inRaid = ns.call("IsInRaid")
  if inRaid == nil and ns.api("GetNumRaidMembers") then inRaid = (ns.call("GetNumRaidMembers") or 0) > 0 end
  if inRaid then
    local n = ns.call("GetNumGroupMembers") or ns.call("GetNumRaidMembers") or 0
    for i = 1, n do
      local name, _, _, level, _, class, _, online = ns.call("GetRaidRosterInfo", i)
      name = ns.plain(name)
      if type(name) == "string" then
        table.insert(out, { name = name, level = ns.plain(level), class = ns.plain(class), online = online })
      end
    end
    return out
  end
  local n = ns.call("GetNumSubgroupMembers") or ns.call("GetNumPartyMembers") or 0
  if n == 0 then return out end
  local me = unitBase("player")
  if me then table.insert(out, me) end
  for i = 1, math.min(4, n) do
    local p = unitBase("party" .. i)
    if p then table.insert(out, p) end
  end
  return out
end

local function guildOnline()
  local out = {}
  for _, m in ipairs(ns.db and ns.db.guild and ns.db.guild.members or {}) do
    if type(m) == "table" and m.online then table.insert(out, m) end
  end
  return out
end

function ns.raidReadiness()
  local bases = source == "group" and groupMembers() or guildOnline()
  local discord, own, sync = ns.discordData(), ns.db and ns.db.characters, synced()
  local people = {}
  for _, b in ipairs(bases) do
    local p = L.readinessPerson(b, discord, own, sync)
    if p then table.insert(people, p) end
  end
  local _, zone = ns.instanceInfo()
  local raid = raidPick or L.defaultRaid(zone, #bases, ns.settings and ns.settings.readyRaid)
  return L.raidReadiness(people, raid), #bases
end

local function nameList(list)
  local parts = {}
  for _, p in ipairs(list) do
    table.insert(parts, ns.ui.classColor(p.class) .. ns.displayName(p.name) .. "|r"
      .. (p.role and (ns.ui.MUTED .. " " .. string.sub(p.role, 1, 1) .. "|r") or ""))
  end
  return parts
end

-- Wraps names into lines of about `per` names so a 40-man list fits the window.
local function addNames(lines, list, per)
  local parts = nameList(list)
  for i = 1, #parts, per do
    local row = {}
    for j = i, math.min(i + per - 1, #parts) do table.insert(row, parts[j]) end
    table.insert(lines, "    " .. table.concat(row, ", "))
  end
end

local function build()
  local W = ns.ui
  local r, n = ns.raidReadiness()
  local lines = {}
  if n == 0 then
    return W.emptyLines(source == "group" and "You're not in a group" or "No guild members online",
      source == "group" and "Join the raid group, or switch to Guild online." or "Wait for a roster scan (a minute).")
  end
  table.insert(lines, W.PINK .. r.raid .. "|r" .. W.MUTED .. " (" .. (r.size or "?") .. "-player)  "
    .. (source == "group" and "your group" or "guild online") .. ", " .. n .. " people|r")
  table.insert(lines, L.roleLine(r))
  local sections = {
    { r.ready, W.GOOD .. "Ready|r" },
    { r.lowLevel, W.WAIT .. "Not " .. L.MAX_LEVEL .. "|r" },
    { r.notAttuned, W.WAIT .. "Not attuned: " .. tostring(r.attunement) .. "|r" },
    { r.unknown, W.MUTED .. "No addon data (attunement unknown)|r" },
  }
  for _, s in ipairs(sections) do
    if #s[1] > 0 then
      table.insert(lines, "")
      table.insert(lines, s[2] .. " (" .. #s[1] .. ")")
      addNames(lines, s[1], 6)
    end
  end
  table.insert(lines, "")
  table.insert(lines, W.MUTED .. (r.attunement and ("Attunement checked: " .. r.attunement .. ".")
    or "No attunement is tracked for this raid yet.") .. " T/H/D = Discord role.|r")
  local stale = L.staleHint((ns.discordData() or {}).generated, ns.now())
  if stale then table.insert(lines, W.MUTED .. stale .. "|r") end
  return lines
end

local win
win = ns.makeListWindow("GFoAGuildSyncReadyFrame", "Raid night: who's ready", 440, 22, "readyPos", build, 10,
  function(f, w)
    local W = ns.ui
    local raidBtn, srcBtn
    raidBtn = W.button(f, "Raid: auto", 150, 20, function()
      local items = { { text = "Auto (zone or group size)", func = function()
        raidPick = nil
        raidBtn:SetText("Raid: auto")
        w.refresh()
      end } }
      for _, raid in ipairs(L.RAIDS) do
        table.insert(items, { text = raid .. " (" .. L.RAID_SIZES[raid] .. ")", func = function()
          raidPick = raid
          if ns.settings then ns.settings.readyRaid = raid end
          raidBtn:SetText(raid)
          w.refresh()
        end })
      end
      W.popup(raidBtn, items)
    end)
    raidBtn:SetPoint("TOPLEFT", 12, -f.top)
    srcBtn = W.button(f, "My group", 100, 20, function()
      source = source == "group" and "guild" or "group"
      srcBtn:SetText(source == "group" and "My group" or "Guild online")
      w.refresh()
    end)
    srcBtn:SetPoint("LEFT", raidBtn, "RIGHT", 6, 0)
    local rescan = W.button(f, "Rescan", 70, 20, function() if ns.refreshRoster then ns.refreshRoster(true) end end)
    rescan:SetPoint("TOPRIGHT", -14, -f.top)
    return 26
  end)

function ns.toggleReady(show) win.toggle(show) end

ns.commands["ready"] = function() ns.toggleReady() end
ns.commands["raidnight"] = ns.commands["ready"]
ns.on("GROUP_ROSTER_UPDATE", function() win.refresh() end)
