# PEMK — Layer D: Server-authoritative battles

> **Status (2026-07-04): scoped and ratified.** The ranked end-state is
> **reuse the Essentials engine headless on the MRI server** (Model B, §2) —
> chosen over detection-only and a clean-room core. The cheap PvE tier (D1–D5)
> ships first with no engine; the engine (D7–D9) is deferred and parity-gated,
> and can be abandoned for the closed-form/detection tier without losing the
> earlier wins. First build step: **D1** (§7).

This document answers the last open question in the anti-cheat ladder: **how does
the server independently decide what a battle produced — the Pokémon that
appears, the one you catch, the EXP/money/drops you earn, and who wins a ranked
match — without trusting the client that ran it?**

It is the companion to `docs/ARCHITECTURE-SECURITY.md`, which shipped Layers A–C
(world data, position authority, interaction authority). Layer D is the largest
and last layer, and it is deliberately staged so the cheap, high-value kills land
first with **no battle engine at all**, and the expensive, drift-prone
re-simulation lands last, fully de-risked and enforced only after it is proven
against a parity corpus.

Guiding principle, unchanged: **never trust the client.** The client renders and
predicts; the server decides. Every check here ships **audit-first**
(`detect → shadow → enforce`), gated behind an env flag and advertised to the
client through `reconcile_block`, exactly like `PEMK_POS_ENFORCE` and
`PEMK_PICKUP_ENFORCE` before it.

---

## 1. Threat model — what Layer D kills

These are the four unsecured battle rows from the security matrix
(`docs/ARCHITECTURE-SECURITY.md` §"honest matrix", lines 44–47), plus the
identity and team cheats they enable.

| Cheat today | How it works now | Killed by | Enforcement path |
|---|---|---|---|
| **Illegal team / set** | client sends any moveset/ability/nature/EV/IV/level; server stores only species/level/pid/egg | **D1** | closed-form predicate |
| **Forced wild species / level** | client rolls the encounter locally | **D2** | server-minted encounter |
| **Forced shiny / perfect IVs** | client mints `personalID` + IVs (`Data/Scripts/014_Pokemon/001_Pokemon.rb`) | **D2** | server owns `{species,level,personalID,iv[6]}` |
| **Fake catch (identity)** | client claims a caught mon's data; `valid_mint_entry?` is structural-only (`server/lib/pemk/monsters.rb`) | **D3** | mint authored from the persisted encounter roll |
| **Fake catch (success)** | client claims a capture that didn't happen | **D3** (bounded) → **D8** (exact) | server-rolled shake, then re-sim |
| **Fabricated EXP / money / drops** | client declares any rewards on `battle_end` | **D4** (bound) → **D6/D8** (exact) | closed-form envelope, then per-mon authority + re-sim |
| **Under-the-bound cheating** | plausible-but-fictitious rewards below the theoretical max | **D5** | cross-battle statistical anomaly |
| **PvP RNG fabrication** | the *host* client owns every crit/miss (`Plugins/PEMK/005_Battle/008_BattleRngSync.rb`) | **D9** | server-seeded RNG + server re-sim |
| **Rage-quit loss-dodge** | disconnect resolves to `@decision = 5` (DRAW) | **D9** | forfeit-not-draw + server move-clock |
| **Result / rating forgery** | server is a pure relay, never sees the outcome | **D9** | server is the sole outcome authority |

**Explicitly out of scope for Layer D** (named here so the boundary is honest):
*acquisition provenance* — a competitively **legal** set that was never
legitimately obtained. The monsters registry doc already marks acquisition
validation as its own surface; D1 checks legality, not provenance. See
§6 Honest limits.

---

## 2. Core architectural decision

**Two authority models under one facet-ramped flag family, cheapest first, the
engine last.**

### Model A — *server authors the outcome* (D1–D6, no turn simulation)

