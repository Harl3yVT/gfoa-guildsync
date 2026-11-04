-- GFoA Guild Sync: settings you may want to edit.
local _, ns = ...

ns.config = {
  -- Attunements: a character counts as attuned when ANY of the listed quest ids is completed.
  -- These are Classic Era quest ids; WoW: Forever ids must be confirmed in game
  -- (/gfoa quest <id> prints whether the current character has that quest flagged).
  attunements = {
    { name = "Onyxia", quests = { 6502, 6602 } },         -- Drakefire Amulet (A) / Blood of the Black Dragon Champion (H)
    { name = "Molten Core", quests = { 7848 } },          -- Attunement to the Core
    { name = "Blackwing Lair", quests = { 7761 } },       -- Blackhand's Command
  },

  -- Default minimum loot quality to record (0 poor .. 3 rare, 4 epic, 5 legendary). /gfoa lootmin N changes it.
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
