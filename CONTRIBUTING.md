# Contributing: Sephya's leaderboard (GayFurriesLeaderboard)

This repo ships **GFoA Guild Sync** to CurseForge. Sephya's **Gay Furries of Azeroth Leaderboard** is bundled in the
same download, with Sephya's OK, so leaderboard updates reach players through Guild Sync releases.

- **Sephya** (`SepiHub`) owns `GayFurriesLeaderboard/` and sends changes as pull requests.
- **Harley** (`Harl3yVT`) reviews, merges and releases. A release is a `v*` tag, which uploads to CurseForge
  automatically, so only Harley tags.

If you are Claude helping Sephya, read this whole file first. It is the brief.

## Layout

```
GFoAGuildSync/            Harley's addon (do not edit; ask in the PR if you need something from it)
GFoAGuildSyncBotData/     data the Discord bot sends back to the addon (do not edit)
GayFurriesLeaderboard/    Sephya's addon: GayFurriesLeaderboard.lua + .toc
GayFurriesLeaderboard/tests/   stub-harness tests (not loaded by WoW, not shipped)
.pkgmeta, .github/        packaging and release (do not edit)
```

## Workflow

1. `git clone https://github.com/Harl3yVT/gfoa-guildsync` (Sephya has write access, so no fork is needed).
2. `git switch -c sephya/<short-topic>` from an up-to-date `main`. Never commit to `main` directly.
3. Edit only files under `GayFurriesLeaderboard/`.
4. Run the tests (below). They must all pass. Add a test for each behaviour you change.
5. Bump `## Version:` in `GayFurriesLeaderboard/GayFurriesLeaderboard.toc` (semver; this is the leaderboard's own
   version, separate from Guild Sync's).
6. Push the branch and open a PR to `main` with `gh pr create`. In the description: what changed and why, how you
   tested it (tests, and in game if you did), and whether saved data changed (see the rules).
7. **Do not** push tags, create GitHub releases, edit `.github/` or `.pkgmeta`, or touch CurseForge.
   Harley merges, bumps Guild Sync's version and tags the release.

Want something in the Guild Sync side (its Leaderboards view, `/gf lb`, the Discord bot)? Say so in the PR or open an
issue; Harley's side handles it.

## Rules that keep the guild's data working

The Discord bot reads the officers' `SavedVariables/GayFurriesLeaderboard.lua` (uploaded by a companion tool) and
Guild Sync reads the same data for its own Leaderboards view. Breaking these breaks the Discord boards.

1. **Keep the saved data shape.** These fields are read outside the addon and must keep their names and meaning:
   - `members["First Surname"] = { total, weekly, week, class, dTotal, dWeekly, gold, updated }`
     (`gold` in copper, `-1` when hidden; `week` = `floor((t - 5*86400 - 15*3600) / 604800)`, reset Tue 15:00 UTC)
   - `duels[] = { w, l, wc, lc, t }`, `rolls[] = { w, l, t, bet }` (newest 300 duels / 500 rolls kept)

   Adding new fields is fine. Renaming, removing or changing units is not, unless agreed with Harley in the PR first.
2. **Keep the comm prefix `GPVPLB`** and stay compatible with the message format older copies send: guild members
   update at different times.
3. **Keep code marked `-- GFoA`.** Those lines are fixes and integration Harley's side made (listed below). Change
   them only if you mean to, and say so in the PR.
4. **WoW Forever specifics** (interface `16001`, level cap 60): characters have a first name *and* a surname.
   `UnitName("player")` returns the surname as its second value (not a realm). Names in the data are full
   `"First Surname"` strings.
5. **No secrets or personal info** in the repo. It is public.

## What the `-- GFoA` changes do

- **Per-character counters** (`Char()`, `db.chars[name]`): SavedVariables are account-wide, so deaths, kill bases
  and weekly bases are kept per character; alts no longer add to the main.
- **Roster requests skipped** while `GFoAGuildSync` is loaded (it already asks every minute).
- **World PvP kills only**; battleground kills are not counted. "dishonorable kill" is not a kill.
- **Weekly kills clamp at 0** when a lower kill count is read.
- **Hidden Mode** (`/gpvp gold off`) also hides your own saved gold entry.
- **Deathrolls**: losses by the player who opened the roll are recorded; trade bets skip old rolls instead of stopping.

Background and the not-yet-built suggestions (REQ throttling, rolling the week before counting, pruning old
members) are in Harley's audit notes; ask Harley if you want them.

## Tests

The tests load the real `GayFurriesLeaderboard.lua` against fake WoW globals and drive it through events, comm
messages and `/gpvp`. One test also loads `GFoAGuildSync/Logic.lua`, so run them from a full checkout.

With a stock Lua 5.1:

```
lua GayFurriesLeaderboard/tests/test_leaderboard.lua
```

Or with [lune](https://github.com/lune-org/lune) (no Lua 5.1 needed):

```
lune run GayFurriesLeaderboard/tests/run_lune.luau GayFurriesLeaderboard/tests/test_leaderboard.lua
```

The last line prints `N passed, 0 failed`. Tests named `KNOWN:` pin current behaviour of a listed, unfixed problem;
if you fix one, update that test.

## Testing in game

Copy the three folders `GFoAGuildSync`, `GFoAGuildSyncBotData` and `GayFurriesLeaderboard` into
`World of Warcraft\_forever_\Interface\AddOns\` (replacing the CurseForge copies), then `/reload`. Note that a
`/reload` saves SavedVariables from the *old* code before loading the new files, so reload twice when testing saved
data.