The server decides the verifiable fact and hands it back as a grant the client
adopts. *Is this team legal?* is a predicate over exported data. *What species,
level, PID and IVs is this wild encounter?* is a table roll the server owns. *Did
the ball catch, and what was caught?* is ~60 lines of ported capture math plus the
encounter the server already minted. *What is the most this battle could pay?* is
the standard EXP/yield formula over a server-known foe. **None of this needs a
turn loop, a move-effect handler, or cross-engine determinism** — the client never
rolls, so there is nothing to make deterministic across engines.

### Model B — *server recomputes / re-simulates* (D7–D9, the engine)

The client submits a battle transcript (server seed + compact input tuples + claimed
result); the server replays the **same Essentials Ruby engine, headless, on MRI**
and compares. This closes the residual gaps Model A leaves open (catch-success on
client-claimed HP, exact EXP split) and delivers the one thing that genuinely
requires a full simulation: **canonical ranked-PvP outcomes.**

### Why this shape

- **Reuse the engine, never reimplement.** The engine is separable: `class Battle`
  takes its scene as a constructor argument
  (`Data/Scripts/011_Battle/001_Battle/001_Battle.rb`), all visuals/audio/input
  route through `@scene.pbXxx`, the ~26k-line mechanics core has **zero**
  Graphics/Sprite/Bitmap/Viewport references, and a production null scene already
  exists — `Battle::DebugSceneNoVisuals`
  (`Data/Scripts/011_Battle/004_Scene/009_Battle_DebugScene.rb`) drives Battle
  Frontier AI-vs-AI battles today. Reimplementing a clean-room core (the
  showdown-model bet) means maintaining **two** engines forever, still requires the
  full engine as a conformance oracle, and — the disqualifying flaw — a divergent
  re-sim can **overturn a result a legitimate player actually won**. One engine =
  one source of truth.
- **Ship the cheap wins before the engine.** D1–D4 kill the monetized PvE cheats
  (illegal teams, forced identity, fake catches, fabricated rewards) with closed-form
  checks in weeks. The alternative — gating all reward authority behind exact
  re-simulation — holds anti-cheat hostage to a multi-month, solo-scale, bit-parity
  gamble whose enforce phase carries the highest false-reject risk in the whole
  design. The closed-form reward **upper bound** is the default, not a fallback.
- **Four independent enforce facets.** `{teams, encounters, catches, rewards, pvp}`
  each ramp `off → shadow → on` on their own `PEMK_BATTLE_ENFORCE_*` flag, advertised
  via `reconcile_block` — the strongest audit-first realization, giving each check
  its own false-positive bake before it blocks anyone.
- **The engine is deferred but scheduled.** Rating **is** the prize in ranked, so a
  ladder that can *detect* tampering but never *re-derive* a canonical outcome is not
  acceptable. Re-sim (D9) is the scheduled ranked-integrity milestone — bounded by a
  ranked **whitelist** and gated behind an **offline parity corpus** so the server
  authority can never be *more* wrong than the client it overrides.

---

## 3. Prerequisites

Four hard dependencies underpin the roadmap. The first two are cheap and unblock
the whole cheap tier; the last two gate only the engine tier.

### 3.1 Battle-data export (blocks D1+)

Mirror the Layer A `world.json` pipeline (`server/lib/pemk/world_data.rb`). A
**client-side exporter** walks `GameData::Species/Move/Ability/Item/Type` plus the
Ruby-hardcoded 25 natures (`Data/Scripts/010_Data/001_Hardcoded data/009_Nature.rb`
— no PBS/.dat exists; transcribe them) at build time and writes a trimmed
`server/data/battle_data.json`; a new `server/lib/pemk/battle_data.rb` loads and
freezes it at boot. Export the **pure-data slice only** — species base
stats/learnsets/EV-yield/BaseExp/GrowthRate/catch-rate, move numeric fields, the
type-effectiveness matrix, item flags, and caps (`EV_LIMIT 510`/`EV_STAT_LIMIT
252` at `Data/Scripts/014_Pokemon/001_Pokemon.rb:91-93`, `MAXIMUM_LEVEL 100` at
`Data/Scripts/001_Settings.rb:131`, IV 0–31). ~500–900 KB raw, ~150–250 KB
gzipped. **Never ship `.dat`** — the MRI server has no RGSS and cannot
`Marshal.load` an RGSS-referencing struct. A move's `function_code` and an
ability/item id are **dispatch keys**, not data; the ~30k-line `011_Battle` effect
tree is out of export scope and only reached by the engine tier.

