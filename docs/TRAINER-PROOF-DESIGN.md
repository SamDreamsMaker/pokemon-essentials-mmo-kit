# Proving a trainer battle before its prize is paid

Design, 2026-09-29 (revised after its adversarial review). Money authority
(docs/MONEY-AUTHORITY-DESIGN.md) pays a trainer's prize on the client's claim, judged by
placement, cadence and daily caps: a claim proves no fight. This design lets the server
prove that the battle was fought and won, against the trainer's real team and AI, with
randomness the client did not choose - before the prize counts.

## 1. What the engine gives us (research, 2026-09-29)

- The foe team is deterministic. `GameData::Trainer#to_trainer` draws with Kernel#rand
  (personalID, IVs) but overwrites each drawn value from the PBS data or a fixed default
  (gender, ability index 0, nature, IVs, EVs, shiny, moves, held item). Only the FORM of a
  few species survives: random at creation (Unown, Pumpkaboo, Minior, Sinistea, Alcremie,
  Urshifu) or taken from map, clock or player (Burmy, Lycanroc, the Scatterbug line).
- In battle the rolls go through `Battle#pbRandom` and `Battle::AI#pbAIRandom`, both tapped
  by the D7 recorder; one Kernel#rand is left in AI scoring (Shell Side Arm's tie).
- The prize has no randomness: max level of each foe team x base money, x2 Amulet Coin /
  Luck Incense on the player's side, x2 Happy Hour; added in `pbEndOfBattle` on a win.
- Nothing names a trainer to the server when the battle starts; the claim goes out inside
  `pbEndOfBattle`, before any record exists.
- The D7 recorder captures both sides' choices, forced switches and the outcome; the
  harness replays wild battles by re-registering both sides' recorded choices - it has
  never re-run the AI, and raises on any AI draw.

## 2. The model

1. **One seed per placement.** When a trainer loads, the client asks
   (`:trainer_battle_req {trainers, map, event, page}`); it waits for the answer at
   `pbStartBattle`, behind the transition. The server checks the placement against the
   export and the player's position, and hands out THE seed of (account, placement, page):
   made on the account's mailbox under a unique index, the same answer however often it is
   asked, replaced only after a proven win or a server-side expiry - never after a loss the
   client reports. The answer also sets what the client would otherwise choose: weather and
   terrain, the rules, the forms the export leaves random.
2. **A battle the client cannot steer.** Every draw of both streams comes from the seed
   (D7 `on`). The record carries what a replay needs: the trainers and their bag, the
   player's items used, every "Will you switch?" answer and forgotten move, the switch
   style.
3. **The record goes first.** It leaves at `pbEndOfBattle` entry, before the claim, and is
   kept with the claim until the server has it.
4. **The replay decides, in seconds.** The ingest walks the seed (D7) and binds the record
   to its seed row (one record per row, one claim per record). The replay daemon, woken at
   once (Postgres NOTIFY), rebuilds the FOE team with the engine's own `to_trainer` from the
   game's data, checks the PLAYER team against the server's own knowledge (owned uids,
   first-sight locks, the last team report, legality, EXP at most the high-water), replays
   the player's choices and RE-RUNS the trainer's AI on the seed's AI stream: the foe's
   choices must be the AI's, the outcome a win, the recomputed prize the claimed amount,
   the claim's trainers the row's.
5. **Pay on the verdict.** A proven claim is paid - within the client's 60-second hold. A
   refuted or unreplayable one is held unpaid, never voided (engines can drift; D8 never
   condemns on a replay alone), and replayed again after a harness fix.

## 3. Steps

- **P1 - can the AI be re-run? (no protocol change, shadow only).** The recorder records
  single battles against one trainer in shadow; the harness loads the trainers' data,
  builds the foe team with `to_trainer`, replays the player's choices and re-runs the AI on
  the recorded AI draws, and compares the foe's choices. Parity over real battles (the
  autotest fights the demo's trainers) is the go/no-go for everything below.
- **P2 - the seed.** Request and answer, the seed rows (migration), the recorder arming in
  `on`, the record additions, the record before the claim.
- **P3 - the verdict.** Claim-record-seed binding, the player-side checks, the NOTIFY-woken
  daemon, `proven` / `refuted` / `not_replayable`; shadow logs what `on` would hold.
- **P4 - enforcement,** first for repeatable single-trainer placements and rematches (the
  open-ended farm the daily cap only bounds), then one-shot trainers, then doubles and
  partners.

### P1 results (2026-09-29): go

