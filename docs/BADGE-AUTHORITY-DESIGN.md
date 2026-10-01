# The server owns the badges

Status (2026-10-01): designed and reviewed; B0 (the export), B1 (shadow) and B2
(enforcement) built. Off by default (`PEMK_BADGE_AUTHORITY` off | shadow | on; `on` runs
as shadow while a blocker stands, section 4).

## 1. Why

In Essentials a badge decides the field moves (`pbCheckHiddenMoveBadge`, by badge or by
count), how high a traded Pokemon obeys (`10 x (badges + 1)`), the stat boosts some games
give per badge, and whatever the game's events test. Today a new badge bit is the
client's word: a memory edit, an edited event or the debug menu sets it, and the ledger
keeps it. Trainer proof P4 already holds a replay's badge count to the ledger's - which
is circular while the ledger is the client's word.

What the server reads of the badges today: the login restore and the proof checks. Field
moves and event gates stay on the client (the position audit takes a surfer's word): a
later step consumes the server's mask for them.

## 2. How badges flow today (the review, with the code)

- The ledger keeps badges monotonic only when flag state is `on`; otherwise a frame
  assigns them. M3's `no_increase` compares integers, so a mask of `0b011` over `0b100`
  counts as no increase: a badge check must be bitwise (`value & ~ledger`).
- A fresh login overwrites the client's badges with the ledger's: a bit only the save has
  is lost at the next login, today.
- The client reports only `badges[i] = ...` writes; a badge frame goes out at once (only
  money waits for the claims).
- The demo's Brock sets badge 0 in a script continuation line, at the own level of his
  `TrainerBattle.start` win branch. The demo's player house (map 3, event 7) offers "Debug
  mode" (`$DEBUG = true`: the debug menu, battles skipped as wins) and "Give all badges"
  (`$player.badges[i] = true` for 16 badges) to anyone who talks to it.

## 3. The model

- **A badge is granted by a proven win, nothing else.** The ledger gets a bit only from
  the server: when the claim for its source battle is settled `proven` (the stored proof,
  never the "paid as M3" of enforcement turned off), in that settle's own transaction. A
  held, allowance-paid or M1-paid claim, a void, a refusal, an unprovable verdict: never.
- **A frame never raises the ledger's badges.** Under `on` the new bits of an econ frame
  are dropped (bitwise), and the answer is the mask the client should show.
- **The client shows `ledger | pending`**: pending is the win-source bits of this
  account's seeded held claims (verdict held, not voided, a seed row, no refusal) whose
  seed holds a won record the seed walk did not refute - no table, and every refusal and
  void ends it by itself (they unlink the claim and its record). A claim alone is no win:
  voided at each fresh login and claimed again on its open seed, it would keep a badge
  pending without a battle (B1's review). No age limit: a record waiting for its replay
  waits, as its prize does (the replay daemon's silence is an alarm). The honest player
  sees the badge at once; it becomes the ledger's when the replay proves the win. Login,
  the acknowledgements and the proof checks use the same `ledger | pending`.
- **`badge_grants`** (account, badge, evidence `legacy | proof | operator | revoked`, source,
  claim nonce, granted_at; one row per account and badge) records why each bit is owned.
  `Ledger#grant_bits` sets bits bitwise (a server transaction, like `adjust`).
- **Cutover**: at the first `on` boot, the bits an account held before the badge
  authority judged it are `legacy` grants - no proof exists for wins before P4, and
  judging them would take them away. B1 keeps that mask, `badge_baselines` (the ledger's
  badges before the account's first judged frame); an account without one was never
  judged, and its whole mask predates the authority. A bit gained after the baseline is
  judged at the cutover like a new one: a shadow period is no window to keep what it
  logged WOULD-REFUSE (B1's review). A period with the authority off trusts the clients:
  what an account never judged gained then is legacy. The server reads no badge from a
  save: a bit only a save holds is lost at the next login today, and stays so.
- A rematch sets a bit already owned: nothing to judge (the union, and `badge_grants`
  first).

## 4. Blockers (`on` runs as shadow and names each)

Trainer proof not enforcing; an export without `badge_sources`; any unknown source (the
demo's house); any source no battle gives; a win source no replay can prove (several
trainers in its call, a battle paying no money - no claim, so no proof - or one trainer
in two battles giving different badges); a win source fought with no seed (a trainer the
export does not place, one sharing a battle call, a battle rule sizing it other than
single, or - in shadow - a partner possible: the game registers one - in an event or in
its code - or computes one, and the battle has no noPartner rule); a badge index at or
over `badges_max`. The export must see every badge write for a refusal to mean anything:
it lists as unknown any write to `$player.badges` it cannot read (a computed index, a
fill, an assignment) and, in the game's code, any to the player's own `@badges` /
`self.badges` but the new game's reset.

Two of these need no edit to the game (2026-10-01, from the demo itself):
- *A partner* keeps nothing from owning the badges: the clients fight a badge's battle
  alone. Wherever the server judges the badges and proves trainer battles (shadow or
  `on`, with trainer proof), `login_ok` / `auth_ok` name the placements whose win gives a
  badge and that a replay proves once fought alone (one trainer the export places, a
  prize, no size rule - the others change nothing by it); a client fighting one of them
  against that trainer alone (inside `TrainerBattle.start_core`, not a trainer who
  waited for another), with no size rule or a single one, online and seeded, sets the
  noPartner rule as the trainer loads -
  before the game decides whether the partner joins; the battle's own rules clear after
  it. The boot log counts them. From shadow on, so a win then is seeded, and proven by
  the time the server owns the badges. Owning them, the server needs `badge_alone`
  from every client (older ones get update_required: a partner the export cannot see -
  one a plugin sets - is fought alone too). Before that, a client from before
  `badge_alone` may still fight with the partner: its win has no seed, and the cutover
  lists it for the operator (`pemk_badges.rb unowned`, then `grant`); so in shadow, and
  in `on` held back, a partner the export lists keeps the flags off (said at boot).
- *A write that is not the game's* - a debug helper, like the demo's house help NPC:
  `PEMK_BADGE_IGNORE=map:event,ce:N,file:line` names unknown writes and sources no battle
  gives (map 3 event 7 for the demo's house). It keeps nothing from owning the badges;
  its badges are refused like any no win explains, and flag like them: a player who uses
  it asks for badges no battle earned (remove it from the game when you can). A name that
  matches no such write is said at boot. It is not for a badge the game means to give
  with no battle: that one stays a blocker (the server could not tell who earned it).

## 5. Steps

- **B0 - the export** (built): `badge_sources` - each literal set of a script line, at the
  own level of a win branch whose condition is exactly the battle call (then it names
  that call's trainers, `no_money` after a noMoney rule, `no_partner` after a noPartner
  one) or anywhere else (it names none); a line with a write it cannot read is listed
  unknown, with the badge writes of the game's own scripts and plugins (`$player`,
  `$Trainer`, `pbPlayer`). WorldData reads them: `win_bits(map, event, type, name,
  version)` and `badge_blockers`. A win is matched by its trainers at the event's map and
  event, not by a call index: a claim names its trainers, not its call - so a win over
  the same trainer on a page that gives no badge explains it too (a real win over him).
- **B1 - shadow** (built): for each new bit of a frame - over the ledger's and the
  baseline's, bitwise; not a frame the ledger refuses or has applied - log EXPLAINED (a
  proven win, its claim voided since or not), PENDING (a won record on the claim's seed,
  not refuted by the seed walk, waits for its replay), UNPROVABLE (a win claimed with no
  seed, or one the harness cannot replay) or WOULD-REFUSE, and why: one line per verdict
  and reason, a verdict already said for a badge not said again. The claims that count
  pay (verdicts paid, suspect, held, allowance): one away from its trainer, for a trainer
  the exports do not place or out of order explains nothing. When nothing keeps the
  server from owning the badges (else the game itself may give one), once per frame, a
  refusal flags `badge_unexplained` (one opens a review) and an unprovable win, from a
  client that asks for its battles' seeds, `badge_unprovable` (two do). The first judged
  frame keeps the account's baseline. On the account's mailbox: at the proof sweep,
  WOULD-GRANT for a proven win's badges, WOULD-DROP (flagged) for those another verdict
  leaves unexplained; at a fresh login, WOULD-DROP (not flagged: an honest client killed
  before its save is one) for those a voided claim showed. Autotest 088: an honest Brock
  win is PENDING, then WOULD-GRANT after the replay; a modified client's Brock badge with
  no battle, all sixteen at once, Brock's after a claim on his seed with no battle
  recorded, are WOULD-REFUSE; after a claim with no seed, UNPROVABLE.
- **For B2, from B1's review**: a win claimed with no seed is an honest player's too (the
  battle began offline, or its seed came late) and its badge would be lost for good (the
  gym's event is done): the client waits for the seed of a battle that gives a badge, and
  the operator grant covers the rest. A proven win's badge is granted at the proof, and
  stays when a fresh login voids its unsealed claim (the battle fought again sets a badge
  already owned) - 089 checks that rather than a lost badge. A shadow claim naming a seed
  that is not its own is unlinked - B1 says UNPROVABLE where `on` refuses it
  (`wrong_seed`); a record dropped over its hourly cap leaves an honest badge WOULD-REFUSE
  until it comes.
- **B2 - enforcement** (reviewed 2026-10-01, before any code). `on` enforces when trainer
  proof and money enforce and no blocker stands; its clients advertise `badge_hold` and
  `badge_alone` (older ones get update_required). Its review changed the plan:
  - *Owned, pending, shown.* Owned = the ledger, which only the server raises:
    `Ledger#grant_bits` ORs bits under `SELECT ... FOR UPDATE` of the badges row (never an
    `adjust` delta: two grants of one bit would carry into a badge nobody earned) and
    writes the `badge_grants` rows, in one transaction. Pending = the win bits of held,
    unvoided, linked claims with no proof yet whose won record's replay is undecided
    (pending, walk_ok, walk_skipped, or a match whose team check stands) - a decided
    record ends it before the sweep settles. Shown = pending, read first, then owned: a
    proof settled between the two reads is in one or the other.
  - *Grant at the proof*, inside `TrainerProofs#settle`'s transaction: no moment where the
    claim is no longer pending and the bit not yet owned.
  - *Frames never move the badges*: the frame's seq is recorded, the balance untouched
    (no raise, and no drop - a stale save's 0 erases nothing); the answer is `shown` (a
    duplicate frame's too). Bits it shows that are neither owned nor pending: REFUSED,
    logged and flagged as B1 does - but WAITING (not shown, no flag) for a claim whose
    won record is not in yet: over its hourly cap, a reconnect.
  - *The proof checks count owned badges only* (the replay daemon, obedience; with
    `PEMK_BADGE_AUTHORITY=on` in its environment, or - told nothing - while the server
    says it enforces: `badge_cutover` row 2, written at an enforcing boot and gone at any
    other, read at every pass; otherwise P4's rule, no more than owned; it says which when
    it changes): a record
    claiming more badges than owned, covered by earlier wins shown then not replayable,
    is unprovable (the allowance, no flag); where wins recorded before it (its own never -
    it would wait for itself) and still undecided are needed, it gets no verdict yet -
    their verdict decides, a made-up one refuted covering nothing - retried at the next
    pass, at most ten minutes from when it began waiting (not from its arrival: a backlog
    replayed at once must not turn an honest record unprovable; a daemon in loop mode asks
    again within 5 s while one waits; a one-shot run never expires one), then unprovable;
    else refuted. A win claimed with no seed was never shown: it covers nothing. Pending
    counted at the record's time would let a made-up win open a window for another
    battle's record.
  - *The boot pass*, before the reactor starts, at every enforcing boot - a dry run when
    `on` is held back by a blocker: owned := the grant rows, plus, at the first cutover
    only (`badge_cutover`), the legacy bits (the baseline - a bit a stale frame took since
    comes back - or the whole mask of an account never judged; not for an account born
    after the cutover), plus proof grants for proven claims never granted; pending bits
    stripped from the ledger (shown still shows them); refused bits removed (flagged at
    the cutover only - a period off later trusted the clients); unprovable ones removed
    without a flag and listed for the operator. Written under the row's lock, keeping a
    grant made since the plan. At the cutover it looks at every account holding, granted
    or with a baseline of a badge (a stale frame may have zeroed a ledger); after it,
    only at accounts whose ledger is not their grants, or with a win proven since its last
    whole pass; an account it fails on keeps what it holds and the pass is done again at
    the next boot. An operator's revocation is kept as a revoked grant: no legacy bit,
    no win proven before it grants the badge again - one proven after does, as does a win
    waiting for its replay as it came; a frame showing the badge is REVOKED (no sign). A
    revocation reaches a player at their next login (revoke while they are away: until
    then their records counting the badge are refused), and the console's clock is the
    server's (run it where the server runs: proofs and revocations compare times).
  - *Client* (`badge_hold`): the badge frame waits (60 s at most, by the clock) while a
    prize claim or a kept record is unanswered, and goes out again after each claim's and
    record's first answer; `login_ok` / `auth_ok` name the placements whose win gives a
    badge (from shadow on, section 4), and their seed is waited for 30 s while online (a
    dropped link ends the wait: no reconnect happens in a battle - such a win is
    unprovable, the operator's to grant). Those battles are fought with no partner
    (`badge_alone`, section 4). Login always carries `:badges` (0 without a row).
  - *Operator*: `bin/pemk_badges.rb list | grant | revoke | unowned` (the wins a player
    may have earned that own nothing: claimed with no seed, not replayable, refuted).
  - Autotest 089, on the demo's own export (2026-10-01 Sam's maps were edited: the house
    help NPC gives no badges and no debug mode, Brock's battle has a noPartner rule; the
    maps are not in the repository, so `server/data/world.json` describes the edited demo
    until a stock clone's first debug launch exports its own - safe: the server only
    refuses more. 089 sets `PEMK_BADGE_IGNORE=3:7` for a stock demo's house, whose
    clients fight Brock alone): an honest badge shown at once, owned after the replay,
    kept across a relaunch; a rogue's frame never raises; a client that cannot hold its
    badge frame gets update_required. The unit tests cover the rest: a refuted or
    unreplayable win, the cutover's cases (`server_badge_enforce_test`), operator grants
    and revocations (`ledger_test`, `badges_cli_test`), a badge frame held for its claim
    (`badge_hold_plugin_test`).
  - Autotest 090: a copy of the demo's export says Camper Liam's win gives a badge (he has
    two Pokemon: a partner would join him), and May is the player's partner - Liam is
    fought alone, seeded, replayed, and his badge granted; a B2 client without
    `badge_alone` gets update_required. Its counter-check (the seed ask from before)
    turns the battle into a double with May.
