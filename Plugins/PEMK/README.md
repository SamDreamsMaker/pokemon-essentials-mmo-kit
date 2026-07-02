# PEMK — Pokémon Essentials MMO Kit (v21.1, mkxp-z)

A plugin that turns solo Pokémon Essentials into a small multiplayer game
**without editing a single core script** — everything hooks in through
`EventHandlers`, `MenuHandlers` and guarded method aliases, so the fork stays
updatable from upstream.

The goal is to stay **simple to deploy**: play with friends over LAN from
Windows, or run a dedicated host on Linux — the same MRI 3.1 Ruby code, switched
at boot into `client` or `host` mode.

> **Status.** Working end to end:
> - **Presence** — players move around the same maps together, in real time.
> - **Identity & persistence** — the host assigns each account a stable id and
>   stores its full game state on disk (`server_saves/<id>.rxdata`), surviving a
>   restart.
> - **Economy / badges / bag & box sync** — money, coins, BP, soot, badges and
>   inventory changes are pushed to the host (server-clamped).
> - **PvP battles** — challenge another player on your map; a real, deterministic
>   battle runs on both screens, host-authoritative (choices exchanged + the
>   host's RNG stream replayed), each player seeing their own team. Full multi-
>   Pokémon teams: mid-round replacement switches (faints, U-turn) stay in sync.
>
> Full design + roadmap in
> [`docs/architecture/MMO_CONVERSION_AUDIT.md`](../../docs/architecture/MMO_CONVERSION_AUDIT.md).

## Quick start (two players on one PC)

1. Double-click **`PlayMMO-debug.bat`** — this is your main account (it hosts).
2. Double-click **`PlayMMO-guest.bat`** — a **distinct, persistent** second
   player (`PEMK_GUEST=1`, its own account file), so the two windows aren't the
   same person. First time, pick **New Game** on the guest.
3. Get both onto the same map and walk around — each appears in the other's world.
4. To battle: pause menu → **Battle Player** → pick the other → they accept → a
   synchronized battle starts on both screens.

`ROLE = :auto` (see `Config`) makes this zero-config: the first instance binds the
port and **hosts**; the second finds it busy and **joins** automatically.

## Configuration — `001_Net/001_NetConfig.rb`

| Setting | Meaning |
|---|---|
| `ROLE` | `:auto` (host-or-join), `:host`, `:client`, or `:off` (vanilla) |
| `HOST` | host IP a `:client` connects to (LAN IP for friends; `127.0.0.1` local) |
| `PORT` | TCP port (default `9998`) |
| `BIND_HOST` | host bind address — `127.0.0.1` (same-PC) or `0.0.0.0` (LAN) |
| `HEARTBEAT_FRAMES` | idle position re-announce interval (frames) |

### LAN play without editing Ruby — `mmo_config.txt`

Drop a plain-text `mmo_config.txt` in the game folder to override the defaults.
Any subset of keys works; `#` starts a comment:

```ini
# On the HOST machine:
role = host
bind = 0.0.0.0        # accept LAN connections (allow the Windows Firewall prompt)
port = 9998

# On each FRIEND's machine instead:
# role = client
# host = 192.168.1.42  # the host's LAN IP (host runs: ipconfig)
# port = 9998
```

Without this file, `ROLE = :auto` is used (host-or-join on `127.0.0.1`).

### Sharing a build with a friend (LAN)

1. Compile the plugin: launch once via **`PlayMMO-debug.bat`** (rebuilds
   `Data/PluginScripts.rxdata` from source).
2. Build a clean, shareable zip:
   ```
   powershell -ExecutionPolicy Bypass -File tools\package-mmo.ps1
   ```
   → `PEMK-Build-<timestamp>.zip` on your Desktop (no `.git`/docs/dev cruft; a
   `mmo_config.txt` template is included). Send it to your friend.
3. **You (host):** set `mmo_config.txt` to `role=host` + `bind=0.0.0.0`, run
   `ipconfig` for your IPv4 LAN address, allow the Windows Firewall prompt.
4. **Friend:** unzip, set `mmo_config.txt` to `role=client` + `host=<your LAN IP>`,
   run `Game.exe`.

> Internet play additionally needs the host to port-forward the TCP port and
> share their public IP. The game bundles Nintendo-derived assets, so keep builds
> to private tests, not public distribution.

## Architecture

```
001_Net/     Config            central settings
             MessageCodec      split framing: safe primitive envelope + opaque body
             NetClient         one TCP connection, non-blocking, main-thread poll
002_Server/  RelayServer       accept thread + main-thread pump; routes addressed
                               frames to one recipient, presence to all
             ServerStore       per-account Marshal save files (server_saves/<id>.rxdata)
             ServerLogic       login / save / mutation validation (money/badges clamps)
003_Game/    Session           connection lifecycle (host/join), self id, logging
             RemotePlayer      Game_Character subclass for other players (+ Remotes registry)
             Presence          builds/emits the local player's position (step/turn/heartbeat)
             Dispatch          routes inbound messages
             Hooks             EventHandlers + the Graphics.update alias (the pump)
004_Persist/ Auth              blocking login at the load screen; server state hydration
             PersistHooks      Game.load/save aliases; push saves to the host
             Economy/Badges/Inventory  mirror local changes to the host, server-clamped
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
the title/load screen is untouched; login pumps manually. The only background
thread is the relay's blocking `accept` loop.

**How PvP battles stay in sync.** Each instance runs its *own* battle with its own
team as party 1, so the untouched scene shows each player their own perspective.
The two are made byte-identical by making the **host authoritative**: both
players' per-round choices are exchanged as compact index tuples, and the host
records every `pbRandom` draw and streams it to the client, which replays those
exact values instead of calling `rand`. This is the `RecordedBattle` record/replay
pattern, streamed live. Battles run on Marshal **copies** with `internalBattle =
false`, so real parties, Exp, money and the Pokédex are never touched.

## Known limits

- **No authority on movement / economy beyond clamps.** Presence is broadcast and
  clients are trusted for it. Economy/badge mutations are range-clamped by the
  host, but this is a trusted host+friends model, not anti-cheat.
- **`Marshal` on the wire — host closed, small client-side residual.** The host
  never `Marshal.load`s an untrusted frame: it routes on a self-contained
  primitive-codec envelope and rejects legacy whole-Marshal frames, while deep
  graphs (saves, teams) ride as opaque bodies it stores/forwards without decoding.
  The only remaining `Marshal.load` of a peer-influenced graph is on the **client**
  — its own save, or a team it is about to battle — the accepted residual of the
  trusted-host model.
- **Debug-mode entry:** loading server state can intermittently hit an mkxp-z
  boot-stack `SystemStackError`; it is load-only and a relaunch recovers. Release
  builds (compiled plugins, no critical-code wrapper) are far less exposed.

## Diagnostics

Session and battle events are written to `mmo.log` in the game root (both
instances on one PC share it, which is handy for reading both sides at once).