- The recorder records single battles against one trainer in shadow: the trainers, their
  bag, the battle's settings, every yes/no the player answered and each move forgotten,
  and the map (a level-up's happiness reads it).
- The harness rebuilds the trainer with the engine's own `to_trainer` from the game's
  data, refuses a record whose foe team or bag differs, registers the player's recorded
  choices, re-runs the trainer's AI on the recorded AI draws, and compares its choices,
  its Mega Evolution and its replacements; the prize is recomputed.
- Autotest 083 fights Camper Liam and Brock (AI skill 100, two Full Restores): 8 battles
  over four runs, 3 to 12 rounds, won and lost, replayed to the same end and the same
  money. A unit test replays a frozen Brock record and altered copies (an AI choice, a
  replacement, the foe team, the bag, the trainer): each is refused, with its reason.
- Found on the way: a level-up in any replayed battle crashed the harness (no
  `$game_map`); it now has one, set to the recorded map, and the corpus's caught
  battles that failed on it replay to a match.

### P2 (2026-09-29): the seed

- Under `PEMK_BATTLE_ENFORCE_RNG=on` the login says trainer battles are seeded
  (`trainer_seed`). A trainer loaded for a battle asks its placement's seed at once
  (`:trainer_battle_req {nonce, trainers: [[type, name, version, map, event]]}`); the
  battle's start waits for the answer, at most two seconds, behind the transition.
- The server answers only a placement the export knows, on the map the player stands on,
  and one trainer at a time (single battles first): `:trainer_battle_seed {nonce, seed}`,
  else `:trainer_battle_deny {nonce, reason}` and the battle is recorded unseeded.
- The seed is THE open seed of (account, placement) - migration 042, `trainer_battles`,
  one open row per placement under a unique index: asked again, the same answer; a new one
  only once a win on it is proven (P3) or after a day. Every attempt's record names it.
- The record leaves at `pbEndOfBattle` entry, before the prize claim; the ingest binds it
  to its seed row (`battle_records.trainer_battle_id`) and walks it.
- Autotest 084: Liam, then Brock twice under `on` - three seeded battles, the two against
  Brock on the same seed (and, the same choices, the same battle), each walked and
  replayed from the seed, the AI's draws included, to a match.

### P3 (2026-09-29): the verdict, in shadow

- A prize claim names the seed its battle ran on (`:money_claim ... seed`); the server
  links the claim to the seed's row when the row is this account's and names the claim's
  own trainer (migration 043: `money_claims.trainer_battle_id`, `proof`).
- The replay tool (`bin/pemk_replay.rb`) also checks the player's team against the
  server's own (`ProofChecks`): each Pokemon registered, owned, active, its first-sight
  lock kept (IVs - or 31, Hyper Training - shiny, gender), no more EXP than the server has
  seen; it writes `replay_prize`, `replay_detail` and `team_check`. As a daemon it wakes on
  the server's `NOTIFY pemk_replay` for each record, not at its next poll.
- The live server's sweep (every 5 s) gives each linked claim its verdict: **proven** (a
  won record, replayed to a match, the player's team the server's, the replay's prize the
  claimed amount - the placement's seed is then spent), **refuted** (the draws are not the
  seed's, the replay or the team disagrees, another prize), **unprovable** (no won record
  in ten minutes, a record that cannot be replayed, an unregistered Pokemon). One record
  proves one claim. Shadow: `trainerproof: ... PROVEN` / `WOULD-HOLD (reason)`, nothing
  held.
- Autotest 085: an honest win over Camper Liam is proven and spends the seed; a modified
  client that asks Brock's seed, makes the battle up and claims his prize is refuted.

### P3's review, and P4 (enforcement) as it will be built

The review of the first P4 draft found, in P3 as built, that one win could be proven
again and again (a copy of its record, another claim naming the same battle) and that
claims against trainers fought again were never judged: fixed before P3 merged - a seed
holds one won battle and one claim (migration 044), records bind to an open seed only,
and `repeatable` claims are judged. For P4 it gave a simpler, safer shape:

- **`PEMK_TRAINER_PROOF` off | shadow | on**, default off; `on` enforces only when money
  authority enforces and battle rng is `on`, otherwise it runs as shadow and says why.
  Only placements the export marks provable (one trainer built from the data, a single
  battle, no partner) are enforced; the boot names the others.
- **The sweep only decides; the next ask pays.** The sweep writes the proof; when one
  lands, the online client is told to ask again at once. The payment happens where M3
  pays today - on the account's mailbox, in the answer's own transaction - so `first`,
  voids, seals and the daily counters keep their meaning and nothing races them.
