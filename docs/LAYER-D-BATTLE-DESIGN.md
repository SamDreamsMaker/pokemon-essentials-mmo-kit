# PEMK — Layer D: Server-authoritative battles

> **Status (2026-07-04): scoped and ratified.** The ranked end-state is
> **reuse the Essentials engine headless on the MRI server** (Model B, §2) —
> chosen over detection-only and a clean-room core. The cheap PvE tier (D1–D5)
> ships first with no engine; the engine (D7–D9) is deferred and parity-gated,
> and can be abandoned for the closed-form/detection tier without losing the
> earlier wins. First build step: **D1** (§7).
>
> **Progress (2026-07-04): D1 shipped, detection-only.** The battle-data export +
> server read model (`battle_data.json` / `pemk/battle_data.rb`) and the team/set
> legality audit (`pemk/team_audit.rb`, client `TeamReport`, `PEMK_BATTLE_ENFORCE_TEAMS`
> off/shadow/on) are live and logging illegal teams. There is no battle-entry gate
> yet, so every mode only logs — enforcement waits on the ramp + a real gate.
>
> **Progress (2026-07-05): D2 shipped (shadow + on).** The wild-encounter roller
> (`pemk/encounter_mint.rb`: weighted slot pick + `{pid, iv[6], shiny}` mint via
> SecureRandom) is live on the one `pbGenerateWildPokemon` seam. `shadow` reports each
> locally-rolled encounter and the server logs species-not-in-table / wrong-map suspicion
> + what it would mint. **`on` makes the client REQUEST the mint and BUILD the wild
> Pokémon from the server's `{species, level, pid, iv[6], shiny}` — the client is a pure
> observer of what appears, its level, shininess and IVs.** Fail-open (deny/timeout/offline
> → local roll at vanilla odds). Off by default. Honest gaps (disclosed): maps flagged
> `ScaleWildEncounterLevels` stay local (the server has no party levels); the claimed
> enctype isn't validated against the tile's terrain (species still come from a legit
> table with server identity); generation influences that are ability/item CODE
> (Shiny Charm/chaining, Synchronize, Cute Charm, Static/Magnet-Pull) aren't folded in.
> No persistence yet — D3 (catch) adds `encounter_rolls` when it must reference the mint.
> **Progress (2026-07-05): D3 part 1 shipped (server-adjudicated catches).** The server
> ports pbCaptureCalc exactly (`pemk/catch_calc.rb`, engine-parity unit-proven against
> independently computed thresholds) and rolls the SHAKES with SecureRandom, bound to
> the stashed D2 encounter mint (species/level/IVs the server itself issued; a caught
> verdict consumes the mint). Client inputs are clamped to the honest envelope: HP to
> the server-computed max (base stats + mint IV + level), ball rate to each ball's
> legitimate cap (gen-8 values, 255 ceilings, Ultra-Beast /10), status whitelisted.
> `PEMK_BATTLE_ENFORCE_CATCHES` off/shadow/on (shadow = report + server_would log; on =
> the client adopts the server verdict via the one `pbCaptureCalc` seam). Fail-open
> everywhere; requires encounters=on (no mint -> local). Honest gaps: a miss doesn't
> consume the mint so re-requests retry at vanilla odds (attempt counter logs SUSPECT
> catch-spam at 21+; ball ownership isn't validated — the bag is blob-authoritative);
> static/event/roamer catches never mint so they stay local.
>
> **Fix (2026-10-06): only the encounter table's own roll is minted or reported.** The
> alias read any `pbGenerateWildPokemon` call made while `$game_temp.encounter_type` was set
> as the table's encounter: a roaming Pokémon (the roamer handler rewrites the roll in
> place) was minted as a table roll and the roamer then built FROM it, for good; the Poké
> Radar's chains were replaced by the server's roll; an encounter a Repel turned away left
> the type set, so an event's battle after it (the invisible Kecleon, a legendary) was
> replaced too; and `shadow` reported all of them as SUSPECT, plus every form species
> under its base id. Now `choose_wild_pokemon` marks its roll, the `:on_wild_species_chosen`
> handlers work on a copy that notes any write (even of the values it held), and
> `generate_foes` mints or reports only the marked rolls still untouched (`PEMK::Encounter
> .table_roll` lets a plugin mark its own). Catches are asked for minted foes only. What
> stays the game's - events, roamers, radar chains - opens no D4 window and no Pay Day
> proof, as event battles always did. Proven on the engine's own code (the old plugin turns
> the roamer into the minted Pokémon there); autotest 096. Then: the client names the game's
> encounter version (`$PokemonGlobal.encounter_version`, moved on by story events) and the
> server rolls that version's tables, version 0's where the map has none for it (the
> engine's own fallback; none at all on a map with no version 0) - it always rolled version
> 0. Like the encounter type, the version is the client's word: only the map's exported
> tables are read, and the MINT and report lines say which (`v1`). A catch names its foe's
> personal id (the shadow report too), so a stash holding two alike (a fled Pidgey, then
> another) judges and stamps the right roll.
>
> **Progress (2026-07-22): D3 part 2 shipped (persisted rolls + mint provenance).**
> Every D2 `on` mint is persisted (`encounter_rolls`, migration 009 — additive), the
> catch verdict stamps it caught, and the caught mon's M3 UID mint CLAIMS it: each
> minted identity now carries a provenance label on its registry row —
> **`wild_caught`** (server-issued + server-verified capture), **`wild`**
> (server-issued, no catch verdict — catches off, or fabricated from a fled
> encounter's grant), **`client`** (no matching roll — legitimate for
> starters/gifts/eggs, which is why it never rejects; a save-copied clone of a wild
> mon self-labels: only one of the pair can claim the roll). Zero client/wire
> changes; provenance is recorded only when encounters=on (else origin stays NULL =
> unknown, never mislabeled); per-account mailbox FIFO makes record→stamp→claim
> ordering deterministic; stale never-fought rolls are pruned at boot (7-day
> retention). Detection/telemetry — the foundation for ranked provenance gating
> later.
>
> **Progress (2026-07-22): D4 part 1 shipped (closed-form reward bounds, detection).**
> The server now bounds what a WILD battle can produce. A `:battle_end_report`
> (outcome + foe pids, matched to the connection's D2 mints so a fabricated report
> opens nothing) starts a per-account budget window: the max EXP the party could gain
> (`reward_calc.rb` reproduces the gen-8 scaled formula at its maximum × the full
> multiplier stack × 6 gainers) and the money it could move (Pay Day gain / blackout
> loss, scaled to the exported max level). Money `:econ` deltas then get a clean
> ledger attribution (`battle:<n>` / `unattributed` — never a suspect label persisted),
> and over-budget money or an impossible party level jump (checked via the newly
> exported growth curves) is LOGGED. Detection-only, nothing rejects. Level items used
> outside a battle (a Rare Candy pays for a level, an Exp. Candy for its EXP) are read
> from the bag snapshots and credited first, so using them is not suspect; where the
> items came from is the inventory audit's question. A trainer battle opens a window too:
> the client names the trainers it loaded, and the server takes their parties from the
> battle data export, only for a trainer whose battle starts on the player's map (the
> world export places them). A battle lost after a knockout still bounds the EXP it
> paid. A catch keeps its mint stashed so
> the battle's end report still opens the window for the catch's EXP, and the client
> holds its flushes during a battle so the party projection follows that report.
> `PEMK_BATTLE_ENFORCE_REWARDS` off/shadow/on, default
> off; needs encounters=on for foe context. Adversarial review caught (and fixed
> before commit) a persisted-false-accusation bug (a spend after a win labeled
> suspect in the ledger), an inert-client bug (foes wiped before the report), and a
> cross-thread window race.
>
> **Progress (2026-07-22): D5 shipped (statistical anomaly detection — the backstop).**
> Purely server-side, and it NEVER enforces — it turns the D2-D4 telemetry into a human
> REVIEW QUEUE (`anomaly_reports`), because a lucky player looks like a cheat. Two
> signals: per-account SUSPECT counters (`player_flags`, atomically incremented at the
> reward/catch-spam/encounter detections) and a provenance mix — a `client`-origin mon
> whose species is in a wild table is a fabricated wild catch, attributed to the
> immutable MINTER (`issuer_account_id`, so a fabricated mon traded to a victim can't
> frame them), eggs excluded. A periodic worker-thread sweep (≤ every 60s, non-
> overlapping) refreshes reports past their thresholds. `PEMK_ANOMALY_DETECTION` binary,
> default off; migration 010 additive. Adversarial review caught (and fixed) a
> trade-griefing false-positive (owner- vs issuer-grouping). Tier 1 detection is now
> complete. Next: D6 (per-mon EXP/level authority) or the engine tier (D7+).

