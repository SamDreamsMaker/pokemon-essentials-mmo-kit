# PEMK — Security model & anti-cheat roadmap

This document answers one blunt question: **which player actions does the server
actually verify, and which does it take on faith?** It then lays out the plan
(Milestone 4) to move gameplay itself under server authority.

Guiding principle, borrowed from every serious multiplayer engine:
**never trust the client.** The client renders and predicts; the server decides.
Today PEMK meets that bar for *data* (money, items, Pokémon) but not yet for
*gameplay* (where you are, what you touch, how a battle resolves).

---

## TL;DR — is "pick up the item" secured?

**No.** Picking up an overworld item is computed entirely on the client. There is
**no distance check, no "does this item exist / is it still there" check** on the
server. The client runs the map event, adds the item locally, and then syncs its
**bag** to the server as a snapshot. The server clamps the *bag* (caps, shape) —
so you can't hold an impossible quantity — but it never validated the **act** of
picking it up: it doesn't know the item's tile, doesn't know your position, and
can't tell a legitimate pickup from a fabricated one.

So the bag *contents* are server-authoritative, but the *event that changed them*
is trusted. That distinction is the whole point of this document, and closing it
is Milestone 4.

---

## What the server verifies today (the honest matrix)

| Capability | Computed by | Server-verified? | If a cheat client lies… |
|---|---|---|---|
| **Login / identity** | server | ✅ yes | can't — bcrypt + opaque session token, no client-claimed id |
| **Money / coins / BP / soot** | server ledger | ✅ yes | rejected — append-only ledger, capped |
| **Badges** | server | ✅ yes | rejected — server owns the bitmask |
| **Bag contents** | server snapshot | ✅ shape/caps only | can't hold impossible amounts, but see below |
| **Pokémon identity & ownership** | server (UIDs) | ✅ yes | can't dupe — UID registry + ownership |
| **Trades** | server | ✅ yes | can't dupe/steal — atomic CAS swap, rollback |
| **Where a Pokémon came from (pickup, gift, catch)** | **client** | ❌ no | can fabricate acquiring one (within UID rules) |
| **Overworld movement / position** | client → **server-audited** | ✅ enforceable (M4-B) | no-clip / illegal-warp snapped back to last-good tile (opt-in flag; audit-only by default) |
| **Item pickup (distance, existence)** | client → **server-granted** | ✅ enforceable (M4-C) | remote / duplicate pickups denied — distance gate + one-shot + server grant (opt-in flag) |
| **Interacting with NPCs / objects** | **client** | ❌ no | can trigger events from anywhere |
| **Wild encounters / which Pokémon appears** | **client** | ❌ no | can force encounters / shinies / species |
| **Catching** | **client** | ❌ no | can claim a catch that never happened |
| **Battle outcomes (vs NPC)** | **client** | ❌ no | can declare any result, EXP, drops |
| **PvP battle** | both clients (relayed) | ⚠️ deterministic, not authoritative | a modified client can desync/cheat its own side |
| **Spawn / respawn position** | **server** | ✅ enforceable (M4-B) | server seeds spawn from the persisted last-good position |
| **Map transfers / warps** | client → **server-audited** | ✅ enforceable (M4-B) | illegal (non-endpoint) warps snapped back (opt-in flag) |

Read the ✅ rows as: *a hacked client cannot gain here.* Read the ❌ rows as:
*today this is a trusted-players model — a hacked client can lie and the server
won't catch it.*

### The precise list of currently **unsecured** interactions

Everything the game does in the overworld and in battle is client-side:

1. **Movement** — position, facing, speed, collision. The server relays your
   coordinates to same-map players but never checks they're reachable.
2. **Item pickup** — no distance check, no check that the item exists or is
   unclaimed. Only the resulting bag is clamped.
3. **Hidden items / Poké-finder / foraging** — same as pickup.
4. **NPC & object interaction** — talking, receiving gifts, cut/rock-smash/etc.,
   triggering switches — all client-run; the server isn't consulted.
5. **Wild encounters** — encounter roll, species, level, shininess, IVs.
6. **Catching** — capture success and the resulting Pokémon's data (the UID makes
   it non-duplicable, but not *un-fabricable*).
7. **NPC/trainer battles** — outcome, rewards, EXP, item drops.
8. **PvP battles** — deterministic and relayed, but each side simulates locally;
   authority is "challenger's RNG," not the server. A modified client can cheat.
9. **Spawn point & respawn** — where you appear on login or after a faint.
10. **Map warps / transfers** — which map you move to and where you land.

None of these is a bug — it's the current milestone. The client runs the *entire*
Essentials engine, so anything the engine computes is, by definition, trusted
until the server grows an independent copy of the rules.

---

## Why it's like this

