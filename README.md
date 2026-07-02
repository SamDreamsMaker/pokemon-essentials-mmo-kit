# PEMK — Pokémon Essentials MMO Kit

Turn solo **Pokémon Essentials v21.1** (running under **mkxp-z**) into a small
multiplayer game — **without editing a single core script**. PEMK is a
self-contained plugin (`Plugins/PEMK/`) that hooks in through `EventHandlers`,
`MenuHandlers` and guarded method aliases, so the fork stays updatable from
upstream Essentials.

It's built to be **simple to deploy**: play with friends over LAN from Windows,
or run a dedicated host on Linux — the same MRI 3.1 Ruby code, switched at boot
into `client` or `host` mode.

## What works today

- **Presence** — players walk the same maps together in real time (menus included).
- **Server identity & persistence** — the host assigns each account a stable id and
  stores its full game state on disk (`server_saves/<id>.rxdata`), surviving a restart.
- **Economy / badges / bag & box sync** — money, coins, BP, soot, badges and
  inventory changes are pushed to the host and server-clamped.
- **Synchronized PvP battles** — challenge another player on your map; a real,
  deterministic battle runs on both screens (host-authoritative: both players'
  choices are exchanged and the host's RNG stream is replayed by the client), and
  each player sees their own team on the player side.

## Quick start (two players on one PC)

1. Launch **`PlayMMO-debug.bat`** — your main account (it hosts).
2. Launch **`PlayMMO-guest.bat`** — a distinct, persistent second player.
3. Meet on the same map and walk around. To fight: pause menu → **Battle Player**
   → pick the other player → they accept → a synchronized battle starts.

`ROLE = :auto` makes this zero-config: the first instance binds the port and
**hosts**; the second finds it busy and **joins**. LAN / dedicated-host setup,
configuration and build-packaging are documented in the plugin README.

## Docs

- **SDK guide, configuration & LAN/deploy:** [`Plugins/PEMK/README.md`](Plugins/PEMK/README.md)
- **Architecture & conversion audit:** [`docs/architecture/MMO_CONVERSION_AUDIT.md`](docs/architecture/MMO_CONVERSION_AUDIT.md)

## Base engine

PEMK is built on **Pokémon Essentials v21.1** (© Maruno & the Essentials team) and
is a fork of [maruno17/pokemon-essentials](https://github.com/Maruno17/pokemon-essentials).
The engine's own scripts live in `Data/Scripts/`; PEMK never touches them, so the
fork can still pull upstream improvements. The game bundles Nintendo-derived
assets, so keep builds to **private tests**, not public distribution.
