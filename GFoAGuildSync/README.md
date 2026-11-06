# GFoA Guild Sync (WoW: Forever addon)

Guild tools for Gay Furries of Azeroth. Works for every guild member with no setup and no officer rights.

**Nothing intrusive.** No pop-ups, no chat posts, no sounds, no tours, nothing that opens by itself. Everything is a
passive tooltip line, a window you open yourself, or the minimap button. Nothing prints to chat or pops up unless you
turn it on: event reminders, the craft-request line and toasts are all off by default (Options or `/gf`). The addon
only reads game state and writes SavedVariables; it never acts for you, never types in chat and never edits guild notes.

![Guild window with alts grouped under their main](docs/screenshot-guild-window.png)
<!-- screenshot placeholder: guild window, "Group alts under their main" ticked -->

## Features

- **Full names**: windows, tooltips and the chat alt note show characters as "First Surname" (WoW: Forever) when
  the guild roster or your own characters know the surname; saved data and Discord stay keyed by first name.
- **Guild crafters in tooltips**: "Guild can craft: Testy (Tailoring 285), Other" on items, "Guild already knows it"
  on recipes (Pattern:, Plans:, Formula: ...), and "Reagent for: Runecloth Bag" on reagents your characters use.
- **Ask guild crafters**: Alt+right-click an item (bags, chat links) and pick "Ask guild crafters". The request goes
  to officers' addons and from there to the guild Discord's crafting channel. Nothing is sent until you click it.
  Or `/gf ask <shift-click the item>`. The item tooltip then shows "Asked guild crafters 5m ago".
- **Guild window** (`/gf guild`): roster with class colours, Discord check marks and "alt of"; filters for online,
  class, role, level range and search; optional "Group alts under their main".
- **Leaderboard** (bundled, by Sephya): GayFurriesLeaderboard comes in the same download with its own window,
  minimap button, settings and `/gpvp` command: PvP kills, deaths, gold, duels and deathrolls. The guild window's
  "Sephya's window" button opens it. It skips its own roster requests while Guild Sync is running.
  The guild window's **Roster | Leaderboards** switch shows its boards (PvP, deaths, gold, duels, deathrolls) in our
  window too, your row in pink. PvP and deaths show this week and the total side by side (click either header to
  rank by it). People who left the guild are hidden (tick **Former members** to show them); read only, it never
  changes Sephya's data.
  Our minimap menu lists "Guild leaderboards" (that view, also `/gf lb`) and "Leaderboard (Sephya's)" (its own window) when it's loaded. Options can hide its minimap button ("Hide the
  Leaderboard minimap button", off by default). Player tooltips show your record against that player from its
  data, e.g. "You vs them: duels 3-1 · deathrolls 2-0" (your wins-losses; no line when you have none).
- **Alts everywhere**: "Altname is Thrall's alt" and "Alts: ..." on player tooltips and guild window rows;
  " (Thrall's alt)" after chat lines from alts (display only).
- **Profession cooldowns** (`/gf cd`): your characters' Mooncloth / transmutes, plus guildmates whose addons share
  theirs ("ready now" first).
- **Levelling buddy** (`/gf level`): XP/hour, time to the next level and to 60, rested XP, and the guild's
  **race to 60** with levels gained in the last 7 days.
- **Guildie finder** (`/gf finder`): guild members online within 3 levels of you, filter by class and role.
- **My stats** (`/gf stats`, private): quests and mob kills, XP from quests / kills / exploring, best XP/hour session,
  gold earned and spent by source (loot, quests, vendor, AH/mail; repairs, trainers, flights, vendor), items looted
  by quality and your first epic, skill-ups per profession, fish caught, dungeon runs and bosses, deaths per zone
  and level, flights, hearthstones, sessions and the longest one, time per level. No combat log. Kept only in your
  per-character settings file.
- **Share my stats** (`/gf stats share on`, or the Options checkbox; **off by default**): copies a small totals
  block (quests, deaths, dungeons, flights, first epic and so on, **no gold** unless you also type
  `/gf stats share gold on`) into the saved data and guild sync so the guild Discord can post fun leaderboards
  (`/stats leaderboard`). `/gf stats share off` removes you from the boards at your next sync.
- **Attunements and pre-raid checklist** (`/gf attune`): attunements across your characters, and for the current
  character a checklist (level 60, attunements, Aqual Quintessence, Drakefire Amulet, Onyxia Scale Cloak). Items are
  only checked while the window is open.
