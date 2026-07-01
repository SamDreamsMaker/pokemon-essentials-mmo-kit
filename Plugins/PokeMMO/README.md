# PokeMMO — MMO SDK for Pokémon Essentials v21.1 (mkxp-z)

A plugin that turns solo Pokémon Essentials into a multiplayer sandbox **without
editing a single core script** — everything hooks in through `EventHandlers`,
`MenuHandlers` and guarded method aliases, so the fork stays updatable from
upstream.

> Status: **Phase 1 — "walking skeleton"**. You can see other players move around
> the overworld, smoothly, in real time. No authority / anti-cheat yet (that's
> Phase 2+). See the full plan in [`docs/architecture/MMO_CONVERSION_AUDIT.md`](../../docs/architecture/MMO_CONVERSION_AUDIT.md).

## Quick start (local test, two windows on one PC)

1. Double-click **`PlayMMO-debug.bat`** and wait for the title screen.
2. Double-click **`PlayMMO-debug.bat`** again (second window).
3. Start/continue a game in both and walk around — each player appears in the
   other's world.

`ROLE = :auto` (see `Config`) makes this zero-config: the first instance binds
the port and **hosts**; the second finds it busy and **joins** automatically.

## Configuration — `001_Net/001_NetConfig.rb`

| Setting | Meaning |
|---|---|
| `ROLE` | `:auto` (host-or-join), `:host`, `:client`, or `:off` (vanilla) |
| `HOST` | host IP a `:client` connects to (LAN IP for friends; `127.0.0.1` local) |
| `PORT` | TCP port (default `9998`) |
| `BIND_HOST` | host bind address — `127.0.0.1` (same-PC, no firewall prompt) or `0.0.0.0` (LAN) |
| `HEARTBEAT_FRAMES` | idle position re-announce interval (~frames) |

### LAN play without editing Ruby — `mmo_config.txt`

Drop a plain-text `mmo_config.txt` in the game folder to override the defaults
(handy for friends). Any subset of keys works; lines starting with `#` are
comments:

```ini
# On the HOST machine:
role = host
bind = 0.0.0.0        # accept LAN connections (allow the Windows Firewall prompt)
port = 9998

# On each FRIEND's machine instead:
# role = client
# host = 192.168.1.42  # the host's LAN IP
# port = 9998
```

Without this file, `ROLE = :auto` is used (host-or-join on `127.0.0.1`), which is
perfect for the two-windows-on-one-PC test.

## Architecture

```
001_Net/     Config            central settings
             MessageCodec      length-prefixed framing + Marshal  (the wire boundary)
             NetClient         one TCP connection, 100% non-blocking, main-thread poll
002_Server/  RelayServer       single accept thread + main-thread pump; fans frames out
003_Game/    Session           connection lifecycle (host/join), self id, logging
             RemotePlayer      Game_Character subclass for other players (+ Remotes registry)
             Presence          builds/emits the local player's position (step/turn/heartbeat)
             Dispatch          routes inbound messages
             Hooks             EventHandlers + the pbUpdateSceneMap alias (the pump)
```

**The pump model.** Measured mkxp-z behaviour forced a specific design (details in
the audit doc §4): its thread scheduler starves threads spawned off the main
thread and `IO.select` misses pending connections on a listening socket. So all
socket I/O is **non-blocking and driven from the main thread** once per frame via
`Pump.tick` (from `:on_frame_update`, plus an alias of `pbUpdateSceneMap` to keep
the link alive during message/menu loops). The only background thread is the
relay's blocking `accept` loop.

**Remote players** are `RemotePlayer < Game_Character` with `@through = true` (they
follow server truth, ignoring local collision) and reuse the engine's own tile
interpolation for smooth movement. Their sprites are injected via
`Spriteset_Map#addUserSprite`, which updates and disposes them automatically.

## Message protocol (Phase 1)

A message is a plain Ruby Hash. Position update:

```ruby
{ type: :pos,        # or :dir (turn in place)
  id:   "<sender>",  # sender-generated id (server-assigned in Phase 2)
  map:  5, x: 10, y: 12, dir: 2,   # dir: 2/4/6/8 = down/left/right/up
  speed: 3,          # so the remote glides at the sender's real pace
  mode: :walk, char: "boy_walk", outfit: 0 }
```

The relay forwards raw framed bytes to every other client — it never decodes
them (keeps the deserialisation trust boundary on the clients).

## Known limits (Phase 1)

- **No authority / anti-cheat.** The relay is a dumb broadcast; clients are
  trusted. Server-authoritative state, identity and validation come in Phase 2+.
- **`Marshal` wire-format** is an RCE vector on untrusted input — fine for a
  trusted host + friends, **must be replaced** before any public deployment
  (see `MessageCodec` and audit §10-G9).
- **Disconnected players linger** as "ghosts" until the next map change (the
  dumb relay sends no leave events yet).
- **Slight positional drift** under network jitter — a later interpolation-buffer
  pass will remove it.
- **No in-battle networking** — `:on_frame_update` / `pbUpdateSceneMap` don't run
  during battles; that needs its own hook.
- Default `BIND_HOST` is `127.0.0.1` (same-PC only). Set `0.0.0.0` for LAN.

## Diagnostics

Session events (host/join, connect result, pump errors) are written to
`mmo.log` in the game root.
