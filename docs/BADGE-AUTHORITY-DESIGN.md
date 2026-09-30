# The server owns the badges

Status (2026-09-30): designed and reviewed; B0 (the export) built. Off by default when
built (`PEMK_BADGE_AUTHORITY` off | shadow | on).

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
  account's seeded held claims (verdict held, not voided, a seed row, no refusal) - no
  table, and every refusal and void ends it by itself (they unlink the claim). The honest
  player sees the badge at once; it becomes the ledger's when the replay proves the win.
  Login, the acknowledgements and the proof checks use the same `ledger | pending`.
- **`badge_grants`** (account, badge, evidence `legacy | proof | local | operator`, source,
  claim nonce, granted_at; one row per account and badge) records why each bit is owned.
  `Ledger#grant_bits` sets bits bitwise (a server transaction, like `adjust`).
- **Cutover**: at the first `on` boot, every bit the ledger holds is a `legacy` grant - no
  proof exists for wins before P4, and judging them would take them away. B1 counts the
  accounts whose saves hold bits the ledger lacks, so the operator can grant them first.
- A rematch sets a bit already owned: nothing to judge (the union, and `badge_grants`
  first).

## 4. Blockers (`on` runs as shadow and names each)

Trainer proof not enforcing; an export without `badge_sources`; any unknown source (the
demo's house); any source no battle gives, unless the operator lists it as local
(`PEMK_BADGE_LOCAL=badge@map:event`, named at boot as the client's word); a win source no
replay can prove (several trainers in its call, a partner possible, a battle paying no
money - no claim, so no proof - or one trainer in two calls giving different badges); a
badge index at or over `badges_max`.

## 5. Steps

- **B0 - the export** (built): `badge_sources` - each literal set, at the own level of a
  win branch whose condition is exactly the battle call (then it names that call's
  trainers) or anywhere else (it names none); unknown sets listed. WorldData reads them.
  Still to add: the call index and its no-money mark per win source, `pbPlayer` and plugin
  scripts, `win_bits(map, event, type, name, version)` and `badge_blockers`.
- **B1 - shadow**: for each new bit of a frame, log EXPLAINED / PENDING / WOULD-REFUSE (and
  why), flag `badge_unexplained`; at settle, WOULD-GRANT. Autotest 088: an honest Brock win
  is PENDING, then WOULD-GRANT after the replay; three modified clients (a badge set on
  Brock's map, an allowance claim and a badge, all badges from the house) are WOULD-REFUSE.
- **B2 - enforcement**: the rules above, the client holding its badge frame with its money
  frame and marking it again after each claim answer, an operator grant command. Autotest
  089: an honest badge shown at once, owned after the proof, kept across a relogin; a
  client killed before its checkpoint loses its claim and its badge and fights Brock
  again; a modified client holding a claim then logging in again is never granted.