- **A claim is `held` until its proof**: nothing credited, its payout keys reserved, void
  at a fresh login like any unsealed claim (nothing to take back). The client keeps it,
  renews its hold and asks again; a Mart does not wait on held claims.
- **Proven: paid. Refuted: refused**, and flagged. **Unprovable** is paid from the day's
  allowance (`PEMK_MONEY_UNPROVEN_DAILY`) only when the cause is the server's (it denied
  or did not answer the seed, the placement is unprovable); a claim with no seed, or
  another seed, for a placement whose seed was handed out is refused. While a record
  waits for its replay the claim stays held; the daemon's silence is an alarm, not a
  verdict.
- **Pay Day** in a trainer battle waits while its prize is held and counts only a proven
  prize.
- **The record is kept until the server has it** (an acknowledgement), and sent again on
  a new connection.
- **Old clients are refused at login** (capability `trainer_proof`), as M3 does.

### P4 (2026-09-29): enforcement, as built

- `PEMK_TRAINER_PROOF` off | shadow | on (default off). `shadow` is P3; `on` enforces where
  money authority enforces and battle rng is `on`, else runs as shadow and says why. The
  boot names the battles with more than one trainer (never proven) and asks for the
  replay daemon. Old clients are refused at login (capability `trainer_proof`).
- A payable prize goes through the proof gate:
  - its claim names its battle's open seed: **held** - nothing credited, its battle's
    payout keys reserved, the seed row linked (`money_claims.trainer_battle_id`);
  - it names another seed (not this account's, not this placement's, spent, or a battle
    another claim holds): **refused** (`proof = wrong_seed`), flagged;
  - it names none (a battle fought offline, a seed that came late, a battle against
    several trainers or with a partner - or a client that never asks), or its placement
    shares a battle call: paid from the day's allowance (`PEMK_MONEY_UNPROVEN_DAILY`,
    default $5,000; `money_daily.unproven_paid`, migration 045). With no room left today
    it stays held and is paid the next UTC day (the answer says when to ask again); a
    prize over the whole allowance gets the allowance on a day nothing was paid from it.
