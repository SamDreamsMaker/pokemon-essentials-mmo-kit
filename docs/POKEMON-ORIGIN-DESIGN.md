# Pokemon origin: every new Pokemon has a source the server knows

Status: proposal, 2026-10-06, revised after an adversarial plan review the same day (20
findings: the first draft trusted client tags, judged position too late, let repeatable
gifts and the three starters be claimed at will, and had no answer for eggs). Waiting for
the project owner's go and their call on section 6. Built in shippable steps, detection
first, each off by default unless it only adds data.

## 1. Where we start

Every Pokemon the player owns gets a server-issued identity (M3.1): a sweep over the party,
the boxes, the Day Care and fused partners asks a uid for each instance without one
(`uid_req {tmp, species, level, pid, egg}`), idempotent by a persisted nonce (issuer +
nonce). Trades move an identity between accounts by compare-and-swap; nothing mints there.

What the server knows about where an identity came from (`monsters.origin`): `wild_caught`
and `wild` (a D2 mint, caught or not, with `PEMK_BATTLE_ENFORCE_ENCOUNTERS=on`), `client`
(no roll matched), NULL (encounters off). D5's `fabricated_wild` reports an issuer with at
least five `client` Pokemon of wild-table species, more than its `wild_caught` ones.

Everything else - a gift, an egg, an event's battle, an in-game trade, a fossil, a Game
Corner prize - is `client`, exactly like a Pokemon a modified client made up. That one
gets a valid uid; the trade CAS moves it to other players, and it passes trainer proofs
and relayed PvP like any other. **A fabricated shiny legendary spreads with a clean
identity** - the security matrix's last ❌ row.

## 2. The sources and how each can be explained (engine v21.1)

| Source | Engine seam | Explained by |
|---|---|---|
| Wild, table roll (steps, rods, Headbutt, Rock Smash, Sweet Scent, Safari, Bug Contest steps) | `choose_wild_pokemon` -> `generate_foes` | **D2 mint** (exists) |
| Wild, the game's fallback (D2 denied / timed out / offline, scaling-level maps, D2 off) | same | a **`[:wild, map, enctype]` claim** judged by the tables (`EncounterMint#legal?`): weak label `wild_local` |
| Event battle (Kecleon, Mew) | `WildBattle.start(:SP, lvl)` or a pre-built `Pokemon` | **server mint at the seam** (below): the export's species/level for that event |
| Gift, literal (`pbAddPokemon`, `pbAddPokemonSilent`, `pbAddForeignPokemon`, `pbAddToParty`, `pbAddToPartySilent`, `pbGenerateEgg`) | the event's script | **server mint at the seam**; the export carries literal edits (shiny, nature, IVs, ability) |
| Gift, chosen (the three starters: three events) | same | server mint; the export groups events a later page of each waits on (**exclusive group**: once per account per group) |
| Fossil revival, Game Corner prize (`pbSet(n, :SP)` then `pbAdd...(pbGet(n))`, repeatable) | same | server mint against a **cost**: the fossil's item decrease or the coins spent (item and money ledgers), the species set from the event's literals; a daily bound for any other repeatable |
| In-game trade (`pbStartTrade`) | `005_UI_Trading.rb` | server mint at the seam; the request names the uid given away, retired in the mint's transaction; the exported species or an evolution of it (the trade evolves it) |
| Roamer | `Settings::ROAMING_SPECIES` | export the roster; a `[:roamer, species]` claim, once per account per species |
| Poke Radar chain | radar handler | a `[:radar, map]` claim: a species of that map's tables, POKERADAR in the server's bag record, a rate bound; weak label `wild_radar`, counted by D5 |
| Day Care egg (`DayCare.collect_egg`) | client | a `[:egg, uid_a, uid_b]` claim: both parents the account's, in its Day Care (the possession projection, O1), compatible by the exported egg groups, the egg of the right family; a persisted step budget (eggs come every 256 steps) |
| Shedinja | `pbDuplicatePokemon` | a `[:shed]` claim: an owned Nincada row with the same personal id, once per row |
| Egg hatch, evolution, unfuse | same object / `@fused` | no new identity |
| Mystery Gift (client download) | `024_UI_MysteryGift.rb` | not explainable until gifts are server-owned: unjudged |
| Bug Contest's prize, plugins, computed species | various | **unjudged** (never accused): an operator list `PEMK_MON_LOCAL`, and an API for plugins (as `PEMK::Encounter.table_roll`) |
| Debug | menus | never explained (the debug lock denies it) |