### 3.2 Server-owned RNG (two tiers)

- **Tier 1 (D2–D3): server-mint with MRI `SecureRandom`.** The server rolls
  identity and catch shakes; the client never rolls, so **no cross-engine
  determinism is required.** Because shiny/nature/gender/ability_index all derive
  from `personalID` (`Data/Scripts/014_Pokemon/001_Pokemon.rb:351/391/429/499`), the
  mint payload collapses to `{species, level, personalID, iv[6]}`.
- **Tier 2 (D7+): a custom cross-engine PRNG in `protocol/`.** A seedable
  xoshiro256★★/PCG that is **bit-for-bit identical** on MRI 3.1 and mkxp-z RGSS Ruby
  — *never* rely on `Kernel#rand`/`Random` internals matching across engines. It
  injects into exactly two one-line hooks: `Battle#pbRandom`
  (`.../001_Battle/001_Battle.rb:93`, 78 call sites, no edits) and
  `Battle::AI#pbAIRandom` (`.../005_AI/008_AI_Utilities.rb:5`, 22 call sites, no
  edits). The stock `RecordedBattle`
  (`.../008_Other battle types/005_RecordedBattle.rb`) already proves record/replay
  with stable draw order. Two leak fixes: neutralize the post-victory Pokérus spread
  `rand(3)` (`.../001_Battle/002_Battle_StartAndEnd.rb:491`) and **preserve** the
  deliberate command-phase `rand(2)` exclusion
  (`.../003_Move/008_MoveEffects_MoveAttributes.rb:1143`) or AI move-prediction
  desyncs the stream. `pbAIRandom` draw-order is load-bearing for any PvE re-sim.

### 3.3 The engine decision (blocks D7+): reuse headless, on MRI

The server loads **all** `011_Battle` mechanics + effect files, the `Pokemon` class
(`014_Pokemon`), the `HandlerHash` infra
(`Data/Scripts/003_Game processing/005_Event_Handlers.rb`), and the `GameData`
model, then injects a server scene **extending `DebugSceneNoVisuals`** whose
`pbCommandMenu/pbFightMenu/pbChooseTarget/pbPartyScreen` pull from queued
authoritative inputs instead of random. Stub ~4 globals (`pbSEPlay`→no-op,
`System.uptime`, `Input`/`$DEBUG`=false, `PBDebug`/`_INTL` passthrough) and set
`@internalBattle = false` to strip `$player`/`$game_temp` coupling. **A partial
load silently degrades** to `Move::Unimplemented`/no-op handlers — so the
acceptance gate is an **offline parity corpus** (replay thousands of logged
`RecordedBattle` snapshots on both client and server; require identical
`@decision` + HP/EXP/catch deltas) before any enforcement.

### 3.4 Server-legible full-stat team representation (blocks D1, D9)

Today teams cross the wire as **opaque Marshal blobs the server deliberately never
decodes** (`Plugins/PEMK/005_Battle/002_BattleSetup.rb`), and the registry stores
only species/level/pid/egg — so there is nothing authoritative to validate. D1
introduces a **non-Marshal, RCE-safe, structured team frame** (species, level,
IVs, EVs, moves, ability, nature, item) carried in the existing opaque body of
`Wire.encode_split` (`protocol/pemk_wire.rb`), decoded only through the primitive
envelope codec. This is bundled **into** D1, not deferred — legality has nothing to
check without it.

---

## 4. Sub-milestones