- The replay tool replays a record bound to a seed row on that row's seed and against
  that row's trainer, whatever the record's body says (a body not a trainer battle's, on
  another seed, in shadow, or against another trainer is refuted before any replay); a
  trainer record that claims no draws is `no_log`. It checks the player's team with the
  game's battle data too: each Pokemon the species it was first seen as or an evolution
  of it, and a legal set (D1's checks; a move or an ability no data explains may come
  from an event: unprovable); its EXP stated (the replay's level follows it) and no more
  than the server has seen (none seen: unprovable). The trainer battles' won records are
  replayed first. A record it fails on is stored as an error (its prize unprovable) and
  stops nothing; what a record says is stored scrubbed.
- `on` needs the team lock (D1, `PEMK_BATTLE_ENFORCE_TEAMS`) and EXP tracking (D6,
  `PEMK_BATTLE_ENFORCE_EXP`) besides money enforcement and battle rng: without them a
  record's IVs and levels would be its word. It runs as shadow and says so.
- The sweep only decides (`proof`): **proven**; **refuted**; **unrecorded** (no won record
  in ten minutes - the client keeps it until acknowledged, so it is the client's doing);
  **unprovable** (a record the harness cannot replay, a trainer that is not the game's data
  - the game may edit its trainers as they load -, a team the server cannot check yet). A
  record still waiting for its replay gives no verdict: the claim stays held and the
  server warns that the daemon is silent. A proven win spends the seed row; any other
  verdict lets the claim and its record go of it, the seed staying (a claim no replay
  proves never buys a fresh seed). Each verdict tells the online client
  (`:money_claim_ready`).
- The client's next ask pays, on the account's mailbox and in that answer's transaction:
  proven is paid what was held, unprovable comes from the allowance, refuted and
  unrecorded get nothing (the battle stays paid for). A refusal stands in every mode;
  with enforcement turned off since, a held claim without one is paid as M3 pays it, and
  its money comes back to the game (`held: true`).
- A held claim is sealed only by a save whose blob carries it (the save frame names the
  newest 64 claims the client wrote into it), so a fresh login voids it - its keys, its
  seed row and the seed's one win free, the battle fought again judged on its own record
  - unless the save that loads has it. Voiding it takes nothing out of the shadow
  balance, which it never reached.
- A trainer battle's Pay Day waits while its prize waits for its replay, or for the ask
  that pays it once proven (`held`, not recorded), and counts only a proven prize; after
  a prize no replay proves it is not paid, and not flagged. A claim over its bound is
  flagged whatever the gate made of it.
- The client: a held prize leaves the game's money until it is paid (no money frame and
  no Mart waits on it), stays in the list and is asked again every ten seconds, at once on
  `:money_claim_ready`. A seed is asked only for a battle the recorder arms (no size rule
  but a single battle's, no partner that could join); under `on` the battle's start waits
  up to six seconds for it. A trainer battle's record carries a nonce and stays in the
  save (four at most, 128 KB) until `:battle_record_ack` - kept as the battle was armed,
  so a link lost mid-battle loses nothing -, sent again on a new connection and every 30
  seconds. The server knows a copy by its nonce (`battle_records.client_nonce`), counts
  trainer records apart from the wild ones' hourly cap, and acknowledges none it could
  not store.
- Autotest 086: Camper Liam's prize held (the ledger and the game without it), replayed,
  proven, paid at the next ask (both with it); a modified client that claims Brock's prize
  without its seed is paid from the allowance at most, and one that makes his battle up
  on the seed is held, then refused.
- `docker-compose.yml` now passes the money knobs (`PEMK_MONEY_*`, `PEMK_TRAINER_PROOF`),
  which it did not.

### P4's review (2026-09-29)

An adversarial review of P4 as built found, all fixed before merge: the replay took its
seed and trainer from the record's body (a client could replay a win found on another
seed); a link lost mid-battle lost the record, so the honest prize was refused; a voided
or unproven claim kept its seed row, so the battle fought again was refused; a stale save
(a reconnect pushes the file on disk) sealed held claims it did not carry; a record the
database failed to store was acknowledged; the hourly record cap was shared with wild
battles; voiding a held claim took money out of the shadow balance; an exhausted
allowance used up the battle for nothing; a stored refusal was forgotten when
enforcement was turned off; a partner doubled a seeded battle's bound. It also showed
that refusing a claim for dropping a seed its connection was handed only ever caught
honest players (a cheater simply never asks), so such a claim is paid from the allowance
like any other without a seed.

Its verification found, also fixed: a record whose Pokemon carried a stat key of its own
(with bytes the database refuses) crashed the replay daemon on every restart, holding
every prize - the checks read the six stats only, what a record says is stored scrubbed,
and a record the tool fails on becomes an error; a save named its oldest 64 claims, not
its newest; a battle fought again after a void was judged on the first fight's record;
closing the seed row on any verdict let a client buy fresh seeds with unprovable
records; a record without EXP chose its level; a proven prize not paid yet let its Pay
Day go unproven; the suspect flag was lost under the gate and a Pay Day after an
unproven prize was flagged.

## 4. What stays open

- Lookahead: a client knows its seed before it plays, so it can simulate the battle ahead
  (D7 accepted this for wild battles). Revealing each round's draws only after the
  player's choices close it, at one round trip per turn.
- A bot that fights for real is not a cheat this can see; caps and cadence still bound it.
- Placements the export cannot rebuild (a trainer built by a script, edited in
  `:on_trainer_load`) are unprovable: their prizes come from the allowance.
- The allowance is the bound for everything unproven: a client that never asks for a
  seed, or sends a record the harness cannot replay, gets at most
  `PEMK_MONEY_UNPROVEN_DAILY` a day.
- The player's team is checked for what each Pokemon can be (owned, locked traits, EXP
  seen, species line, a legal set) - not for the exact set it has: a nature, a legal move
  or a holdable item it does not have would pass, and so would a battle-only form from
  the first turn. The EXP seen is what D6 took from the client's reports, within its caps.
- The battle's weather, terrain and environment are the record's word (the export does
  not say what each map's battles get).
- Money authority turned off entirely leaves held prizes where they are (their money out
  of the game) until it comes back; a Pay Day held with its prize, paid after
  enforcement was turned off, does not give its coins back.
- The replay runs the server's copy of the game: a server whose game files differ from
  the players' refutes honest battles. Run `shadow` first and read its `WOULD-HOLD` lines.

## 5. Sam's decisions (2026-09-29)

- **Unproven claims under `on`** (no answer to the seed request, an unprovable
  placement): **held, and paid from a small daily allowance**. Old clients are refused at
  login, as M3 does.
- **Lookahead: accepted for now**, as for wild battles; revealing each round's draws
  after the player's choices stays possible later.
