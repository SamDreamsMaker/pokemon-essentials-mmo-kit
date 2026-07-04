# PEMK Server — dedicated authoritative backend

A standalone **MRI Ruby** server (not mkxp-z) that owns accounts and player data
for a game built with the PEMK client SDK. The game **client stays mkxp-z**; only
the server changes. It speaks the split-frame wire protocol (safe primitive
envelope + opaque body — the server never `Marshal.load`s a client frame) over
TCP and persists to **PostgreSQL** (via Sequel).

## Architecture in one paragraph

One `IO.select` reactor thread (non-blocking, backpressured) accepts connections
and does all socket I/O. Work is handed to a fixed **worker pool**, serialized
**per player** through a mailbox — so there are no global locks and one slow
player can't stall another. State is split three ways: **server-authoritative**
records the server computes and clamps (economy ledger, badges, bag, Pokémon
UIDs/ownership), an **opaque save blob** the client owns and the server only
stores/returns (party, position, story flags), and **transient** presence that is
never persisted. Zone-scoped presence (`map_id → set(conn)`) means a position
update fans out only to same-map players.

## What the server owns today

| Area | Authority | Migration |
|---|---|---|
| **Accounts & auth** | email + password (bcrypt) → opaque 256-bit session token; unauthenticated connections drop every gameplay frame | `001`, `002` |
| **Durable save** | opaque `bytea` blob, stored and returned verbatim, never deserialized server-side | `001` |
| **Economy** | server-side **append-only ledger** (money/coins/BP/soot), clamped to `config/economy_caps.yml` | `003` |
| **Badges** | server-authoritative bitmask | `003` |
| **Bag inventory** | server-persistent `jsonb` snapshot, restored at login | `004` |
| **Pokémon identity** | server-issued **monster UIDs** (idempotent minting, party shadow) — dupe-proof | `005` |
| **Trading** | atomic ownership swap (CAS + row locks, whole-trade rollback) with an append-only `monster_transfers` audit/idempotency log | `006` |

Auth retires the old client-claimed `account_id`, killing impersonation.
Per-IP rate-limit + per-account lockout are evaluated before any password
hashing. Trading is dupe-proof: the swap only commits if every Pokémon is still
`owner = seller AND status = active AND flagged = false` under a `FOR UPDATE`
lock, and a positive-list login eviction removes any Pokémon you traded away.

## Local dev on Windows (WSL) — the maintained scripts

The server runs under **WSL Debian**. Two committed scripts do everything; keep
them up to date if the environment changes.

```bash
# from the repo's  server/  folder, inside WSL Debian:
bash bin/setup.sh        # ONE-TIME, idempotent: installs Ruby+Postgres+build deps,
                         #   creates a user-level Postgres cluster in ~/pemk-pgdata
                         #   on port 55432 (never touches the system 5432 cluster),
                         #   writes ~/pemk-env.sh, creates the pemk + pemk_test DBs,
                         #   bundle-installs the gems, migrates to the latest schema.

bash bin/run-tests.sh    # runs the suite against the ISOLATED pemk_test DB
                         #   (migrate + syntax-check every file + rake test).

bash bin/dev-server.sh   # runs the server on 0.0.0.0:9998 (brings the cluster up,
                         #   frees the port, migrates, then execs the server).
```

From Windows you don't need a WSL shell open: **`PlayMMO-server.bat`** (in the
repo root) just runs `bin/dev-server.sh` in WSL — double-click it and leave the
window open while you play. The full novice walkthrough (installing WSL itself,
first-run expectations) is [`../docs/INSTALL-WINDOWS.md`](../docs/INSTALL-WINDOWS.md).

The dev cluster is intentionally isolated: user-level, port **55432**, trust auth,
your Linux user as superuser, gems in `~/.pemk-bundle`, config in `~/pemk-env.sh`.
Nothing needs root after `setup.sh`'s one apt step.

## Deploy (production-parity, Docker)

```bash
cp .env.example .env      # set POSTGRES_PASSWORD
docker compose up --build # postgres + migrations + server
```

`docker compose` binds `PEMK_BIND=0.0.0.0`; open the TCP port through the
firewall. `SIGTERM` drains gracefully (`stop_grace_period: 30s`). `rake pemk:backup`
runs a `pg_dump`. Point clients at the host via `mmo_config.txt`
(`host = <server ip>`, `port = 9998`).

> **Transport.** Baseline is plain TCP — keep it to **LAN / a trusted network
> (e.g. Tailscale)**. A public deployment must terminate **TLS** at a reverse
> proxy: a client still `Marshal.load`s its own save and a peer's battle team, so
> a MITM without TLS is a client-side RCE risk.

## Config & env

- `config/economy_caps.yml` — per-currency caps. A **missing cap is a boot error**,
  not a silent default.
- `DATABASE_URL` — Postgres connection (set by `~/pemk-env.sh` in dev, `.env` in
  Docker).
- `PEMK_BIND` / `PEMK_PORT` — listen address/port (default `127.0.0.1:9998` in
  dev, `0.0.0.0:9998` in Docker/`dev-server.sh`).

## Roadmap (authority ladder)

| Milestone | Authority gained | Status |
|---|---|---|
| **M1** | durable store + real auth + zone presence + economy caps | ✅ done |
| **M2** | server-authoritative **economy ledger**, **badges**, **bag** | ✅ done |
| **M3** | server-issued **monster UIDs** (dupe-proof) + atomic **trading** | ✅ done |
| **M4** | server-authoritative **gameplay**: interaction-distance + world-object/spawn data + server-side battles | ⏳ next |

M4 is where gameplay stops being client-computed. The layered plan (world data →
position → interaction → battle) is in
[`../docs/ARCHITECTURE-SECURITY.md`](../docs/ARCHITECTURE-SECURITY.md), which also
lists exactly which interactions are and aren't server-secured today.
