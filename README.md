# GFoA Guild Sync

A WoW: Forever addon for the **Gay Furries of Azeroth** guild. It works for every guild member with no setup and no
officer rights.

**Nothing intrusive.** No pop-ups, no chat posts, no sounds, nothing that opens by itself. Everything is a tooltip
line, a window you open yourself, or the minimap button. The addon only reads game state and writes its own
SavedVariables. It never acts for you.

## Features

- **Guild crafters in tooltips**: "Guild can craft: Name (Tailoring 285)" on items, "Guild already knows it" on
  recipes, "Reagent for: ..." on reagents.
- **Ask guild crafters**: Alt+right-click an item and pick "Ask guild crafters". Nothing is sent until you click.
- **Guild window** (`/gfoa guild`): class colours, filters (online, class, role, level, search), alts grouped under
  their main.
- **Alts everywhere**: "X is Y's alt" on player tooltips and guild window rows.
- **Profession cooldowns** (`/gfoa cd`): yours and guildmates' who share theirs.
- **Levelling buddy** (`/gfoa level`): XP/hour, time to next level and to 60, rested XP, and the guild's race to 60.
- **Guildie finder** (`/gfoa finder`): guild members online within 3 levels of you, by class and role.
- **My stats** (`/gfoa stats`, private): dungeons, bosses, deaths, time per level, gold earned and spent.
- **Attunements and pre-raid checklist** (`/gfoa attune`).
- **My characters** (`/gfoa chars`): Discord link status, and **Show import code** for the guild Discord's
  "Import from addon" button.
- Dungeon runs, raid attendance and loot history (data only).

Full command list, options and what the addon saves: [GFoAGuildSync/README.md](GFoAGuildSync/README.md).

## Install

1. Download `GFoAGuildSync-vX.Y.Z.zip` from the [latest release](../../releases/latest).
2. Extract it into `World of Warcraft\_forever_\Interface\AddOns`, so you end up with
   `...\AddOns\GFoAGuildSync\GFoAGuildSync.toc`.
3. Start the game (or `/reload`). If the AddOns list says "out of date", tick **Load out of date AddOns**.

Type `/gfoa` in game to check it's running.

## Releases

Pushing a tag `vX.Y.Z` that matches `## Version` in `GFoAGuildSync/GFoAGuildSync.toc` builds the zip (with the
`GFoAGuildSync` folder at the zip root) and publishes the release.
