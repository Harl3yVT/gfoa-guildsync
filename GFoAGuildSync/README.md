# GFoA Guild Sync (WoW: Forever addon)

Guild tools for Gay Furries of Azeroth. Works for every guild member with no setup and no officer rights.

**Nothing intrusive.** No pop-ups, no chat posts, no sounds, no tours, nothing that opens by itself. Everything is a
passive tooltip line, a window you open yourself, or the minimap button. The addon only reads game state and writes
SavedVariables; it never acts for you, never types in chat and never edits guild notes.

![Guild window with alts grouped under their main](docs/screenshot-guild-window.png)
<!-- screenshot placeholder: guild window, "Group alts under their main" ticked -->

## Features

- **Guild crafters in tooltips**: "Guild can craft: Testy (Tailoring 285), Other" on items, "Guild already knows it"
  on recipes (Pattern:, Plans:, Formula: ...), and "Reagent for: Runecloth Bag" on reagents your characters use.
- **Ask guild crafters**: Alt+right-click an item (bags, chat links) and pick "Ask guild crafters". The request goes
  to officers' addons and from there to the guild Discord's crafting channel. Nothing is sent until you click it.
  Or `/gfoa ask <shift-click the item>`. The item tooltip then shows "Asked guild crafters 5m ago".
- **Guild window** (`/gfoa guild`): roster with class colours, Discord check marks and "alt of"; filters for online,
  class, role, level range and search; optional "Group alts under their main".
- **Alts everywhere**: "Altname is Thrall's alt" and "Alts: ..." on player tooltips and guild window rows;
  " (Thrall's alt)" after chat lines from alts (display only).
- **Profession cooldowns** (`/gfoa cd`): your characters' Mooncloth / transmutes, plus guildmates whose addons share
  theirs ("ready now" first).
- **Levelling buddy** (`/gfoa level`): XP/hour, time to the next level and to 60, rested XP, and the guild's
  **race to 60** with levels gained in the last 7 days.
- **Guildie finder** (`/gfoa finder`): guild members online within 3 levels of you, filter by class and role.
- **My stats** (`/gfoa stats`, private): dungeon runs, bosses, deaths, time per level, gold earned and spent. Kept only
  in your per-character settings file and never sent anywhere.
- **Attunements and pre-raid checklist** (`/gfoa attune`): attunements across your characters, and for the current
  character a checklist (level 60, attunements, Aqual Quintessence, Drakefire Amulet, Onyxia Scale Cloak). Items are
  only checked while the window is open.
- **My characters** (`/gfoa chars`): Discord link status per character, with **Show import code**, Options and
  minimap buttons.
- Dungeon runs, raid attendance and loot history, and the export string for the Discord "Import from addon" button.

![Item tooltip with Guild can craft](docs/screenshot-tooltip.png)
<!-- screenshot placeholder: item tooltip with "Guild can craft" and "Reagent for" -->

![Levelling window](docs/screenshot-levelling.png)
<!-- screenshot placeholder: Levelling window with race to 60 -->

## Install

Easiest: **WowUp** (beta channel 2.24+ knows WoW: Forever) > Get Addons > Install from URL >
`https://github.com/Harl3yVT/gfoa-guildsync`, or **CurseForge** once the project is approved. Both update it for
you. When a guildmate's addon is newer, `/gfoa` and the Options page say so (nothing pops up).

By hand:

1. Download the zip (green **Code** button > **Download ZIP**, or the release zip).
2. Extract it and put the `GFoAGuildSync` folder in `World of Warcraft\_forever_\Interface\AddOns`
   (so you have `...\AddOns\GFoAGuildSync\GFoAGuildSync.toc`). The `sample` and `tests` folders can be left out.
