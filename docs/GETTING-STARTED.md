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

## Understand what you're running (deeper docs)

- **Project overview & what works today:** [`README.md`](../README.md)
- **The MMO client plugin (config, how the SDK hooks in):** [`Plugins/PEMK/README.md`](../Plugins/PEMK/README.md)
- **The dedicated server (operations, tests, database):** [`server/README.md`](../server/README.md)
- **Security model & anti-cheat roadmap:** [`docs/ARCHITECTURE-SECURITY.md`](ARCHITECTURE-SECURITY.md)
- **Server-authoritative battles (design):** [`docs/LAYER-D-BATTLE-DESIGN.md`](LAYER-D-BATTLE-DESIGN.md)

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
