# PEMK — Pokémon Essentials MMO Kit

Turn solo **Pokémon Essentials v21.1** (running under **mkxp-z**) into a small
multiplayer game — **without editing a single core script**. PEMK is a
self-contained client plugin (`Plugins/PEMK/`) that hooks in through
`EventHandlers`, `MenuHandlers` and guarded method aliases, so the fork stays
updatable from upstream Essentials.

The game **client** talks to a **dedicated authoritative server** — a standalone
**MRI Ruby + PostgreSQL** process in [`server/`](server/) that owns accounts and
all player data. The client never hosts: you deploy the server once and point
every client at it. This is the split that lets the server become the source of
truth for money, items and Pokémon (and, on the roadmap, gameplay itself).

## What works today

- **Accounts & login** — create an account in-game with an **email + password**;
  a session token logs you straight back in on later launches.
- **Presence** — players walk the same maps together in real time (menus
  included), with same-map fan-out on the server.
- **Server-authoritative economy** — money, coins, BP and soot live in a
  server-side append-only ledger; the client mirrors changes and the server
  clamps them. Tampering with the local number doesn't stick.
- **Server-authoritative badges & bag** — badges (bitmask) and the whole bag
  inventory are stored on the server and **restored at login**, not trusted from
  the save file.
- **Dupe-proof Pokémon** — every owned Pokémon is minted a **server UID**; the
  server tracks ownership so a Pokémon can't be duplicated.
- **Server-authoritative trading** — trade Pokémon with another player through an
  **atomic ownership swap** on the server (either both sides move or neither
  does), safe against duplication and disconnect mid-trade.
- **Event-driven auto-save** — progress is checkpointed automatically at safe
  moments (no manual Save): important changes flush within a second, ambient
  state on a short timer, plus a backstop when the window closes.
- **Synchronized PvP battles** — challenge another player on your map; a real,
  deterministic battle runs on both screens (the challenger's RNG stream is
  authoritative and replayed by the other side), each seeing their own team.

## Quick start (two players on one PC)

**One-time:** install the server. On Windows this runs under WSL Debian — the
full step-by-step (WSL, then a single setup script) is in
[`docs/INSTALL-WINDOWS.md`](docs/INSTALL-WINDOWS.md). In short:

```bash
# inside WSL Debian, from the repo's server/ folder:
bash bin/setup.sh        # one-time: installs Ruby+Postgres, creates the dev DB
```

**Every session:**

1. Double-click **`PlayMMO-server.bat`** to start the dedicated server (Ruby +
   Postgres in WSL) and **leave the window open**. Clients connect to
   `127.0.0.1:9998`.
2. Double-click **`PlayMMO-debug.bat`** — at the load screen pick **Create
   account**, enter an **email + password**, then play the intro (it sets your
   character name).
3. Double-click **`PlayMMO-guest.bat`** — a second window (`PEMK_GUEST=1`,
   reads `mmo_config_guest.txt`); create a **different** account so the two
   windows are two players.
4. Meet on the same map and walk around. To fight: pause menu → **Battle Player**
   → pick the other → they accept → a synchronized battle starts. To trade: pause
   menu → **Trade Player**.

## Docs

- **Install from scratch on Windows (novice-friendly):** [`docs/INSTALL-WINDOWS.md`](docs/INSTALL-WINDOWS.md)
- **Client SDK guide, configuration & LAN/deploy:** [`Plugins/PEMK/README.md`](Plugins/PEMK/README.md)
- **Dedicated server (ops, tests, schema):** [`server/README.md`](server/README.md)
- **Security model & anti-cheat roadmap:** [`docs/ARCHITECTURE-SECURITY.md`](docs/ARCHITECTURE-SECURITY.md)
- **Architecture & conversion audit:** [`docs/architecture/MMO_CONVERSION_AUDIT.md`](docs/architecture/MMO_CONVERSION_AUDIT.md)

## Where the authority is today

The server owns **accounts, the durable save, the economy ledger, badges, the
bag, and Pokémon identity/ownership** — those are genuinely server-side and
tamper-resistant. **Gameplay** (movement, wild encounters, battle outcomes) is
still computed on the clients and only relayed, so today it's a *trusted-players*
model. Making gameplay itself server-authoritative — interaction-distance checks,
server-side interactive-object and spawn data, server-side battles — is the
Milestone 4 roadmap, laid out in [`docs/ARCHITECTURE-SECURITY.md`](docs/ARCHITECTURE-SECURITY.md).

## Base engine

PEMK is built on **Pokémon Essentials v21.1** (© Maruno & the Essentials team) and
is a fork of [maruno17/pokemon-essentials](https://github.com/Maruno17/pokemon-essentials).
The engine's own scripts live in `Data/Scripts/`; PEMK never touches them, so the
fork can still pull upstream improvements. The game bundles Nintendo-derived
assets, so keep builds to **private tests**, not public distribution.