Three tiers. Tier 1 needs **no engine**; Tier 2 adds a new persistent-stat
authority; Tier 3 is the deferred, parity-gated engine.

### Tier 1 — Server-authored outcomes (no engine, no cross-engine RNG)

#### D1 — Battle-data export + full-stat team frame + team/set legality gate

- **Kills:** illegal teams and sets — moves outside the legal pool, abilities not in
  the species set, impossible natures, EVs over 510/252, IVs outside 0–31, over-level
  mons.
- **Mechanism:** ship the exporter + `server/lib/pemk/battle_data.rb` loader
  (§3.1) **and** the non-Marshal full-stat team frame (§3.4). Add a pure predicate:
  legal move pool = union(level-up ≤ level, TutorMoves/TM pool, EggMoves,
  **pre-evolution** level-up moves), merging `PBS/pokemon_forms.txt` overrides;
  ability ∈ abilities + hidden_abilities; nature ∈ the 25-entry table; EV/IV/level
  within caps. Wire it alongside the existing `Monsters#apply_party` projection so it
  logs `WOULD-REJECT`.
- **Prerequisites:** §3.1 export, §3.4 team frame. *No engine, no RNG.*
- **Effort:** **L** (predicate is S; the export pipeline and the new RCE-safe team
  frame are the real cost — this is not the "M / no prerequisites" some drafts
  claimed).
- **Risk:** low–medium. The one real hazard is **false-positive rejection** of legal
  sets (pre-evo / egg / TM / form-merge edge cases) — which is exactly why it ships
  detect-first. Confirm `MECHANICS_GENERATION` before hardcoding the
  `NO_VITAMIN_EV_CAP` rule (`Data/Scripts/001_Settings.rb:236`).
- **Enforcement ramp:** `PEMK_BATTLE_ENFORCE_TEAMS` off (log claimed vs legal) →
  shadow (`WOULD-REJECT`) → on (block battle/ranked entry) — after the real-player
  false-positive rate is ~0.

#### D2 — Server-authoritative wild-encounter minting

- **Kills:** forced/fake wild encounters, forced shinies, forced IVs — **at the
  source.** The client can no longer choose what appears.
- **Mechanism:** activate the dormant Layer A hook `WorldData#encounters(map_id)`
  (`server/lib/pemk/world_data.rb:102`, currently no caller). On an encounter the
  client sends `battle_req`; the server rolls `{species, level, personalID, iv[6]}`
  with `SecureRandom` against the frozen table, persists it to `encounter_rolls`
  (keyed by a `battle_sessions` row), and returns a `battle_encounter` grant the
  client adopts — reusing the `handle_pickup_req` verdict shape
  (`server/lib/pemk/server.rb:335`), fail-open on an unexported map, fail-closed on
  reject. Refactor the three client generation sites (`choose_wild_pokemon`,
  `pbGenerateWildPokemon`, `Pokemon#initialize`) plus the roamer path to **adopt**
  the server identity rather than roll.
- **Prerequisites:** D1 (species data), §3.2 Tier 1 RNG, `encounter_rolls`/`battle_sessions`
  migrations (copy the `monsters_mint_dedup` UNIQUE-index style).
- **Effort:** **L**.
- **Risk:** medium. Two disclosed gaps: (1) **generation-influence code** —
  Synchronize→nature, Cute Charm→gender, a lead ability's favored-type pull, Shiny
  Charm reroll odds, Compound Eyes' held-item roll — are ability/item *handlers*, not
  data. The server must fold these few influences into its roll or accept a
  documented single-player-feel regression; do **not** let the client "correct" the
  mint (that reopens the hole). (2) **Offline / solo play** has no server to mint —
  offline-caught mons are client-authored and must be quarantined on sync
  (flagged non-ranked/telemetry) rather than silently trusted. Encounter *timing*
  stays client-side; rate-limit and audit request cadence.