The client is a full, self-contained Pokémon Essentials game. It already knows
every map, event, encounter table and battle formula. Making the *data* (money,
items, Pokémon) server-authoritative was tractable: those are small, discrete
facts the server can hold and clamp. Making *gameplay* authoritative means the
server needs its **own** model of the world — maps, object positions, spawn tiles,
encounter tables — and its own battle engine, so it can independently recompute
what the client claims. That's a much bigger surface, which is why it's its own
milestone.

The good news: you don't have to server-simulate *everything* to kill the common
cheats. A cheap distance/existence check stops fabricated pickups; a movement
sanity check stops teleporting; server-owned spawn tiles stop spawn-anywhere. Full
battle re-simulation is only needed for the last mile (ranked PvP integrity).

---

## Milestone 4 — the anti-cheat ladder

Four layers, cheapest-and-highest-value first. Each is shippable on its own and
each makes the next easier (they share the "server has its own world data" spine).

### Layer A — Server-side world data (the foundation) — *shipped*

**Shipped so far:** the server now loads a **read-only world model** from a
build-time JSON export (`server/data/world.json`, produced in-engine by the
"PEMK: Export World" debug action — the server never reads `.rxdata` maps, so it
never `Marshal.load`s an engine object). On top of it, the client sends an
**audit-only interaction claim** on every item-ball pickup ("I picked up item X
at (map,x,y)"), and the server **logs** any claim that disagrees with the model.
It enforces nothing yet — this is the telemetry that will seed the enforcement
checks with real data and a false-positive signal before anything blocks.
Remaining in Layer A: warp/spawn tiles, encounter tables, and widening claims
beyond item balls.

The server can't verify a position or a pickup until it knows the map. So first,
give the server a **read-only model of the world**, extracted from the same
Essentials data the client ships:

- **Interactive objects** — every map's item balls, hidden items, and interactable
  events, keyed by a stable **object id + (map, x, y)**.
- **Spawn / warp tiles** — legal spawn points, respawn (healing) points, and warp
  endpoints per map.
- **Collision / passability** — enough to know which tiles are walkable.
- **Encounter tables** — species/level/rate per map & method (for Layer D later).

*Deliverable:* an offline exporter that reads the game's map data into a compact
server-side table, plus an **audit mode** where the server logs (doesn't block)
mismatches between what clients claim and what the world data says. Audit-first is
the safe way to seed the data and find bad assumptions before enforcing.

### Layer B — Position authority — *shipped (opt-in enforcement)*

**Shipped:** the server runs a **position audit** on the presence stream it
already receives (no new client message) — every per-step frame is checked
against the world model and a violation is classified:

- **no-clip** — a step onto a fully-blocked tile (passability grid),
- **teleport** — a same-map jump of more than one tile (Chebyshev distance),
- **illegal-warp** — a cross-map move that matches no known warp endpoint, edge
  connection, or spawn/heal/home tile.

Enforcement is **live but gated** behind `PEMK_POS_ENFORCE` (off / shadow / on).
In `on`, no-clip and illegal-warp are **snapped back** to the last-good tile
(`:pos_correct` → client `PosCorrect`, moveto same-map / transfer cross-map),
and the violating frame is *not* fanned out to peers; teleport stays log-only
(too many legit sources — Fly/Dig/ledges). Default is audit-only so real players
surface false-positive classes (surf, bridges, ledges) before anything is
blocked. **Spawn/respawn is server-owned:** the last-good position is persisted
(migration 007) and re-seeded at login, so a client can't spawn anywhere.

The end state for Layer B:

- Reject or snap-back positions that aren't reachable (through walls, off-map).
- Cap movement speed / step rate (no teleporting, no super-speed).
- Own **spawn and respawn** points — the server places you on login and after a
  faint, from Layer A's legal tiles.
- Own **warps** — a map transfer is validated against Layer A's warp endpoints.

*Result:* teleport, no-clip, and spawn-anywhere die. This is also the prerequisite
for the interaction check.

### Layer C — Interaction authority (the "pick up the item" fix) — *shipped (opt-in enforcement, item pickups)*

The server validates an *action* against *position*. **Shipped** for overworld
item balls:

- **Distance gate** — a pickup is only accepted if the claimed object is **within
  one tile** (Chebyshev) of the player's server-known position (Layer B). Otherwise
  `:too_far`. (One tile is the classic engine rule.)
- **Existence & one-shot** — the object must exist at that (map, x, y) per Layer A,
  and item balls are **consumed server-side** via an atomic `UNIQUE(account_id,
  map, x, y)` row (migration 008), so the same item can't be picked up twice
  (`already_taken`).
- **Server grant** — with `PEMK_PICKUP_ENFORCE=on`, the client's guarded
  `pbItemBall` **asks first** (`:pickup_req`) and adds the item only on
  `:pickup_grant`; a `:pickup_deny` leaves the ball. Off by default; offline /
  solo / pre-login / bag-full fall back to the local pickup.
- **Permanent per account** — pickups are one-shot *for all time*, like the money
  ledger and badges: a client "new game" on the same account does **not** re-enable
  taken balls (your money doesn't refund either), while a genuinely fresh start is a
  **new account** whose pickup rows are empty (FK cascade on account delete). So
  enforcement is safe to default on — real players never hit a stale-dup wall. The
  only wipe path is a **dev/QA F9 tool** (`PEMK: Reset my pickups`), honored **only**
  when the server was booted with `PEMK_ALLOW_PICKUP_RESET=on` (off in production);
  a client-obeyed reset is deliberately *not* offered — it would be an infinite
  item re-farm.

**Honest scope:** this makes pickups server-*authorized*, not yet
minted-into-inventory. The bag is still blob-authoritative (M2.3), so a fully
hacked client that edits its own bag blob is *detected* on the next snapshot, not
*prevented* here; and because the one-shot is consumed at grant time, a lost grant
forfeits that one item (favours anti-dupe over anti-loss). True exactly-once mint,
plus gift/event rewards and NPC-talk gating, are deferred to the
server-authoritative-bag milestone.

*Result:* fabricated pickups, remote grabs, and duplicate item balls all fail
(opt-in). Gift/event/NPC-spam gating remains future work.

### Layer D — Battle authority — *scoped; see [`LAYER-D-BATTLE-DESIGN.md`](LAYER-D-BATTLE-DESIGN.md)*

The last and largest layer: the server independently determines what a battle
produced. It is **staged** so the cheap, high-value kills land first with **no
battle engine**, and the expensive re-simulation lands last, parity-gated.

- **Tier 1 (no engine)** — server-authored outcomes: **D1** team/set legality
  (over an exported `battle_data.json`, like Layer A's `world.json`), **D2**
  server-minted wild encounters (species/level/shininess/IVs server-rolled, not
  client-claimed), **D3** server-adjudicated catches minting the encounter's own
  identity, **D4** closed-form PvE reward bounds (EXP/money/drops), **D5**
  cross-battle statistical anomaly detection.
- **Tier 2** — **D6** per-mon EXP/level authority (migrating stats off the opaque
  party blob).
- **Tier 3 (deferred, parity-gated)** — the engine: **D7** a cross-engine seeded
  PRNG + a **headless re-run of Essentials' own battle code on the MRI server**
  (reused, never reimplemented — the mechanics core has zero Graphics refs and a
  `Battle::DebugSceneNoVisuals` null scene already exists), validated offline
  against a parity corpus; **D8** per-turn checkpoint re-sim; **D9**
  **server-authoritative ranked PvP** + ladder, replacing today's
  "challenger-authoritative" relay.

Enforcement ramps on four independent facets (`PEMK_BATTLE_ENFORCE_{teams,
encounters,catches,rewards,pvp}`, `off/shadow/on`), advertised via
`reconcile_block` — same audit-first pattern as B and C.

*Result:* illegal teams, forced shinies, fake catches, fabricated rewards, and PvP
cheating all fail. **Ranked end-state ratified: reuse the Essentials engine
headless.** Honest limit: until D8 the server bounds and clamps but doesn't
re-derive battle context; the version-coupling tax of the reused engine is
permanent.

---

## Roadmap at a glance

| Layer | Kills | Needs | Effort |
|---|---|---|---|
| **A. World data** *(shipped)* | (foundation) | in-engine map exporter + audit logging | medium |
| **B. Position** *(shipped, opt-in)* | teleport, no-clip, spawn/warp-anywhere | Layer A + movement checks | medium |
| **C. Interaction** *(shipped, opt-in — item pickups)* | fake/remote/duplicate pickups | Layers A–B + distance gate + server grant | medium |
| **D. Battle** *(scoped — staged D1–D9)* | illegal teams, forced encounters/shinies, fake catches/rewards, PvP cheats | Tier 1 (D1–D5) closed-form, no engine → Tier 2 EXP authority → Tier 3 (D7–D9) headless engine reuse + ranked | large |

Recommended order is A → B → C → D, and within it **audit before enforce**: ship
each check in log-only mode first so real players surface false positives before
anything gets blocked.

---

## Transport security (orthogonal, but don't forget it)

All of the above assumes the bytes on the wire are the client's. They're sent over
**plain TCP**. Two consequences:

- **Keep it to a trusted network.** LAN or **Tailscale** (which is encrypted). A
  public server on bare TCP is exposed.
- **A public deployment needs TLS** at a reverse proxy — not just for privacy: the
  client `Marshal.load`s its own save and a peer's battle team, so a MITM that can
  rewrite those bytes is a client-side remote-code-execution risk. TLS closes that.

Transport hardening is independent of the A–D gameplay ladder; both are needed for
a real public deployment.
