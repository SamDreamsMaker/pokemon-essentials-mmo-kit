# PEMK Server — dedicated authoritative backend

A standalone **MRI Ruby** server (not mkxp-z) that owns player data for a game
built with the PEMK SDK. It replaces the in-process, trust-everything relay that
lived inside a host game instance. The game **client stays mkxp-z**; only the
server changes. Talks the existing split-frame wire protocol (primitive envelope
+ opaque body) over TCP; persists to **PostgreSQL**.

> Design & rationale: produced by the expert audit (dedicated server only, Ruby
> standalone, self-contained accounts, gameplay-authority *goal*). The realistic
> anti-cheat ladder is phased — see the roadmap below.

## Milestone 1 (this slice)

Shippable and valuable on its own:

- **Standalone server** on a stdlib runtime: an `IO.select` reactor (one thread,
  non-blocking, backpressured) + a fixed worker pool + a **per-player mailbox**
  (the unit of serialization — no global locks). No async gem, no Redis, no nio4r.
- **Zone-scoped presence** (`map_id → set(conn)`): the real 500-CCU lever — a
  position update fans out only to same-map players, not everyone.
- **Real auth**: username + password (bcrypt, cost 12 + SHA-256 pre-hash) → an
  opaque 256-bit session token. A connection is **unauthenticated** (every
  gameplay frame dropped) until a verified session — this retires the old
  client-claimed `account_id` and kills impersonation. Per-IP rate-limit +
  per-account lockout, evaluated before any password hashing.
- **Durable store**: saves persist to Postgres as an **opaque `bytea`** (still
  never `Marshal.load`d server-side — the client rehydrates its own bytes).
- **Explicit economy caps** (`config/economy_caps.yml`) — a missing cap is a boot
  error, not a silent literal.
- **Ops**: `docker compose up` (postgres + migrations + server), graceful
  `SIGTERM` drain (`stop_grace_period: 30s`), `rake pemk:import_saves` to migrate
  existing `server_saves/*.rxdata` blobs, `rake pemk:backup` (pg_dump).

## Run it

**With Docker (production-parity):**
```
cp server/.env.example server/.env   # set POSTGRES_PASSWORD
cd server && docker compose up --build
```

**Local dev on WSL/Linux (no Docker):** install `ruby-full build-essential
libpq-dev postgresql`, then from `server/`: `bundle install`, point `DATABASE_URL`
at a local Postgres, `bundle exec rake db:migrate`, `bundle exec ruby
bin/pemk_server.rb`. `bundle exec rake test` runs the suite.

Point the game client at the server via `mmo_config.txt` (`host = <server ip>`,
`port = 9998`).

## Roadmap (authority ladder)

| Milestone | Authority gained |
|---|---|
| **M1** (here) | durable store + real auth + zone presence + caps |
| M2 | **economy** = server-side append-only ledger (first true anti-cheat) |
| M3 | inventory / boxes + **server-issued monster UIDs** (dupe-proof) |
| M4 | movement + battle **detection** (flag/log, not enforcement) |
| *aspirational* | server-authoritative battle re-simulation (needed for ranked PvP) |

Non-ledger state (party/bag) can be **detected** (cap-checked, recorded), not
proven, because the client runs the whole game. Only the economy ledger is
genuinely tamper-proof. Baseline transport is **LAN/Tailscale** (plain TCP);
public internet needs a TLS reverse proxy (a client still loads its own save +
a peer team, so a MITM without TLS is a client-side RCE risk).