- **Enforcement ramp:** `PEMK_BATTLE_ENFORCE_ENCOUNTERS` off (log claim vs would-mint)
  → shadow (roll in parallel, log divergence) → on (server mint is the only valid
  encounter).

#### D3 — Server-adjudicated catch + caught-mon identity

- **Kills:** fake catches — a capture with no server-issued encounter, and forced
  species/shiny/IVs on capture.
- **Mechanism:** `catch_req{ball, hp_fraction, status}` → the server ports
  `pbCaptureCalc` (`.../007_Other battle code/005_Battle_CatchAndStoreMixin.rb:206`,
  ~60 pure lines) and the ball-effect set
  (`.../010_Battle_PokeBallEffects.rb`, 198 lines), rolls the **shake** from a
  per-encounter server stream, clamps `hp_fraction` to plausible bounds, and returns
  `catch_grant`/`catch_deny`. On grant it mints via `Monsters#mint_batch`
  (`server/lib/pemk/monsters.rb:35`) with the entry **authored from the D2
  `encounter_roll`** — inverting `valid_mint_entry?` from structural-only to
  server-authored — idempotent by `UNIQUE(issuer, nonce)`.
- **Prerequisites:** D2 (the caught identity **is** the minted encounter identity).
- **Effort:** **M**.
- **Risk:** medium. **Honest gap:** catch *success* depends on the wild mon's true
  HP/status, which is not server-tracked until re-sim (D8). The server trusts
  client-reported `hp_fraction` bounded by clamping — a client can shade odds but can
  **never force an unrolled shake or mint an identity the server didn't issue**.
- **Enforcement ramp:** `PEMK_BATTLE_ENFORCE_CATCHES` off → shadow (compute pass/fail
  alongside) → on (mint only on server grant). Identity + dedup enforce immediately;
  success-probability stays a bounded audit until D8.

#### D4 — Closed-form PvE reward bounds (EXP / money / drops)

- **Kills:** fabricated rewards — inflated EXP, forged money/BP, phantom drops.
- **Mechanism:** because D2 makes the defeated foe server-known, recompute the reward
  **envelope** with no turn loop: max EXP from BaseExp/GrowthRate/level (the pure
  formula in `.../001_Battle/003_Battle_ExpAndMoveLearning.rb`), money from the
  trainer/base payout, drops from the foe's yield table. Validate the client's claim
  on `battle_end`. Money/BP/coins route through `Ledger#apply_econ`
  (`server/lib/pemk/ledger.rb:19`) with the hardcoded `reason "unattributed"`
  (`ledger.rb:39`) attributed to `reason = "battle:<session_id>"` + a session-scoped
  `seq` so a replayed `battle_end` can't double-pay; drops feed `Inventory#apply_inv`.
- **Prerequisites:** D2 (server-known foe); Ledger reason/seq attribution.
- **Effort:** **M**.
- **Risk:** medium. It is an **upper bound**, not an exact ledger — plausible EXP
  under the max passes here (caught by D5). Money/BP/drops can reach **enforce**;
  **EXP enforcement is blocked** on per-mon stat authority (D6), so EXP stays at
  shadow. Exp-Share / horde / multi-battle widen the envelope.
- **Enforcement ramp:** `PEMK_BATTLE_ENFORCE_REWARDS` off → shadow (log over-claims)
  → on for **money/drops**; EXP held at shadow pending D6.

#### D5 — Cross-battle statistical anomaly detection

- **Kills:** the slow/subtle cheats the per-event bounds structurally miss —
  abnormal per-account shiny rate, crit/accuracy skew, catch-rate outliers,
  EXP-per-hour, encounter cadence, PvP rating velocity.
- **Mechanism:** aggregate the `Audit#log_claim`/`trunc` telemetry
  (`server/lib/pemk/audit.rb`) already emitted by D2–D4 into rolling per-account
  distributions vs population baselines; flag z-score outliers for a human review
  queue. This is the backstop for the residuals D3/D4 admit (catch-success,
  under-the-bound EXP).
