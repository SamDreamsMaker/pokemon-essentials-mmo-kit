# Getting started — from zero to running

Welcome. This is the **one page to start from nothing**. It gets you from an empty
PC to either **playing/testing** the game or **developing** it (adding maps,
Pokémon, encounters…). It doesn't repeat the detailed guides — it puts them in
order and tells you which parts you actually need.

First, the mental model. There are **two programs**:

```
  The GAME (a Windows app)                 The SERVER (Linux, runs in WSL)
  Game.exe — the mkxp-z client   ──TCP──▶  owns accounts, money, items,
  you double-click to play                 Pokémon, and (increasingly) the
                                           game rules themselves
```

You run **both** on your PC for local testing. The game is the client; the server
is the source of truth. That split is the whole point — it's what makes cheating
hard and lets many players share one world.

---

## What's already in the box (you do NOT download it separately)

This project is a **complete fork of Pokémon Essentials v21.1** — everything to
**play** is bundled in the project folder:

| In the folder | What it is |
|---|---|
| `Game.exe`, `mkxp.json` | the **mkxp-z** runtime — runs the game with no extra install |
| `Graphics/ Audio/ Data/ PBS/ Fonts/` | all the game's resources (already here) |
| `Plugins/PEMK/` | the MMO plugin (the multiplayer/anti-cheat layer) |
| `PEMK.rxproj` | the **RPG Maker XP** project — open this to *edit* maps/events |
| `server/` | the dedicated authoritative server (Ruby + PostgreSQL) |
| `PlayMMO-*.bat` | double-click launchers (server / your player / a 2nd player) |

So: **you do not need to download Pokémon Essentials or any "resource pack"
separately** — it's all in here. (`eeveeexpo.com/essentials` is the *home of
Essentials itself* — its wiki, tutorials and community — worth bookmarking to
learn the engine, but not required to run this project.)

---

## Step 0 — Get the project onto your PC

Get the whole project folder (ask the maintainer for access, then `git clone` it,
or download it as a ZIP and extract). Put it somewhere simple — the `C:` drive is
easiest. A path with spaces is fine (`C:\Pokemon Essentials MMO Kit`), just keep
the quotes when a command needs the path.

> The game bundles Nintendo-derived assets, so this stays a **private project** —
> don't distribute builds publicly. See *Credits & licensing* at the bottom.

---

## Path A — I just want to PLAY / TEST

You need the **server** running, then you launch the game. **No RPG Maker, no
editor** — `Game.exe` runs everything.

1. **Install the server once.** It's a Linux program; on Windows it runs inside
   **WSL** (a Linux that ships with Windows — no separate PC). The full
   click-by-click walkthrough for a total beginner is here:
   **▶ [`docs/INSTALL-WINDOWS.md`](INSTALL-WINDOWS.md)** (~20–30 min, mostly
   unattended). It boils down to one command: `bash bin/setup.sh` inside WSL.

2. **Every session:**
   - Double-click **`PlayMMO-server.bat`** → the server starts (a console window);
     **leave it open**. Clients connect to `127.0.0.1:9998`.
   - Double-click **`PlayMMO-debug.bat`** → the game opens; at the load screen pick
     **Create account** (email + password) and play the short intro.
   - (Optional, two players on one PC) double-click **`PlayMMO-guest.bat`** → a
     second window; create a **different** account so it's a second player.