- **My characters** (`/gf chars`): Discord link status per character, with **Show import code**, Options and
  minimap buttons.
- **Discord info without the uploader**: members whose PC doesn't get `GFoAGuildSyncBotData.lua` receive the same
  Discord data (check marks, alts, roles, crafters, surnames, link status) from an officer's addon, in the background.
  `/gf` says where yours came from; Options can turn it off.
- **Raid night** (`/gf ready`): for your raid group or the guild online, who's ready, who isn't 60, who isn't attuned
  and who has no addon data, plus tanks / healers / DPS against the raid size (Barrow Deeps 10, Hyjal Summit 20,
  Onyxia's Lair 40). The in-game twin of the Discord's `/raid ready`.
- **Guild event reminders**: the next event from the Discord schedule counts down under the minimap button ("2h")
  and in its tooltip. Off by default: `/gf reminders on` adds a chat line only you see 30 and 5 minutes before.
  `/gf events` lists them. Only as fresh as the
  Discord data file (the uploader's last run, then a `/reload`).
- **Who can craft this?** Hold Shift while you hover an item, or click an item link in chat: every guild crafter,
  online first.
  `/gf who <shift-click item>` does it in chat.
- **Craft requests for you** (`/gf crafts`): "Ask guild crafters" requests one of your characters can make, with
  Dismiss. Optional (off by default): one chat line at login when there are some.
- **Toasts** (`/gf toasts on`, **off by default**): a small note that fades by itself when one of your characters
  moves up a guild leaderboard or a guildie reaches 60.
- Dungeon runs, raid attendance and loot history, and the export string for the Discord "Import from addon" button.

![Item tooltip with Guild can craft](docs/screenshot-tooltip.png)
<!-- screenshot placeholder: item tooltip with "Guild can craft" and "Reagent for" -->

![Levelling window](docs/screenshot-levelling.png)
<!-- screenshot placeholder: Levelling window with race to 60 -->

## Install

Easiest: **CurseForge**: https://www.curseforge.com/wow/addons/gfoa-guild-sync (the CurseForge app, or
**WowUp-CF** beta 2.24+ searching "GFoA Guild Sync"). Both update it for you. When a guildmate's addon is newer, `/gf` and the Options page say so (nothing pops up).

By hand:

1. Download the zip (green **Code** button > **Download ZIP**, or the release zip).
2. Extract it and put the `GFoAGuildSync` folder in `World of Warcraft\_forever_\Interface\AddOns`
   (so you have `...\AddOns\GFoAGuildSync\GFoAGuildSync.toc`). The `sample` and `tests` folders can be left out.
3. Start the game (or type `/reload` if it's running). If the AddOns list says "out of date", tick
   **Load out of date AddOns**.

**After an update:** one `/reload` (or a restart) loads the new version, and it says so in chat. WoW only saves
addon data when you `/reload` or log out, using the code that was running at that moment, so the data the new
version collects reaches Discord at your *next* `/reload` or logout. Easiest: update while the game is closed.

## Commands

The old `/gfoa` still works and does the same thing as `/gf`.

| Command | What it does |
|---|---|
| `/gf` | Status: roster scan, counts, XP/hour, Discord data, errors, "new version is out" |
| `/gf guild` | Guild window (also: right-click the minimap button) |
| `/gf lb` | Guild window on its Leaderboards view (Sephya's boards: PvP, deaths, gold, duels, deathrolls) |
| `/gf cd` | Profession cooldowns: yours and guildmates' |
| `/gf level` | Levelling buddy and guild race to 60 |
| `/gf finder` | Guildie finder (online, +-3 levels) |
| `/gf stats` | My stats (private) |
| `/gf stats share on\|off` | Share your stats totals (no gold) for the Discord leaderboards; off by default. `/gf stats share gold on\|off` adds gold earned |
| `/gf chars` | My characters: Discord link status, Show import code |
| `/gf attune` | Attunements and pre-raid checklist |
| `/gf dungeons` | Your dungeon runs (21 days) |
| `/gf ask ITEM` | Ask guild crafters for a shift-clicked item |
| `/gf ready` | Raid night: who in your group (or the guild online) is ready for the raid |
| `/gf events` | Upcoming guild events from the Discord schedule |
| `/gf reminders on\|off` | Chat reminders 30 and 5 minutes before guild events (off by default) |
| `/gf who ITEM` | Every guild crafter for a shift-clicked item, online first |
| `/gf crafts` | Craft requests your characters can make, with Dismiss |
| `/gf toasts on\|off` | Toasts for leaderboard moves and guildies reaching 60 (off by default) |
| `/gf xp` | XP/hour, next level and time to 60 |
| `/gf export` | Export your characters for the Discord ("Import from addon") |
| `/gf link CODE` | Link this WoW account to your Discord (code from the guild Discord panel > Link game account); `/gf link` shows the status |
| `/gf unlink` | Remove the link code |
| `/gf main` | Make the logged-in character your main |
| `/gf options` | Options page (also in Esc > Options > AddOns) |
| `/gf show` | Toggle the small status window |
| `/gf minimap` | Show or hide the minimap button (drag it to move it; `/gf minimap reset` puts it back bottom-right) |
| `/gf alts` | Alt names after chat lines on/off |
| `/gf sync` / `/gf sync now` | Guild sync status / send this character now |
| `/gf officer on\|off\|auto` | Officer mode (store what members' addons send); auto = on if you can read officer notes |
| `/gf roster` | Ask the server for the guild roster now |
| `/gf lootmin N` | Record raid loot of quality N and up (3 rare, 4 epic, 5 legendary) |
| `/gf quest ID` | Is quest ID flagged completed on this character? (for finding attunement quest ids) |
| `/gf chatlog on\|off` | Write the game's chat log for the guild chat relay (needs the PC tool). Guild chat then posts to Discord in a batch when you log out, not live. Tell your guild first. |
| `/gf questid` | List the quest ids in your quest log (to fill in `attunements` in `Config.lua`) |
| `/gf api` | Which game APIs/events this client has, and the current instance (for bug reports on Forever) |
| `/gf reset yes` | Delete all saved sync data on this PC |

Minimap button: left-click opens a menu of every window, right-click opens the guild window, drag moves it.

## Options

Esc > Options > AddOns > GFoA Guild Sync (per character; the page scrolls on small screens): every tooltip line, the chat alt suffix, check marks,
guild sync, Alt+right-click "Ask guild crafters", cooldown sharing, minimap button, status window, loot quality,
officer mode, and this character's Discord link status with **Show import code**. The **Link code** box, **Save**
and **This is my main** set the account-wide link code and main (same as `/gf link CODE` and `/gf main`).

## Discord linking (1.4.0)

Type `/gf link CODE` once (code from the guild Discord panel > **Link game account**). Every character on that WoW
account then sends the code with its guild sync, and the bot registers it to you by itself: your main if you have
none, else an alt. Log in on each character once. `/gf main` on your main tells the bot which one it is. A
character already registered to someone else is never moved.

## What it saves and sends

- `GFoAGuildSyncDB` (account): guild roster, your characters (level, XP, professions, recipes, cooldowns, gear ids,
  attunement flags, money), dungeon runs, raids and loot. Officer mode only: what members' addons sent
  (`guildSync`, 30 days) and craft requests (`craftRequests`, 7 days). The highest addon version heard from
  guildmates (`newestSeen`, version string only). Your Discord link code and chosen main (`link`, `main`), which
  also go out with guild sync and the export.
- `GFoAGuildSyncCache` (account, never uploaded): reagents from your profession windows, guildmates' shared
  cooldowns, daily roster levels for the race to 60, and Discord data relayed by an officer's addon (`botData`).
- `GFoAGuildSyncSettings` (per character, never uploaded): options, window positions and **My stats**. Only when
  you turn on `/gf stats share` does a totals block (`sharedStats`, no gold by default) go into your character in
  `GFoAGuildSyncDB` and your guild sync payload.
- Hidden guild addon messages, at most one per second: your logged-in character (with its attunement names, 1.5.3+),
  link code and main for officers' addons (guild sync),
  craft requests you click, and that character's profession cooldowns (only cooldown recipe names and time left,
  plus your addon version), and a tiny "my Discord data is from <time>" request when yours is missing or over 12 hours
  old (at most every 30 minutes). Officers' addons with the uploader file answer it with a whispered copy, sharing the
  same one-message-per-second limit.
  Each can be turned off in the options.

The Discord parts need the optional `GFoAGuildSyncBotData.lua` file in your account's SavedVariables folder plus the
small `GFoAGuildSyncBotData` companion addon (no code; it only tells WoW to load that file). Without them the addon
asks officers' addons for a copy (see above; only accepted from guild ranks 0-2 in your roster), and otherwise shows
nothing extra. The addon never changes that file.

## Export for Discord

`/gf export` (or **Show import code**) shows a string like `GFOA1.1a2b3c4d.eyJ...` with your own characters on this
PC (up to 10; never the guild roster, raids or loot). Press Ctrl+A, Ctrl+C and paste it in the guild Discord:
panel > Import from addon. Long exports come in parts ("Part 1/3"): paste each part in its own box, in order.

## Development

- Pure logic (`Logic.lua`, `Codec.lua`) has tests: `lua tests/test_logic.lua` (stock Lua 5.1), or with
  [lune](https://github.com/lune-org/lune): `lune run tests/run_lune.luau tests/test_logic.lua`.
- `tests/make_fixture.lua` prints the `guildSync` example string used in `sample/GFoAGuildSync.lua`.
- `sample/` holds example SavedVariables files (`GFoAGuildSync.lua`, `GFoAGuildSyncBotData.lua`). WoW does not load them.

## In-game test list

1. Login: no red errors, nothing pops up; `/gf` lists status.
2. `/gf guild`: filters (online, class, role, level, search) work; "Group alts under their main" puts alts under
   the main with a dash; hovering an alt says "X is Y's alt", a main lists "Alts: ...".
3. Hover a crafted item someone knows: "Guild can craft: Name (Prof skill)". Hover a recipe: "Guild already knows it".
   After opening Tailoring once, hover Runecloth: "Reagent for: ...".
4. Alt+right-click a bag item: small menu; "Ask guild crafters" sends; the tooltip then says "Asked guild crafters".
   An officer's `/gf sync` shows "1 craft requests". Cancel sends nothing.
5. `/gf cd` on two guildmates with the addon: each sees the other's Mooncloth / transmute under "Guild".
6. `/gf level`: XP/hour after 10 minutes, next level and 60 times, rested; race to 60 lists the guild.
7. `/gf finder`: online members within 3 levels; class / role buttons filter.
8. `/gf stats`: die once, earn some gold, `/reload`: numbers stay. Kill a mob, turn in a quest, discover a zone:
   kills / quest / exploring XP go up once each (not also under "other"). Sell to a vendor, repair, train, fly:
   each lands under its own gold line. Loot an item: the quality count goes up. Skill up, fish, hearth: counted.
   `/gf stats share on`, wait a minute, `/reload`: the saved file has `sharedStats` without gold; `/gf stats share off`
   leaves `sharedStats = { off = true }`.
9. `/gf attune`: checklist ticks Drakefire Amulet etc. when carried (open the bank once for banked items).
10. `/gf chars`: link status per character; Show import code opens the export.
11. Esc > Options > AddOns > GFoA Guild Sync: every checkbox works and survives `/reload`.
Forever-specific checks (professions window, dungeon run, raid group): `docs/forever-test-checklist.md` in the
bot repo.

12. `/gf link abc-234` says saved (`ABC234`); `/gf link` and `/gf` show it; `/gf link 0OO` says it isn't a
    code; Options > Link code + Save does the same; This is my main sets `main`; `/gf unlink` clears it.
13. Bot data relay (two players): an officer (guild rank 0-2) with the uploader file online; a guildmate on a PC
    without the file logs in. About 25-60 s later the guildmate's `/gf` says "Discord data: ... via <officer>'s
    addon" and the guild window shows check marks and alts; the officer's `/gf` says "shares it (1 sent)". Nothing
    shows in either chat. Untick "Get Discord info from guild officers' addons": the copy is no longer used.
14. `/gf ready` in a raid group: everyone listed once under Ready / Not 60 / Not attuned / No addon data, role
    counts and "N/size ready"; Raid: picks Barrow Deeps / Hyjal Summit / Onyxia's Lair; Guild online lists the
    online roster instead. With Discord data that has `events`: the minimap button shows "2h" etc., its tooltip
    names the event, `/gf events` lists them; no chat line until `/gf reminders on`, then one 30 and 5 minutes
    before (once, also after `/reload`). Hold Shift, then hover a crafted item: "Guild crafters (online first)". `/gf crafts` lists requests your
    characters can make; Dismiss hides one for good. `/gf toasts on` shows a test toast that fades or closes on click.