- **Prerequisites:** D2–D4 emitting audit rows; a baseline window of real player data.
- **Effort:** **M**.
- **Risk:** medium — irreducible false positives (lucky players look like cheaters).
- **Enforcement ramp:** detect → shadow (flag-for-review). **Never** auto-enforce a
  single event; feeds manual action / throttling only.

### Tier 2 — New persistent authority

#### D6 — Per-mon EXP / level authority

- **Kills:** fabricated level/EXP that the blob-owned party hides today —
  `party_snapshots` is detection-only and `Monsters#apply_party`
  (`server/lib/pemk/monsters.rb:54`) flags `foreign_uid`/`dup` but never rejects.
- **Mechanism:** the EXP the server bounds in D4 (and later verifies exactly in D8)
  becomes authoritative per-mon EXP/level. Migrate per-mon stats off the opaque
  `characters.load_blob` party into server-owned rows, written under
  `PlayerMailbox#submit` per-account serialization. This closes the reward loop D4
  opens: D4 bounds the gain at the battle boundary, D6 owns the resulting persistent
  stat.
- **Prerequisites:** D4. **This is genuinely new authority + a data migration**, not a
  reuse.
- **Effort:** **L**.
- **Risk:** medium. Must reconcile server-owned stats with the existing party-snapshot
  shadow without breaking the single-player-shaped save flow.
- **Enforcement ramp:** detect (level/EXP drift via the party shadow) → shadow → on
  (server-owned per-mon EXP/level is canonical); flips D4's EXP sub-facet to enforce.

### Tier 3 — Engine-reuse re-simulation (deferred, parity-gated)

#### D7 — Cross-engine PRNG + headless re-sim harness + offline parity corpus *(enabling)*

- **Kills:** nothing player-facing. This is the pivot from checkpoint to re-sim and
  the make-or-break of the whole engine thesis.
- **Mechanism:** implement the §3.2 Tier 2 PRNG in `protocol/`; inject it into the two
  hooks; thread a per-battle seed through `Battle#initialize`; apply the two leak
  fixes. Build the §3.3 headless harness (all `011_Battle` + `014_Pokemon` +
  `GameData` + `HandlerHash`, `DebugSceneNoVisuals`-derived scene, global stubs,
  `@internalBattle=false`). Stand up the **offline parity corpus** and, in parallel,
  a CI **conformance oracle** that runs the *real client* engine on scripted
  seed+inputs and asserts identical traces.
- **Prerequisites:** D1 (data + team frame). *Offline only — no player impact.*
- **Effort:** **XL** — the multi-month gate that determines whether the re-sim thesis
  holds.
- **Risk:** high. A partial load silently diverges; float rounding / Hash-iteration
  order / string encoding differ between mkxp-z and MRI, so full-computation
  bit-parity (not just the PRNG) is the real hazard. `pbAIRandom` draw-order is
  load-bearing. **Permanent version-coupling tax:** the MRI port must track every
  future edit to the client battle code forever, or the two drift.
- **Enforcement ramp:** none — validated offline against logged battles; proceed to D8
  only when parity holds on a large corpus.

#### D8 — PvE per-turn checkpoint re-sim

- **Kills:** doctored transcripts, impossible per-turn damage, and the residual D3/D4
  trust gaps (lied-low HP at catch, fabricated EXP split).
- **Mechanism:** the client submits `{seed, ordered input tuples (reuse the compact
  FIGHT/BAG/POKEMON/RUN encoding from
  `Plugins/PEMK/005_Battle/007_BattleChoiceSync.rb`), per-turn state hashes}`. The
  server replays through the D7 harness and compares per-turn hashes; divergence →
  `WOULD-REJECT`. This retroactively hardens catch (true HP/status known) and rewards
  (true participation/EXP split known), running off-reactor on the worker pool.
- **Prerequisites:** D7; D3/D4 (server-known encounter + reward path); D6 (persistent
  EXP sink).
