-- GFoA Guild Sync: guild event reminders from the Discord schedule (GFoAGuildSyncBotData.events).
--   * the minimap button shows the next event as a small countdown ("2h") and its tooltip names it
--   * off by default: one chat line (only you see it) 30 and 5 minutes before each event; /gf reminders on
--   * /gf events lists what's coming
-- The Discord data is only as fresh as the uploader's last run: an event added on Discord after that shows up after
-- the next upload and /reload.
local _, ns = ...
local L = ns.logic

function ns.upcomingEvents(max)
  local d = ns.discordData()
  return L.upcomingEvents(d and d.events, ns.now(), max)
end

function ns.nextEvent()
  return ns.upcomingEvents(1)[1]
end

-- Lines for the minimap tooltip (next event and the staleness note), or {}.
function ns.eventTooltipLines()
  local e = ns.nextEvent()
  if not e then return {} end
  local out = { "Next guild event: " .. L.eventLabel(e) .. " in " .. L.formatDuration(e.start - ns.now()) }
  local stale = L.staleHint((ns.discordData() or {}).generated, ns.now())
  if stale then table.insert(out, stale) end
  return out
end

-- The minimap button's countdown text, or nil.
function ns.eventCountdownText()
  if not ns.opt("minimapCountdown", true) then return nil end
  local e = ns.nextEvent()
  return e and L.shortCountdown(e.start - ns.now()) or nil
end

local function remind()
  if ns.updateMinimapCountdown then ns.updateMinimapCountdown() end
  if not ns.opt("eventReminders", false) or not ns.cache then return end
  ns.cache.eventReminded = L.pruneSent(ns.cache.eventReminded, ns.now())
  for _, due in ipairs(L.dueReminders(ns.upcomingEvents(), ns.now(), ns.cache.eventReminded)) do
    local mins = math.max(1, math.ceil((due.event.start - ns.now()) / 60))
    ns.print(ns.ui.PINK .. L.eventLabel(due.event) .. "|r starts in " .. mins .. (mins == 1 and " minute" or " minutes")
      .. ns.ui.MUTED .. " (guild Discord schedule)|r")
  end
end

ns.commands["events"] = function()
  local list = ns.upcomingEvents(10)
  if #list == 0 then
    ns.print(ns.discordData() and "no guild events coming up in the Discord data"
      or "no Discord data on this PC (it comes with the uploader), so no guild events")
    return
  end
  for _, e in ipairs(list) do
    ns.print(L.eventLabel(e) .. ": in " .. L.formatDuration(e.start - ns.now())
      .. (date and ("  " .. ns.ui.MUTED .. date("%a %H:%M", e.start) .. "|r") or ""))
  end
  local stale = L.staleHint((ns.discordData() or {}).generated, ns.now())
  if stale then ns.print(stale) end
end

ns.commands["reminders"] = function(arg)
  if arg == "on" or arg == "off" then
    ns.setOpt("eventReminders", arg == "on")
  else
    ns.setOpt("eventReminders", not ns.opt("eventReminders", false))
  end
  ns.print("guild event reminders " .. (ns.opt("eventReminders", false) and "on (30 and 5 minutes before)" or "off"))
end

ns.on("PLAYER_LOGIN", function() ns.after(20, "eventsFirst", remind) end)
ns.every(30, "eventReminders", remind)