> **Progress (2026-07-25): D6 part 1 shipped (per-mon EXP high-water + rollback detection).**
> The foundation of per-mon EXP authority, still detection-only. The party projection now
> carries each mon's `:exp`; the server keeps a per-UID **high-water** (`monster_stats`,
> migration 011 additive) — the most EXP a mon has ever legitimately reported. EXP never
> decreases in normal play, so a reported EXP BELOW the high-water is a save-rollback / edit
> (a distinct signal from D4, which bounds EXP *increases*). Only uids the account **owns**
> are tracked (a client can't move another mon's high-water); the high-water is never
> downgraded. A rollback is flagged **once per high-water** via a `rollback_flagged` latch,
> cleared only when EXP climbs back past it — a single no-fault crash (a restored save behind
> the live high-water) re-projects the low EXP on every subsequent frame and un-latched would
> flood the D5 queue; it now yields one flag (D5 `exp_rollback` threshold 3). Adversarial
> review caught exactly this per-frame re-flag amplifier. `PEMK_BATTLE_ENFORCE_EXP` tri-state,
> default off. Part 2 (`on`: reconcile the client party to the server high-water at login) is
> the risky save-migration and remains ahead.

> **Progress (2026-07-25): D6 part 2 shipped (`on` = up-only EXP restore to the high-water).**
> Design chosen via a 4-stance judged panel; owner picked **high-water give-back**: the party
> stays blob-shaped (the server cannot rewrite it), so `on` is a server DIRECTIVE — the
> `:mon_ack` carries `:exp_correct` `[{uid, exp}]` for party mons below their high-water, and
> the client's new `ExpCorrect` module (PosCorrect's template) raises each to the target on a
> safe overworld frame — **never lowers** — then re-projects + checkpoints (self-terminating;
> re-sends are no-ops). The crash race is the feature: earned-but-lost EXP comes back. No new
> frames, no migration; `shadow` logs the would-restore plan once per rollback episode.
> Adversarial review (5 lenses, refutation-verified) caught a real HIGH: **Shadow Pokémon's
> `exp=` override diverts the write into `@saved_exp`** — an unguarded apply would loop
> forever, inflate the purification payout to level 100, and corrupt a legit save. Guards
> shipped: shadow mons skipped; the write is verified (any fan-plugin `exp=` override skips
> for the session instead of looping); the target is clamped to the mon's growth-curve max
> (server clamps the STORED high-water per-species too — a hacked projection can't be
> memorized then re-imposed); held 1 EXP short of the cap when the species can still evolve
> (Gen<=7 level-up-evo trap); fainted mons stay fainted; `safe?` also excludes running
> events/message boxes; and the restore's own level jump is **exempted one-shot from the D4
> reward audit** (it would otherwise SUSPECT-flag the server's own correction). Honest
> limits: the restore is silent (no UI event); an egg or species-clamped mon below its
> high-water re-emits as a bounded no-op until it grows past it; D5 `exp_rollback` flags
> still accrue in `on` (the episode self-heals but stays visible to the operator); a hostile
> server can raise (never lower) EXP up to the species cap. **Operator note: level-jump
> judging (D4/D6 exemption paths) needs growth CURVES in battle_data.json — re-run the F9
> "PEMK: Export Battle Data" if your export predates D4.**

> **Progress (2026-07-25): D8 shipped (per-battle re-sim ENFORCEMENT — quarantine-first).**
> The D7 corpus now has teeth, under its OWN flag `PEMK_BATTLE_ENFORCE_RESIM` off/shadow/on
> (an operator's `rng=on` never silently becomes rejection). Model: **provisional-until-
> verified, walk-tier bite**. A seeded catch is born `verify_state='provisional'` (migration
> 013, additive); the ingest-time SEED WALK is the ONLY tier that can condemn (it's
> cryptographic — value-by-value seed refutation, engine-drift-independent), and the harness
> replay verdict only CERTIFIES (`match`→`verified`, the D9 ranked asset) or withholds — it
> never auto-condemns (drift-prone). A `walk_mismatch` poisons its encounter roll
> (`condemned_at`) and quarantines the caught mon after `PEMK_RESIM_MIN_STRIKES` (default 2)
> distinct refuted battles, gated by an FP-STORM breaker (≥3 accounts adverse in one
> `engine_fp` cohort → suppress, re-adjudicate later). Quarantine rides `monsters.status`
> ONLY (the M3.2 trade CAS already blocks it — zero trade-code change) + a provisional
> **trade hold** released the moment the walk clears (seconds), 60-min fail-open TTL so a
> dead harness never bricks trading. **Nothing is ever destroyed; EXP/money untouched; the
> `flagged` bit is not overloaded.** The `ResimVerdicts` sweep runs on the live server
> (single-writer — the harness never touches monsters), idempotent + fully audited
> (`enforcement_events`). Operator console `bin/pemk_quarantine.rb` (list/show/pardon/
> reports); **pardon is a one-command FULL reversal** (active + verified + un-poison roll +
> mark evidence `pardoned` so strikes don't re-arm). Ramp: `bin/pemk_replay.rb` daemon
> (`PEMK_REPLAY_LOOP`), evasion covered by D5 `rng_silent` + `resim_claim_evasion` sweeps.
> **Adversarial review (5 lenses, 13 confirmed, all fixed):** shadow no longer burns the
> on-mode idempotency slot; storm-suppressed records stay actionable (no permanent
> forgiveness); a NULL-unsafe `!= 'pardoned'` that silently disabled all quarantine; NULL
> `caught_at` trade-held forever; verify consuming an un-minted catch; condemn made
> transactional + `FOR UPDATE`-serialized against the mint claim. 369 tests green.
> **Honest limits (documented, not bugs):** (1) an HONEST-seed battle with a LIED outcome
> (real draws, fabricated init/result) passes the walk and is never condemned — only the
> harness replay `mismatch` catches it, and that WITHHOLDS `verified` (D9-ineligible) rather
> than quarantining; exact-EXP/outcome enforcement is out of scope. (2) `MIN_STRIKES=2`
> gives the first proven-fabricated catch a pass (drift tolerance; tune to 1 for a harsher
> server). (3) The FP-storm breaker can't fire on a 1-2-player server — mitigated by
> **shadow-first** (would_quarantine audits surface a fleet-wide bug before any state change)
> + full pardon; walk_mismatch is cryptographic so an honest player produces zero of them
> unless our vendored PCG32 skews (guarded by the byte-identity test). (4) `engine_fp` is
> client-reported/inventory-level; a cheat ring sharing it can DELAY (not permanently evade)
> condemnation to human review — server-attested build tokens are a v-next hardening. (5) A
> mon traded out during the fail-open window and later condemned quarantines the innocent
> holder; routing that to review instead is a v-next. **D8 done; next: D9 ranked PvP** (the
> north star — commit-reveal seeds, battle_sessions from the trade rendezvous, Glicko-2,
> reading `verify_state` for eligibility).

> **Progress (2026-07-25): D7 part 1 shipped (the engine tier's deterministic seam).**
> **STEP-0 GATE PASSED:** the unmodified v21.1 battle engine runs HEADLESS on plain MRI —
> real 3v3 AI-vs-AI battles to decision in ~30 ms, and same-seed runs in separate processes
> produce byte-identical transcripts. The reuse-not-reimplement thesis is empirically
> validated; the ordered 109-file load list + 327-line stub inventory live in
> `server/harness/spike/` (part 2's skeleton). Traps recorded: `PBDebug.logonerr` SWALLOWS
> exceptions (a broken headless battle silently plays ~100 empty rounds — the harness must
> make it fatal), `$game_switches` is read every AI command phase, `nil_or_empty?`/`validate`
> are required Kernel functions, `Player` must load even for NPC-only battles.
> **Shipped:** `protocol/pemk_prng.rb` — canonical PCG32 validated against O'Neill's
> reference vectors, pure Integer math (bit-identical MRI/mkxp-z), domain-separated streams
> (battle/AI/run), unbiased `rand_below`, vendored byte-identical to the plugin (test-
> enforced). `PEMK_BATTLE_ENFORCE_RNG` off/shadow/on (default off; **rejection is D8's own
> separate flag — an operator's `on` here can never silently become enforcement**). A 63-bit
> seed is born with each D2 mint and rides `:encounter_grant`. Client `010_BattleRng`:
> shadow RECORDS any single-foe wild battle (Safari excluded — it overrides `pbRandom`);
> `on` DERIVES all draws from the seed's streams, latched at arm time. Capture = per-round
> `@choices` snapshot at END of `pbCommandPhase` (slots are ACT-dependent — encoded by TYPE;
> a positional filter would drop every thrown ball's item id, review-caught) + `@megaEvolution`
> + forced switches + `pbRun` events (the "Use next Pokémon?"→No path is otherwise invisible)
> + init frames (TeamReport-shaped) + outcome at `pbEndOfBattle` ENTRY (pre-Pokérus/form-reset)
> + per-stream packed (bound,value) logs, counts, FNV-1a64 fps. Server: `battle_records`
> corpus (raw body stored VERBATIM for part-2 replay; single-use-per-roll as a DB constraint;
> hourly ingest cap) and **THE SEED WALK** — for bound `on` records the server re-derives
> every draw from its own seed and compares value-by-value, cross-checking env counters and
> fps against the body; results persist as DISTINCT statuses (`walk_ok`/`walk_skipped`/
> `no_log`/`walk_mismatch`/`mode_mismatch`) so log-stripping evasion is as visible as
> failure; a mismatch feeds D5 `rng_desync` (threshold 3). Fabricated favorable rolls are
> now mathematically refutable.
> **Honest limits (all deliberate):** part 1 is INSTRUMENTATION — a modified client can
> ignore the seed, claim `desynced`, truncate, or send nothing; each evasion is *visible*
> (statuses, D5, and part 3's granted-but-recordless sweep) but nothing rejects until D8.
> Seed-at-grant gives lookahead within one wild battle (accepted for PvE; D9 PvP will use
> commit-reveal). The un-logged tail beyond 4096 draws/stream is unverifiable by the walk
> (part-2 replay covers it). `engine_fp` is inventory-level (path+size; compiled games
> degrade to dats+plugins). Ball-throw provenance (server vs local-fallback shakes) is
> reconstructible by joining D3's persisted rolls — part 2 should add the per-throw event.
> A `mode_mismatch` can be an honest pre-flip session (mode adopts at login) — logged, never
> flagged. **Operators: plan `battle_records` retention before running shadow at scale
> (worst case ~30 MiB/hour/account at the cap; a prune job lands with part 3).**
> Next: **D7 part 2** — the MRI headless harness (from the spike skeleton) + replay of
> corpus records; then part 3 (parity measurement at scale).

> **Progress (2026-07-25): D7 part 2 shipped (the headless replay harness) — REAL battles
> re-simulated at 100% parity.** `server/harness/` productionizes the spike: hardened stubs
> (`PBDebug.logonerr` TRANSPARENT — an engine exception fails the replay, closing the step-0
> trap; deterministic fake clock; fixed noon time), a 114-file proven engine load (real
> `ItemHandlers` + in-battle item procs — balls are engine code, not stubs; ShadowPokemon's
> `Battle::Battler` reopen; Metadata/Pokedex for the Player path) and a boot tripwire that
> refuses to load inside the live server process. `replay.rb` re-simulates a captured record:
> parties rebuilt from init frames, BOTH sides' choices re-registered per round (vanilla
> playback pattern), draws derived from the seed's PCG32 streams (`on`) or value-replayed
> with bound verification (shadow), `pbRun` events re-executed (the "Use next Pokémon?"→No
> confirm answered from the pending event — via `pbDisplayConfirmMessage`, the method the
> engine actually calls), mega state restored, D3 catch verdicts injected ONLY on the final
> recorded round of a caught record, Struggle rounds auto-chosen. The verdict digests at the
> SAME seam as the recorder (`pbEndOfBattle` entry) and requires decision + turn count +
> per-mon HP/status/EXP + FULL record consumption (an early-ending divergent replay can
> never silently MATCH). Truncated/desynced records short-circuit to `not_replayable`.
> `bin/pemk_replay.rb` batches `pending`/`walk_ok`/`walk_skipped` records and stamps the
> verdict; triage statuses (`walk_mismatch`/`no_log`/`mode_mismatch`) are never overwritten
> without `REPLAY_FORCE`. **Validated: 5/5 real in-game battles (4 wins + a Sleep-Powder →
> Master-Ball catch) replay to MATCH under the hardened comparator; two of them are frozen
> as regression fixtures the suite replays on every run.** The corpus lifecycle is live:
> `pending → walk_ok → match`. Adversarial review: 25 confirmed findings fixed (the big
> three: catch verdict blessed EVERY throw; turns/consumption never compared; the confirm
> override was dead code). Honest limits: verdict granularity is end-state (PP burned /
> items consumed mid-battle are not compared — part 3 can tighten); `$bag` is empty (Exp
> All-class items uncaptured — a bench-EXP mismatch will surface them); replay needs the
> game repo's Data/ (server-only deployments skip the harness test). **In-game validation
> then covered the hardened paths on purpose: a 5-round multi-ball catch, a flee, a
> 7-round faint+switch battle — 9/9 real-battle parity, the two hardest frozen as suite
> fixtures.** Next: **D7 part 3** — parity at scale (batch stats, corpus
> retention/pruning, the granted-but-recordless sweep) — then the D8 decision.

> **Progress (2026-07-25): D7 part 3 shipped (parity at scale — D7 COMPLETE).**
> (1) **Corpus retention**, the promise made to operators: at boot the server prunes
> `match` records older than `PEMK_CORPUS_RETENTION_DAYS` (default 30, 0 = keep forever)
> — matched records are *spent* proof; every other status (`mismatch`/`walk_mismatch`/
> `no_log`/`mode_mismatch`/`error`/pending) is EVIDENCE and is never auto-pruned.
> (2) **The evasion-by-silence sweep** (D5): a CAUGHT seeded encounter proves its battle
> concluded — if no battle record ever arrived, the client withheld it. Reported as
> `rng_silent` only for accounts that have EVER sent a record (an old client without the
> recorder plugin sends none — a mixed fleet must not flag) and past a 1-hour grace
> window (crash/disconnect losses). ≥5 silent caught mints → review-queue report.
> (3) **Corpus parity report** in `bin/pemk_replay.rb`: status×mode breakdown + parity
> per `engine_fp` cohort — a cohort whose parity collapses is version drift or a cheat
> cluster. (Validated live: the day's two client builds appear as two cohorts, both
> 100%.) 343 tests green. **D7 (parts 1-3) is COMPLETE**: unforgeable seeded RNG,
> walk-verified capture, headless re-simulation at proven 100% real-battle parity, and
> the operational loop to run it at scale. The engine tier's enabling milestone is done —
> next decision: **D8** (per-turn PvE re-sim with REJECTION, under its own
> `PEMK_BATTLE_ENFORCE_RESIM` flag per the operator contract) or D9 groundwork.

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
- **Fork caveat (open-source operators):** the high-water assumes strictly-monotonic EXP.
  Vanilla Essentials never lowers a mon's EXP (the level cap plateaus, eggs grow from 0,
  hatching keeps the object, trades only move ownership), so the base kit is safe. A fork
  that *clamps EXP downward* — a hard cap refunding overflow, set-level battle rooms — would
  produce a legitimate decrease and read as a rollback. Keep such forks on `shadow` (never
  `on` with `PEMK_ANOMALY_DETECTION`) until they teach the server about the clamp.

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