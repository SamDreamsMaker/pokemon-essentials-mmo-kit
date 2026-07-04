# PEMK — Pokémon Essentials MMO Kit (v21.1, mkxp-z)

A plugin that turns solo Pokémon Essentials into a small multiplayer game
**without editing a single core script** — everything hooks in through
`EventHandlers`, `MenuHandlers` and guarded method aliases, so the fork stays
updatable from upstream.

The game **client** (this plugin, under mkxp-z) connects to a **dedicated
authoritative server** — a standalone Ruby + PostgreSQL process (see
[`server/`](../../server/)) that owns accounts and all player data. The client
never hosts: deploy the server once, point every client at it.

> **Status (Milestones 1–3 — dedicated authoritative backend):**
> - **Accounts & auth** — **email + password** login against the server; a session
>   token reconnects on later launches; the old impersonatable claimed-id is gone.
> - **Durable saves** — your game state lives in **Postgres** on the server and is
>   reloaded at login (the client's local save is only an offline fallback). The
>   server stores the save as an opaque blob it never deserialises.
> - **Server-authoritative economy / badges / bag** — money, coins, BP, soot,
>   badges and the whole inventory are mirrored to the server, clamped, and
>   **restored at login** — not trusted from the save file.
> - **Dupe-proof Pokémon** — every owned Pokémon carries a **server-issued UID**;
>   the server tracks ownership so a Pokémon can't be duplicated.
> - **Server-authoritative trading** — trade Pokémon through an **atomic ownership
>   swap** on the server (both sides move or neither does), safe against duplication
>   and mid-trade disconnects.
> - **Event-driven auto-save** — progress is checkpointed automatically at safe
>   frames (no manual Save): urgent changes flush within a second, ambient state on
>   a short timer, with a window-close backstop.
> - **Presence** — same-map players see each other in real time (zone-scoped
>   fan-out on the server).
> - **PvP battles** — challenge a same-map player; a deterministic battle runs on
>   both screens (the challenger's RNG is authoritative, each sees their own team),
>   full teams with mid-round switches in sync — relayed through the server.
>
> Full design + roadmap in
> [`docs/architecture/MMO_CONVERSION_AUDIT.md`](../../docs/architecture/MMO_CONVERSION_AUDIT.md),
> the security model in
> [`docs/ARCHITECTURE-SECURITY.md`](../../docs/ARCHITECTURE-SECURITY.md), and
> server ops in [`server/README.md`](../../server/README.md).

## Quick start (two players on one PC)

1. **Start the server** — double-click **`PlayMMO-server.bat`** (runs the
   dedicated Ruby + Postgres server in WSL) and leave the window open. First time
   on this machine, install the server once with
   [`docs/INSTALL-WINDOWS.md`](../../docs/INSTALL-WINDOWS.md) (WSL + `bin/setup.sh`).
   For a real deployment use `docker compose up` in [`server/`](../../server/) instead.
2. Double-click **`PlayMMO-debug.bat`** — at the load screen pick **Create
   account**, enter an **email + password**, then play through the intro (that
   sets your character's name).
3. Double-click **`PlayMMO-guest.bat`** — a second window (`PEMK_GUEST=1`) that
   reads `mmo_config_guest.txt`; create a **different** account so the two windows
   are two players.
4. Get both onto the same map and walk around — each appears in the other's world.
5. To battle: pause menu → **Battle Player** → pick the other → they accept → a
   synchronized battle runs on both screens.

The account is created **in-game** and its session token is remembered, so later
launches log straight in. Progress is stored on the **server** (Postgres), not in
a local file.

## Configuration — `mmo_config.txt`

The client always connects to the dedicated server. Point it there with a
plain-text `mmo_config.txt` in the game folder (`#` starts a comment):

```ini
host = 127.0.0.1        # the server's IP (a friend's/host's LAN IP for LAN play)
port = 9998

# Optional DEV shortcut: pre-fill credentials to skip the in-game login screen.
# Accounts are keyed by email. Leave commented for the normal in-game flow.
# email = you@example.com
# password = your-password
```

A guest instance (`PlayMMO-guest.bat`, `PEMK_GUEST=1`) reads `mmo_config_guest.txt`
instead, so two windows on one PC can be two accounts. Compile-time defaults live
in `001_Net/001_NetConfig.rb` (`HOST`, `PORT`); `ENABLED`/`ROLE = :off` disables
the plugin (pure vanilla).

### Playing with friends (LAN / internet)

1. **Host the server** on one machine: run it with `PEMK_BIND=0.0.0.0` (the
   Docker compose default) and allow the port through the firewall. On LAN, share
   your IPv4 (`ipconfig`); over the internet, port-forward the TCP port and share
   your public IP.
2. **Each friend** sets `mmo_config.txt` → `host = <server IP>`, runs `Game.exe`,
   and creates their account in-game.

> Baseline transport is plain TCP — keep it to **LAN / a trusted network (e.g.
> Tailscale)**; a public deployment should terminate **TLS** at a reverse proxy
> (a client still Marshal-loads its own save + a peer's battle team, so a MITM
> without TLS is a client-side RCE risk). The game bundles Nintendo-derived
> assets, so keep builds to private tests, not public distribution.

## Architecture

```
001_Net/     Config            central settings
             MessageCodec      split framing: safe primitive envelope + opaque body
             NetClient         one TCP connection, non-blocking, main-thread poll
002_Server/  (retired)         RelayServer / ServerStore / ServerLogic — the old
                               in-process host, superseded by the dedicated server/
                               (Ruby + Postgres). Kept for reference only.
003_Game/    Session           connects to the dedicated server; self id = account id
             RemotePlayer      Game_Character subclass for other players (+ Remotes registry)
             Presence          builds/emits the local player's position (step/turn/heartbeat)
             Dispatch          routes inbound messages
             Hooks             EventHandlers + the Graphics.update alias (the pump)
             NetStatus         reconnect FSM + player-facing connection notices
004_Persist/ Auth              token / email login handshake; hydrates server state
             AuthUI            in-game login / create-account screen (email + password)
             PersistHooks      Game.load/save aliases; server-authoritative load screen
             Economy/Badges/Inventory  observe local changes -> notify the server (M2)
             Monsters          server-issued Pokémon UIDs: mint / find / evict / materialize (M3)
             Checkpoint        event-driven auto-save: arms + flushes checkpoints at safe frames
006_Sync/    Sync              coalescing dirty-set; mark_econ/badge/inv/mon -> arm a checkpoint
                               + T2 blob projection (party/position), gated during a trade
007_Trade/   Trade            player-to-player trade state machine (pause-menu option),
                               escrow + untradeable gate; the swap is committed server-side
005_Battle/  Challenge         the challenge / accept handshake (pause-menu option)
             BattleSetup       exchange parties on accept, then launch
             BattleLauncher    build the battle on Marshal copies (no save side effects)
             BattleScenePump   stream the host's RNG each frame during a battle
             BattleNet         battle-stream transport + per-frame inbound queues
             NetBattles        HostBattle / ClientBattle (role-based)
             BattleChoiceSync  exchange each side's human choice per round
             BattleRngSync     the host's authoritative RNG stream, replayed by the client
             BattleSwitchSync  mid-round replacement picks (faints, U-turn) across the mirror
```

**The pump model.** Measured mkxp-z behaviour forced this design (audit §4): its
scheduler starves threads spawned off the main thread and `IO.select` misses
pending connections on a listening socket. So all socket I/O is **non-blocking
and driven from the main thread** once per frame via `Pump.tick`. It runs from a
single alias of **`Graphics.update`** — the one method called exactly once per
frame in *every* scene, so the network (and presence heartbeats) stay alive in the
overworld, in battles, and inside full-screen menus (Bag, Pokédex, Party…) alike,
with no double-pumping. `Pump.tick` no-ops until a game is loaded (`$player`), so
the title/load screen is untouched; login pumps manually. The client runs no
background game threads — the authoritative server is a separate process.

**How PvP battles stay in sync.** Each instance runs its *own* battle with its own
team as party 1, so the untouched scene shows each player their own perspective.
The two are made byte-identical by making one side **authoritative**: the
**challenger** hosts (records every `pbRandom` draw and streams it; the accepter
replays those exact values instead of calling `rand`), and both players' per-round
choices are exchanged as compact index tuples — all relayed through the dedicated
server. This is the `RecordedBattle` record/replay pattern, streamed live. Battles
run on Marshal **copies** with `internalBattle = false`, so real parties, Exp,
money and the Pokédex are never touched.

## Known limits

- **Gameplay is still client-computed (not yet anti-cheat).** The server now owns
  accounts, the durable save, and — genuinely server-authoritative — the **economy
  ledger, badges, bag, and Pokémon identity/ownership + trading** (M2–M3). But
  **movement, wild encounters and battle outcomes are still computed on the
  clients** and only relayed, so gameplay itself remains a *trusted-players* model.
  Interaction-distance checks, server-side world-object/spawn data, and
  server-side battles are the Milestone 4 roadmap — see
  [`docs/ARCHITECTURE-SECURITY.md`](../../docs/ARCHITECTURE-SECURITY.md) for
  exactly what is and isn't secured today.
- **`Marshal` on the wire — host closed, small client-side residual.** The host
  never `Marshal.load`s an untrusted frame: it routes on a self-contained
  primitive-codec envelope and rejects legacy whole-Marshal frames, while deep
  graphs (saves, teams) ride as opaque bodies it stores/forwards without decoding.
  The only remaining `Marshal.load` of a peer-influenced graph is on the **client**
  — its own save, or a team it is about to battle — the accepted residual of the
  trusted-host model.
- **Debug-mode boot stack.** Loading server state at the debug boot used to
  intermittently hit an mkxp-z `SystemStackError` (load-only, a relaunch
  recovered). The wire-hardening shrank the load-path stack (no repro in 55
  launches) and the debug launchers now set `RUBY_THREAD_VM_STACK_SIZE` for ~16×
  more VM-stack headroom (measured); release builds were always far less exposed.

## Diagnostics

Session and battle events are written to `mmo.log` in the game root (both
instances on one PC share it, which is handy for reading both sides at once).