- **Effort:** **L** (given D7 paid the engine cost).
- **Risk:** medium — any unported/divergent handler is a false reject, so a long shadow
  bake per move/ability is mandatory. Non-trivial compute per battle at scale;
  sample/queue under load.
- **Enforcement ramp:** detect/shadow for a long bake → enforce exact catch-success +
  EXP (escalates the `catches`/`rewards` facets to full enforce).

#### D9 — Server-authoritative ranked PvP + ladder

- **Kills:** all PvP cheating — host-owns-RNG fabrication
  (`Plugins/PEMK/005_Battle/008_BattleRngSync.rb`), ignored-opponent-inputs, illegal
  ranked teams, rage-quit-to-draw dodging, and result/rating forgery.
- **Mechanism:** flip the already-wired `ADDRESSED` `battle_*` frame family
  (`server/lib/pemk/server.rb:21`; client `Plugins/PEMK/003_Game/004_Dispatch.rb`)
  from pure relay to a server-mediated **session**, cloning the trade rendezvous
  (`@pending_trades` + `handle_trade_commit` + `sweep_trades` TTL +
  `cancel_pending_trades`, `server.rb:393/449/557`) into a long-lived `@battle_sessions`
  router. The server hard-gates both teams through D1, seeds and persists the PRNG
  (`battle_sessions` row), collects both players' input tuples, and runs the D7 engine
  as the **sole authority** (neither client rolls; PvP needs the mechanics core but not
  the AI layer). Add matchmaking, a rating store (Glicko-2), **forfeit-not-draw** with
  a server move-clock (replacing today's `@decision=5` draw), replay persistence, and
  atomic two-account settlement under `Trades#execute_trade`'s FOR-UPDATE-in-id-order
  + whole-rollback (`server/lib/pemk/trades.rb:27`). The D1 **whitelist** bans
  non-whitelisted `function_codes` at ranked entry, bounding the parity-corpus burden.
- **Prerequisites:** D1 (legality + team frame + whitelist), D7 (engine + seed
  authority), D8 (parity proven in shadow).
- **Effort:** **XL** — the hardest milestone, deliberately last, with net-new ranked
  pillars (matchmaking/rating/anti-collusion/move-clock/replay) that have no reuse.
- **Risk:** high — engine parity under adversarial inputs; latency/move-clock UX;
  anti-collusion is detection-only forever. Fully de-risked only because D1/D7/D8
  proved legality, the engine, and parity first.
- **Enforcement ramp:** `PEMK_BATTLE_ENFORCE_PVP` off (unranked friendlies stay
  peer-relay; log claimed outcomes) → shadow (server re-runs from submitted inputs,
  logs disagreement, no rating writes) → on (server sim is the sole authority for
  ranked; ratings, forfeits, replays go live).

---

## 5. Decisions of record

| Decision | Choice | Why |
|---|---|---|
| **Engine** | Reuse Essentials headless on MRI; **never reimplement**; deferred to D7, parity-gated | Zero-drift single source of truth; a clean-room core maintains two engines and can overturn correct results |
| **RNG (PvE)** | Server-mint with `SecureRandom`; client never rolls | No cross-engine determinism needed; `personalID` derives shiny/nature/gender/ability |
| **RNG (re-sim/PvP)** | Custom cross-engine PRNG in `protocol/`, injected into `pbRandom`+`pbAIRandom` | Bit-parity across MRI/mkxp-z; `Kernel#rand` internals are not portable |
| **Data** | Client-exported `battle_data.json`; pure-data slice only; never `.dat` | MRI has no RGSS; effect code is dispatch keys, not data |
| **Team** | New non-Marshal, RCE-safe full-stat frame, bundled into D1 | Registry stores only species/level/pid/egg; legality has nothing to check without it |
| **Reward authority** | Closed-form upper bound is the **default** (D4); exact EXP/catch via re-sim later (D8) | PvE reward protection must not wait on the XL engine |
| **Ranked** | Canonical re-sim is **scheduled** (D9), not optional | Rating is the prize; detect-but-can't-attribute is not a ladder |
| **Ramp** | Four independent `PEMK_BATTLE_ENFORCE_*` facets, `off/shadow/on`, via `reconcile_block` | Per-check false-positive bake; mirrors `PEMK_POS_ENFORCE`/`PEMK_PICKUP_ENFORCE` |

---

## 6. Honest limits

- **Model A cannot verify battle *context* without re-sim.** Until D8, the server
  trusts client-reported wild-mon HP/status at catch (D3) and which mons participated
  at what level for the EXP split (D4). It bounds and clamps but cannot fully validate;
  a client can shade catch odds or reward splits *within the envelope* — but can never
  force an unrolled catch, mint an unissued identity, or claim an out-of-envelope
  reward.
- **D1 checks legality, not provenance.** A competitively legal set that was never
  legitimately obtained passes. Binding a ranked mon to its minted `encounter_roll`
  over its lifetime is the same per-mon stat-authority surface as D6, and full
  acquisition provenance is out of Layer D scope.
- **EXP is the most-farmed reward and the last to enforce.** It is blob-owned today;
  D6 is a genuine new authority + migration, and exact EXP needs D8. Until then EXP is
  bounded (D4) and statistically watched (D5), never an exact ledger.
- **Re-sim fidelity is all-or-nothing.** A partial engine load degrades silently to
  `Move::Unimplemented`/no-op handlers; the parity corpus only catches interactions it
  has seen. Long-tail combinations can diverge invisibly — the enforce-phase failure
  mode is a **false reject of a legitimate player**, the highest-blast-radius error in
  the design, which is why D7/D8 bake offline and in shadow for a long time.
- **The version-coupling tax is permanent.** One source of truth means the MRI port
  tracks every future client battle-code edit forever. For a solo maintainer this
  recurring cost — not the initial port — is the real price of D7+.
- **Cross-engine bit-parity is fragile.** mkxp-z and MRI differ in float rounding,
  Hash/Set iteration order, string encoding, and frozen-literal behavior;
  integer-ize any float in ported damage calc or the re-sim desyncs.
- **Client constraints persist.** mkxp-z has no `SecureRandom` and limited crypto, so
  the **server is the sole seed authority** (no client commit-reveal), and the client
  cannot independently prove fairness — trust is anchored server-side.
- **Anti-collusion is unsolvable.** Win-trading / rating inflation stay
  detect/shadow, tuned from persisted replays, forever.
- **Transport is unchanged.** Plain TCP (trusted-network / TLS-at-proxy); battle
  teams are still `Marshal.load`ed client-side. The new server-legible team frame
  reduces but does not remove that client-side RCE exposure — TLS at the proxy closes
  it.

---

## 7. Start here

Ship **D1's foundation, log-only**, in this order:

1. **`battle_data.json` exporter + `server/lib/pemk/battle_data.rb` loader** — a
   client-side `GameData` walk mirroring the Layer A `world.json` pipeline, loaded and
   frozen at boot with a round-trip self-test. Pure data, no enforcement, no engine,
   no protocol change beyond the load. This is the cheapest proven-pattern
   down-payment and unblocks everything.
2. **The non-Marshal full-stat team frame** — the RCE-safe structured team the server
   can actually read (§3.4).
3. **The pure-predicate legality validator** over learn pools (level-up ≤ level +
   TutorMoves + EggMoves + pre-evo, merging form overrides), ability set, natures
   table, and caps — wired into the existing party projection to log `WOULD-REJECT`
   behind `PEMK_BATTLE_ENFORCE_TEAMS=off`, advertised via `reconcile_block`.

It follows the exact `off → shadow → on` ramp already proven by `pos_audit` and
`pickup_enforce`, kills the entire illegal-team/set class the moment it reaches
`on`, and is the mandatory gate for ranked PvP (D9). Nothing here can block a real
player until its false-positive rate is measured at zero.