## 3. The model: the server mints what it gives

**At the seam, the server decides** - as D2 does for wild Pokemon and the gift gate for
items. The client's alias of each gift function (and of `WildBattle.start` for an event's
species, and of `pbStartTrade`) sends a synchronous request first (the position frame
first, a bounded wait, the gift gate's pattern), naming the running event (only from the
interpreter that is running it; a common event by its own id). The server judges: the
export lists that species for that event; the player stands where the server last saw
him on that map; once per account, per group, or against a cost. It answers with the
identity - personal id, IVs, shininess, with the export's literal edits applied - and
records the grant (a void-once lifecycle, as gift grants: a crash before the save
replays the same grant, never a repeat). The client builds the Pokemon from it; the
uid sweep then claims that grant by species and personal id, as a mint claims its roll.
Denied, timed out or offline: the game's own Pokemon, unexplained (fail-open, never a
lost gift).

**Where the server cannot be asked first** (eggs, Shedinja, radar, roamers, a wild
fallback), the uid request carries a claim (an optional field: older clients send none,
older servers ignore it), judged when the identity is minted - only a fresh insert, never
a nonce's replay.

Labels: `gift`, `static`, `trade_npc`, `fossil`, `prize`, `egg`, `shed`, `roamer`;
weak ones `wild_local`, `wild_radar`; **`unexplained`** when a judged rule says no; NULL
when no rule applies (unjudged). `client` stays for identities minted before this.

## 4. Steps

- **O0 - the export** (additive, no behavior change): per event, the Pokemon it can give,
  start a battle with or trade (species, level, literal edits), its exclusive group, its
  cost, one-shot or repeatable, and a marker where the species is computed; the roamer
  roster; egg groups in the battle data. The server loads them and counts them at boot.
- **O1 - the possession** (as item authority's E0): the client projects every uid it
  holds - party, boxes, Day Care, fused partners - hash-gated; the server knows what an
  account holds and where. Eggs and in-game trades need it.
- **O2 - server-minted gifts** (`PEMK_MON_GIFTS` off/shadow/on): the seam requests; shadow
  grants everything and logs what it would refuse.
- **O3 - claims and labels** (`PEMK_MON_ORIGIN` off/shadow/on): the weak claims, the labels,
  `unexplained` to the review queue (D5 counts it instead of guessing from wild tables).
  `on` needs D2 on and the O0 export, otherwise it runs as shadow.
- **O4 - enforcement** (section 6).

Each step: plan review, tests driving the engine's own code where the seam is engine
logic, mutants with a control, suite, autotest, diff review. Scenarios: the gifts of
Map026 (Farfetch'd, Pichu with its edits, a Togepi egg), the Kecleon, the Rattata trade, a
fossil, a gift into a full party, a hard kill then replay; a rogue claiming the three
starters, a second Celebi, a gift from a far map, no cap; a catch after a D2 timeout; the
CAS refusing a rogue's Mew. `add_pokemon` in scenarios gets an explained setup (as
`credit_setup` for items).

## 5. Limits to say out loud

- A gift's stats are the server's only when the gift is minted at the seam (O2); a weak
  claim proves the source, not the stats (the first-sight lock then holds them).
- Eggs are judged by family and egg group, not by every breeding rule.
- An external game whose plugins give Pokemon in their own way stays unjudged until it
  lists them: never an accusation, so `on` is safe only once shadow shows no honest line.

## 6. The owner's decision: what `on` does to an unexplained Pokemon

1. **Trade-locked** (recommended, and the review agrees): it stays with its maker, usable
   in single player, trainer battles and PvP, but the trade CAS refuses it (a lock set in
   the mint's own transaction, so no tradeable window; its own abort reason shown to the
   player; unlocked when a later rule or an operator explains it). It cannot spread;
   nothing is destroyed.
2. Also kept out of PvP: not enforceable today (relayed PvP never sends the server the
   teams' uids).
3. Refused at mint: the worst - a Pokemon with no uid fails trainer proofs, and no
   evidence row is kept.