3. **Play together / with friends over the network:** covered in
   [`docs/INSTALL-WINDOWS.md`](INSTALL-WINDOWS.md#playing-with-friends-over-the-network)
   (firewall, LAN IP, or Tailscale). The client's server address lives in
   **`mmo_config.txt`** (`host` / `port`).

That's the whole "click and play" loop.

---

## Path B — I want to DEVELOP (add maps, Pokémon, encounters…)

Do everything in Path A first (you still need the server to test). Then:

### The developer loop
```
  edit content  ─▶  launch PlayMMO-debug.bat  ─▶  mkxp-z recompiles what changed
                    (Game.exe "debug" mode)       AND auto-exports it to the server
                                                  ─▶  you test it live
```
`PlayMMO-debug.bat` runs the game in **debug mode** (the `debug` argument): it
enables the F9 debug menu, recompiles any data you changed, and — thanks to the
MMO kit — **automatically regenerates the server's data files** (`server/data/
world.json`, `battle_data.json`) so the server always sees your latest maps and
tables. **You never run a manual export.** Restart the server (`PlayMMO-server.bat`)
to pick up the regenerated data.

Debug mode online is the server's call (`PEMK_CLIENT_DEBUG`): the dev server that
`PlayMMO-server.bat` starts allows it, so F9 works while you test. A server left at
its default (`deny`) keeps debug mode off on every client that logs in - players get
no F9, no walking through walls, whatever their launch or an event says.

### What you edit with what

- **Game DATA — species, moves, abilities, items, trainers, and wild
  `encounters` (grass tables):** just edit the text files in **`PBS/`** with any
  editor (VS Code, Notepad++). They recompile on the next debug launch. **No RPG
  Maker needed.**

- **MAPS, events, tilesets, and the game's structure:** these need the visual
  editor, **RPG Maker XP** — a paid app on **Steam** (often on sale). Install it,
  then open **`PEMK.rxproj`** in it. Pokémon Essentials (and therefore this
  project) is built on RPG Maker XP; that's the only thing RPG Maker is for here —
  **playing never needs it**, only visual editing does. Learn the editor + engine
  at **[eeveeexpo.com/essentials](https://eeveeexpo.com/essentials)** (the
  Essentials wiki and tutorials).

### The one rule that keeps the project clean

**Never edit the core engine in `Data/Scripts/`.** All the MMO/multiplayer code
lives in **`Plugins/PEMK/`** and hooks in without touching Essentials, so the base
engine can still be updated from upstream. If you're adding behaviour, add it as a
PEMK plugin file, not a core-script edit.

---

## (Advanced) Running the battle anti-cheat at scale

Everything ships **off by default** — you never need any of this to run a server.
The anti-cheat is opt-in per feature via `PEMK_*` env flags, each ramping
`off → shadow → on` so you watch telemetry before anything acts. The battle-engine
tier (D7/D8) adds one moving part beyond the server: a **replay worker** that
re-simulates recorded battles on the real engine, in a **separate process** (it
loads the whole game engine — never the live server).

**The recommended ramp (weeks, not minutes):**

1. `PEMK_BATTLE_ENFORCE_ENCOUNTERS=on` — the server mints wild encounters (needed
   for seeds). Then `PEMK_BATTLE_ENFORCE_RNG=shadow` for ~2 weeks: clients record
   battles, the server verifies the RNG seed. Watch the corpus parity:

   ```bash
   # in server/, one-shot — replays pending records and prints per-cohort parity
   bundle exec ruby bin/pemk_replay.rb
   ```

2. When parity is ~100% for your engine build(s), flip `PEMK_BATTLE_ENFORCE_RNG=on`
   and run the replay worker as a **daemon** (a compose service / systemd unit):

   ```bash
   PEMK_REPLAY_LOOP=300 bundle exec ruby bin/pemk_replay.rb   # boot once, poll every 5 min
   ```

3. Only then consider D8 enforcement — its **own** flag, so `rng=on` never silently
   becomes rejection. Start in shadow: `PEMK_BATTLE_ENFORCE_RESIM=shadow` audits
   what it *would* quarantine (`enforcement_events` rows, `would_quarantine`) without
   touching anything. When the audit is clean, `=on`: a seed-refuted catch is
   quarantined after `PEMK_RESIM_MIN_STRIKES` (default 2) distinct refuted battles —
   the mon stays fully playable, only **un-tradeable** (and later ranked-ineligible).
   Nothing is ever destroyed; EXP/money are untouched.

**Operator console** (reversal is the whole point — undo a false positive in one command):

```bash
bundle exec ruby bin/pemk_quarantine.rb list            # quarantined mons
bundle exec ruby bin/pemk_quarantine.rb show <uid>      # full evidence + audit trail
bundle exec ruby bin/pemk_quarantine.rb pardon <uid>    # un-quarantine (one UPDATE)
bundle exec ruby bin/pemk_quarantine.rb reports         # open review queue
```

**No replay worker?** Then keep `PEMK_BATTLE_ENFORCE_RESIM=off` (or `shadow`): the
seed walk still refutes forged rolls at ingest, and everything else stays
detection-only. If you turn `resim=on` but never run the worker, honest catches
just wait out a 60-minute trade hold — never a permanent block. The server logs a
loud warning if replayable records pile up with no verdict.

Full design + honest limits: [`docs/LAYER-D-BATTLE-DESIGN.md`](LAYER-D-BATTLE-DESIGN.md).

## (Advanced) Server-owned story progression

`PEMK_FLAG_STATE` (off by default) lets the server keep the story progression it
has seen saved and hand it back at login, so a lost or rolled-back save no longer
re-arms gym leaders, gifts and one-shot events. Ramp it like the others:

1. `PEMK_FLAG_STATE=shadow` — the server records the story state and restores
   nothing. Play for a while and read the server log: `DELTA DRIFT` should not
   appear, and `SUSPECT rewind` should only name real rollbacks.
2. `PEMK_FLAG_STATE=on` — saved progression comes back at every login.
3. `PEMK_FLAG_ENFORCE=shadow`, then `on` — the server also holds the tracked
   switches and variables during play: a value changed without the game's own
   events (a memory or save edit) is put back to the server's. In `shadow` the log
   shows `WOULD-REPAIR` lines; honest play should produce none.
4. `PEMK_GIFT_ENFORCE=shadow`, then `on` — events ask the server before they give an
   item, and a one-shot gift (a gym leader's TM) is paid once per account, on its
   event's own map. In `shadow` the log shows `WOULD-DENY` lines; honest play should
   produce none.
5. `PEMK_SHOP_ENFORCE=shadow`, then `on` — Mart purchases and sales, and Battle Point
   exchanges, are made by the server: it checks the clerk's stock and the price, and
   takes or pays the money (or the BP) itself. In `shadow` the log shows `WOULD-DENY`
   lines; honest play should produce none.
6. `PEMK_ITEM_AUTHORITY=shadow` — every item the player gains must come from a source
   the server knows (a granted pickup, a paid gift, a purchase, a trade). The log shows
   `UNEXPLAINED` lines for the others. Items your game can produce unseen (berries,
   what wild Pokemon hold, a vending machine, a computed prize...) are found in your own
   events and data and left out of the judgment; the boot line `item tiers:` says how
   many and why. Turning steps 4 and 5 on first leaves more items to judge. If a plugin
   of yours gives items in its own code, list them in `PEMK_ITEM_LOCAL`.
7. `PEMK_ITEM_AUTHORITY=on` — what the server cannot explain is taken back from the
   player's possession. It needs `PEMK_PICKUP_ENFORCE=on` and steps 4 and 5 `on`; the
   boot log says what is missing, and runs `shadow` until then. Go there only once
   `shadow` has shown no `UNEXPLAINED` line from honest play, and once every event the
   boot `WARNING` names as giving items it cannot tell (a Mystery Gift, a computed
   gift) has its items in `PEMK_ITEM_LOCAL`.

A separate setting protects players from each other: `PEMK_PEER_CHECK=shadow`, then
`on`, checks a Pokemon another player sends (a trade, a PvP team) before it is
loaded. If your plugins store their own objects inside a Pokemon, add those classes
to `PEMK_PEER_CLASSES` first, or `shadow` will name them in `WOULD-REFUSE` lines.

There is nothing to declare in RPG Maker: which switches count as progression is
worked out from your own events. After updating the kit, do one debug launch
before restarting the server: the export picks up the new format on its own.
Details and limits: [`docs/ARCHITECTURE-SECURITY.md`](ARCHITECTURE-SECURITY.md)
(section *Story state*).

## Moderation: banning an account

The detections above name accounts; this is how you act on one. From `server/`, with
the server's `DATABASE_URL` (an account is named by its id or its email):

```bash
bundle exec ruby bin/pemk_admin.rb show player@example.com          # the account, its bans, its flags
bundle exec ruby bin/pemk_admin.rb ban player@example.com --days 7 duplicating items
bundle exec ruby bin/pemk_admin.rb ban 42                           # no end: until lifted
bundle exec ruby bin/pemk_admin.rb bans                             # the bans in force
bundle exec ruby bin/pemk_admin.rb unban 42
```

A ban ends the account's sessions at once. A player who is online is told until when
and why, and the server closes the connection within ten seconds; the game then stays
offline. The next login is refused with the same notice, once the password is right,
so a stranger learns nothing. Nothing is deleted: a lifted ban stays on record with
who set it and who lifted it (`PEMK_OPERATOR` names you in the record; the default
is your shell user). A game older than this feature just shows "Login failed: banned".

## Understand what you're running (deeper docs)

- **Project overview & what works today:** [`README.md`](../README.md)
- **The MMO client plugin (config, how the SDK hooks in):** [`Plugins/PEMK/README.md`](../Plugins/PEMK/README.md)
- **The dedicated server (operations, tests, database):** [`server/README.md`](../server/README.md)
- **Security model & anti-cheat roadmap:** [`docs/ARCHITECTURE-SECURITY.md`](ARCHITECTURE-SECURITY.md)
- **Server-authoritative battles (design):** [`docs/LAYER-D-BATTLE-DESIGN.md`](LAYER-D-BATTLE-DESIGN.md)
- **Automated in-game testing (autopilot + autotest scenarios):** [`docs/AUTOTEST.md`](AUTOTEST.md)

---

## Quick "which do I need?"

| Goal | Server (WSL) | RPG Maker XP | Edit `PBS/` | `Game.exe` |
|---|:---:|:---:|:---:|:---:|
| Play / test the game | ✅ | — | — | ✅ (debug) |
| Add/tweak species, moves, **grass encounters**, items | ✅ | — | ✅ | ✅ (debug) |
| Make/edit maps, events, tilesets | ✅ | ✅ | (optional) | ✅ (debug) |

---

## Credits & licensing

This project is a fork of **[Pokémon Essentials](https://github.com/Maruno17/pokemon-essentials)**
v21.1 (© Maruno & the Essentials team), which runs on **RPG Maker XP** and is
supported by the community at **[eeveeexpo.com/essentials](https://eeveeexpo.com/essentials)**.
The game includes Nintendo/Game Freak-derived assets, so keep everything to
**private, non-commercial testing** — do not distribute builds publicly.