3. Start the game (or type `/reload` if it's running). If the AddOns list says "out of date", tick
   **Load out of date AddOns**.

## Commands

| Command | What it does |
|---|---|
| `/gfoa` | Status: roster scan, counts, XP/hour, Discord data, errors, "new version is out" |
| `/gfoa guild` | Guild window (also: right-click the minimap button) |
| `/gfoa cd` | Profession cooldowns: yours and guildmates' |
| `/gfoa level` | Levelling buddy and guild race to 60 |
| `/gfoa finder` | Guildie finder (online, +-3 levels) |
| `/gfoa stats` | My stats (private) |
| `/gfoa chars` | My characters: Discord link status, Show import code |
| `/gfoa attune` | Attunements and pre-raid checklist |
| `/gfoa dungeons` | Your dungeon runs (21 days) |
| `/gfoa ask ITEM` | Ask guild crafters for a shift-clicked item |
| `/gfoa xp` | XP/hour, next level and time to 60 |
| `/gfoa export` | Export your characters for the Discord ("Import from addon") |
| `/gfoa link CODE` | Link this WoW account to your Discord (code from the guild Discord panel > Link game account); `/gfoa link` shows the status |
| `/gfoa unlink` | Remove the link code |
| `/gfoa main` | Make the logged-in character your main |
| `/gfoa options` | Options page (also in Esc > Options > AddOns) |
| `/gfoa show` | Toggle the small status window |
| `/gfoa minimap` | Show or hide the minimap button |
| `/gfoa alts` | Alt names after chat lines on/off |
| `/gfoa sync` / `/gfoa sync now` | Guild sync status / send this character now |
| `/gfoa officer on\|off\|auto` | Officer mode (store what members' addons send); auto = on if you can read officer notes |
| `/gfoa roster` | Ask the server for the guild roster now |
| `/gfoa lootmin N` | Record raid loot of quality N and up (3 rare, 4 epic, 5 legendary) |
| `/gfoa quest ID` | Is quest ID flagged completed on this character? (for finding attunement quest ids) |
| `/gfoa reset yes` | Delete all saved sync data on this PC |

Minimap button: left-click opens a menu of every window, right-click opens the guild window, drag moves it.

## Options

Esc > Options > AddOns > GFoA Guild Sync (per character): every tooltip line, the chat alt suffix, check marks,
guild sync, Alt+right-click "Ask guild crafters", cooldown sharing, minimap button, status window, loot quality,
officer mode, and this character's Discord link status with **Show import code**. The **Link code** box, **Save**
and **This is my main** set the account-wide link code and main (same as `/gfoa link CODE` and `/gfoa main`).

## Discord linking (1.4.0)

Type `/gfoa link CODE` once (code from the guild Discord panel > **Link game account**). Every character on that WoW
account then sends the code with its guild sync, and the bot registers it to you by itself: your main if you have
none, else an alt. Log in on each character once. `/gfoa main` on your main tells the bot which one it is. A
character already registered to someone else is never moved.

## What it saves and sends

- `GFoAGuildSyncDB` (account): guild roster, your characters (level, XP, professions, recipes, cooldowns, gear ids,
  attunement flags, money), dungeon runs, raids and loot. Officer mode only: what members' addons sent
  (`guildSync`, 30 days) and craft requests (`craftRequests`, 7 days). The highest addon version heard from
  guildmates (`newestSeen`, version string only). Your Discord link code and chosen main (`link`, `main`), which
  also go out with guild sync and the export.
- `GFoAGuildSyncCache` (account, never uploaded): reagents from your profession windows, guildmates' shared
  cooldowns, daily roster levels for the race to 60.
- `GFoAGuildSyncSettings` (per character, never uploaded): options, window positions and **My stats**.
- Hidden guild addon messages, at most one per second: your logged-in character, link code and main for officers'
  addons (guild sync),
  craft requests you click, and that character's profession cooldowns (only cooldown recipe names and time left,
  plus your addon version).
  Each can be turned off in the options.

The Discord parts need the optional `GFoAGuildSyncBotData.lua` file in your account's SavedVariables folder plus the
small `GFoAGuildSyncBotData` companion addon (no code; it only tells WoW to load that file). Without them the addon
shows nothing extra. The addon never changes that file.

## Export for Discord

`/gfoa export` (or **Show import code**) shows a string like `GFOA1.1a2b3c4d.eyJ...` with your own characters on this
PC (up to 10; never the guild roster, raids or loot). Press Ctrl+A, Ctrl+C and paste it in the guild Discord:
panel > Import from addon. Long exports come in parts ("Part 1/3"): paste each part in its own box, in order.

## Development

- Pure logic (`Logic.lua`, `Codec.lua`) has tests: `lua tests/test_logic.lua` (stock Lua 5.1), or with
  [lune](https://github.com/lune-org/lune): `lune run tests/run_lune.luau tests/test_logic.lua`.
- `tests/make_fixture.lua` prints the `guildSync` example string used in `sample/GFoAGuildSync.lua`.
- `sample/` holds example SavedVariables files (`GFoAGuildSync.lua`, `GFoAGuildSyncBotData.lua`). WoW does not load them.

## In-game test list

1. Login: no red errors, nothing pops up; `/gfoa` lists status.
2. `/gfoa guild`: filters (online, class, role, level, search) work; "Group alts under their main" puts alts under
   the main with a dash; hovering an alt says "X is Y's alt", a main lists "Alts: ...".
3. Hover a crafted item someone knows: "Guild can craft: Name (Prof skill)". Hover a recipe: "Guild already knows it".
   After opening Tailoring once, hover Runecloth: "Reagent for: ...".
4. Alt+right-click a bag item: small menu; "Ask guild crafters" sends; the tooltip then says "Asked guild crafters".
   An officer's `/gfoa sync` shows "1 craft requests". Cancel sends nothing.
5. `/gfoa cd` on two guildmates with the addon: each sees the other's Mooncloth / transmute under "Guild".
6. `/gfoa level`: XP/hour after 10 minutes, next level and 60 times, rested; race to 60 lists the guild.
7. `/gfoa finder`: online members within 3 levels; class / role buttons filter.
8. `/gfoa stats`: die once, earn some gold, `/reload`: numbers stay.
9. `/gfoa attune`: checklist ticks Drakefire Amulet etc. when carried (open the bank once for banked items).
10. `/gfoa chars`: link status per character; Show import code opens the export.
11. Esc > Options > AddOns > GFoA Guild Sync: every checkbox works and survives `/reload`.
12. `/gfoa link abc-234` says saved (`ABC234`); `/gfoa link` and `/gfoa` show it; `/gfoa link 0OO` says it isn't a
    code; Options > Link code + Save does the same; This is my main sets `main`; `/gfoa unlink` clears it.
