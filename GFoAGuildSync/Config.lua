-- GFoA Guild Sync: settings you may want to edit.
local _, ns = ...

ns.config = {
  -- Attunements: THE one table to edit when quest ids are confirmed. A character counts as attuned when ANY of the
  -- listed quest ids is completed. An entry with an empty `quests` list is a placeholder: it shows "?" and is never
  -- checked. Find ids in game: pick up / finish the quest, then `/gf questid` lists the ids in your quest log and
  -- `/gf quest <id>` says whether this character has that id flagged completed. See docs/forever-test-checklist.md.
  attunements = {
    -- Classic Era ids (correct on Classic Era; confirm they're the same on WoW: Forever).
    { name = "Onyxia", quests = { 6502, 6602 } },         -- Drakefire Amulet (A) / Blood of the Black Dragon Champion (H)
    { name = "Molten Core", quests = { 7848 } },          -- Attunement to the Core
    { name = "Blackwing Lair", quests = { 7761 } },       -- Blackhand's Command
    -- WoW: Forever raids (open 2026-12-09). Ids unknown until the quests exist in game; leave {} until confirmed.
    { name = "Barrow Deeps", quests = {} },               -- 10-player; may have no attunement at all
    { name = "Hyjal Summit", quests = {} },               -- 20-player; may have no attunement at all
  },

  -- Default minimum loot quality to record (0 poor .. 3 rare, 4 epic, 5 legendary). /gf lootmin N changes it.
  lootMinQuality = 4,

  -- Raid and loot history older than this many days is pruned.
  keepDays = 21,

  -- Seconds between raid attendance snapshots while inside a raid instance.
  raidSnapshotInterval = 300,

  -- Minimum seconds between guild roster scans (and roster requests).
  rosterInterval = 60,

  -- A raid visit continues (same key) if you re-enter the same instance within this many seconds.
  raidVisitGap = 1800,

  -- A dungeon run continues (same key) if you re-enter the same instance within this many seconds.
  dungeonRunGap = 1800,

  -- XP/hour is only written once the play session is at least this long.
  xpMinSessionSeconds = 600,

  -- A /reload or quick relog within this many seconds keeps the XP/hour session going.
  xpSessionResume = 300,

  -- Officer mode keeps members' guild sync payloads this many days.
  guildSyncKeepDays = 30,

  -- Officer mode keeps "Ask guild crafters" requests this many days.
  craftRequestKeepDays = 7,

  -- Guildie finder: online guild members within this many levels of you.
  finderRange = 3,

  -- Pre-raid checklist (shown only in the Attunements window, nothing is checked while it's closed). A row is
  -- ticked when you carry (or have in the bank) ANY of the item ids. Classic Era ids; confirm on Forever.
  preRaid = {
    { name = "Aqual or Eternal Quintessence (Molten Core runes)", items = { 17333, 22754 } },
    { name = "Drakefire Amulet (Onyxia)", items = { 16309 } },
    { name = "Onyxia Scale Cloak (Nefarian, BWL)", items = { 15138 } },
  },
}
