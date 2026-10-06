# Server settings

Every setting the server and its tools read from the environment, with its default. The
server runs with none of them set: it listens on localhost, stores saves, keeps the ledger,
the bag and the Pokemon registry, and checks nothing else. Each check below is opt-in.

A setting that goes `off / shadow / on` ramps the same way everywhere: `off` does nothing,
`shadow` judges and logs what `on` would do (`WOULD-DENY`, `WOULD-CORRECT`, `WOULD-REFUSE`
lines) and changes nothing, `on` acts. An unknown value is read as `off`: the server never
boots stricter than asked. Some `on` settings need others on first; the boot log says what
is missing, and the setting runs as `shadow` until then.

The caps (money, coins, Battle Points, soot, badges, bag and party sizes) are not
environment settings: they live in `server/config/economy_caps.yml`, and a missing cap is
a boot error. The dev launcher `server/bin/dev-server.sh` sets `PEMK_POS_ENFORCE=shadow`
and `PEMK_CLIENT_DEBUG=allow`; `docker compose` sets `PEMK_BIND=0.0.0.0`.

`server/test/settings_doc_test.rb` keeps this page complete: a setting the code reads with
no row here fails the suite, and so does a row no code reads.

## Where it listens, what it loads

| Setting | Default | Values | What it does |
|---|---|---|---|
| `DATABASE_URL` | (required) | a Postgres URL | the database; `~/pemk-env.sh` sets it in dev, `.env` in Docker |
| `PEMK_BIND` | `127.0.0.1` | an address | the address the server listens on; `0.0.0.0` for other machines |
| `PEMK_PORT` | `9998` | a port | the TCP port; `mmo_config.txt` on the clients names the same |
| `PEMK_WORLD` | `server/data/world.json` | a path | the world export (maps, warps, passability, water, events, trainers, badges, field keys) a debug launch of the game writes; absent, the world checks do nothing; present but invalid, a boot error |
| `PEMK_BATTLE_DATA` | `server/data/battle_data.json` | a path | the battle data export (species, moves, items, types, natures, caps) the same launch writes; same policy |

## The clients

| Setting | Default | Values | What it does |
|---|---|---|---|
| `PEMK_CLIENT_DEBUG` | `deny` | `deny` / `autopilot` / `allow` | the game's debug mode (walking through walls, deciding a battle, field moves with no badge, the debug menus) on the clients. `deny`: off while they play here, their autopilot only reads. `autopilot`: off, the autopilot is obeyed - the autotest's level, never a public server. `allow`: as each client has it - a dev server |
| `PEMK_FLOOD_GUARD` | `on` | `on` / `off` | a connection that floods the server before its login is closed - more than a client sends: 3 `:auth` (then 1 per 10 s), 5 `:login` (1 per 5 s), 3 `:register` (1 per 10 s), 10 `:ping` (2/s), or a frame over 4 KiB; so is one that keeps sending far over its frame budgets after (1000 frames dropped in a burst, refilled 20/s; a busy client's automatic trade declines aside); past 32 password checks waiting, a login or a register is answered "busy". `off`: before login nothing is budgeted or capped, nothing is closed, as before. Always, whatever the setting: password checks run beside the players' work, a socket is read 64 KiB a turn, a type the server does not know shares one budget, and a drop is logged once per type per 10 s |
| `PEMK_RELAY_GUARD` | `on` | `on` / `off` | what players send each other: a battle or a trade session is per pair of players and kind, opened only by an answer to an invite, ended only by its own pair's decline, cancel or end - so an invite to a player in a battle, or a stranger's frame, never breaks it; an invite carries no body and at most 2 KiB, 5 per account then 1 per 5 s, and none reaches a player whose output is 512 KiB behind; a partner's bodies are a team (64 KiB) and an escrow (32 KiB), 4 then 1 per 10 s; a player gone mid-battle ends it (a draw) for the other, mid-trade cancels it. `off`: the relay as before |
| `PEMK_PRESENCE_DEDUP` | `on` | `on` / `off` | an idle player's heartbeat is not sent again to clients that keep their peers until a leave; a player entering a map is sent everyone already there; a member silent for 15 s leaves its map. `off`: every frame to everyone, as before |
| `PEMK_PEER_CHECK` | `off` | `off` / `shadow` / `on` | a Pokemon one client sends another (a trade's escrow, a PvP team) is checked against an allow list of classes before anyone loads it; `on` drops the others |
| `PEMK_PEER_CLASSES` | (none) | class names, comma-separated | your own classes stored inside a Pokemon, added to the allow list (the party's: Pokemon, Pokemon::Move, Pokemon::Owner, Mail) |
| `PEMK_TRADE_REDELIVERY` | `on` | `on` / `off` | a traded Pokemon the receiver never saved (a crash, a lost result) is sent again at its next login |

## The world: position, items, gifts, shops

| Setting | Default | Values | What it does |
|---|---|---|---|
| `PEMK_POS_ENFORCE` | `off` | `off` / `shadow` / `on` | where a player may stand, judged on the presence frames the server already receives: a wall stepped onto, a warp that exists nowhere, water crossed on foot, and a surfer or a diver without the badge the game requires (a player is sent back to the shore - never where your own scripts start swims). `off` still logs each verdict; `on` sends the player back to its last good tile. The pace of a player's steps is logged in every mode, never corrected |
| `PEMK_MODE_MOVES` | `on` | `on` / `off` | the move half of the swim keys: a surfer needs a party Pokemon knowing Surf (or Dive), a diver one knowing Dive, judged from the party the client reports. `off`: the badge alone, for a game whose swims need no Pokemon |
| `PEMK_PICKUP_ENFORCE` | `off` | `off` / `on` | an item ball is granted by the server (it exists, the player stands by it, once per account) before the client adds it |
| `PEMK_ALLOW_PICKUP_RESET` | `off` | `off` / `on` | **dev and QA only**: a client may forget its own taken item balls to test them again. On a public server any client could farm every item ball forever |
| `PEMK_GIFT_ENFORCE` | `off` | `off` / `shadow` / `on` | an event asks the server before it gives an item; a one-shot gift the world export knows (a gym leader's TM) is paid once per account, on its event's own map |
| `PEMK_SHOP_ENFORCE` | `off` | `off` / `shadow` / `on` | Mart purchases and sales, and Battle Point exchanges, are made by the server: it checks the clerk's stock and the price, and moves the money or the BP itself |
| `PEMK_ITEM_RECORD` | `full` | `full` / `bag` | what comes back at login from the server's record rather than the save: the bag, the PC storage, the mailbox and the held items (`full` - a dupe fix, for clients that send those stores), or the bag alone |
| `PEMK_ITEM_AUTHORITY` | `off` | `off` / `shadow` / `on` | every item the player gains must come from a source the server knows: a granted pickup, a paid gift, a purchase, a trade. `shadow` logs the others `UNEXPLAINED`; `on` takes them back. `on` needs `PEMK_PICKUP_ENFORCE=on`, `PEMK_GIFT_ENFORCE=on`, `PEMK_SHOP_ENFORCE=on`, `PEMK_TRADE_REDELIVERY=on`, `PEMK_ITEM_RECORD=full` and complete exports, else it runs as `shadow` |
| `PEMK_ITEM_LOCAL` | (none) | item ids, comma-separated | items your own code produces in ways the exports cannot see (a plugin, a computed prize): recorded, never judged |
| `PEMK_ITEM_GRACE_SEC` | `120` | `10` to `3600` | how long an unexplained increase waits for its source before its verdict |

## Money and badges

| Setting | Default | Values | What it does |
|---|---|---|---|
| `PEMK_MONEY_AUTHORITY` | `off` | `off` / `shadow` / `on` | the prize a trainer battle pays is claimed and judged: the trainer placed where the player is, each battle paid once, the amount within its bound. `on` moves the money itself and refuses what it cannot explain; it needs `PEMK_BATTLE_ENFORCE_ENCOUNTERS=on`, `PEMK_SHOP_ENFORCE=on`, item authority enforcing, the daily allowances below and complete exports, else it runs as `shadow` |
| `PEMK_MONEY_PAYDAY_DAILY` | `20000` | a number / `none` | the Pay Day an account may be credited per day: a wild battle's coins have no proof, so they are only bounded |
| `PEMK_MONEY_LOCAL_DAILY` | `10000` | a number / `none` | what an account may sell per day of the items the server never judged (`PEMK_ITEM_LOCAL`, Pickup, mining...) |
| `PEMK_MONEY_REPEAT_DAILY` | `20000` | a number / `none` | the prizes an account may be credited per day for the battles the game lets be fought again |
| `PEMK_TRAINER_PROOF` | `off` | `off` / `shadow` / `on` | a trainer prize is paid on its battle's replay (`bin/pemk_replay.rb`): the claim waits for the verdict and is paid on a proven win. `on` needs money authority enforcing and `PEMK_BATTLE_ENFORCE_RNG=on`, else it runs as `shadow` |
| `PEMK_MONEY_UNPROVEN_DAILY` | `5000` | a number (`0`: never) | under trainer proof, what an account may be paid per day for the prizes no replay can prove for a cause on the server's side (no seed handed out, a battle the export cannot rebuild) |
| `PEMK_BADGE_AUTHORITY` | `off` | `off` / `shadow` / `on` | a badge is the server's when its battle's win is proven; the clients fight the battles that give one alone. `on` needs trainer proof and money authority enforcing, else it runs as `shadow` |
| `PEMK_BADGE_IGNORE` | (none) | `map:event`, `ce:N`, `file:line`, comma-separated | badge writes that are not the game's (a debug helper the export cannot tell apart): refused, like any no win explains |

## Story state

| Setting | Default | Values | What it does |
|---|---|---|---|
| `PEMK_FLAG_STATE` | `off` | `off` / `shadow` / `on` | the server keeps the story progression it has seen saved (switches, variables worked out from your events) and, `on`, hands it back at login - a lost save no longer re-arms gym leaders and one-shot events |
| `PEMK_FLAG_ENFORCE` | `off` | `off` / `shadow` / `on` | the server also holds the tracked values during play: a value changed without the game's own events is put back. Needs `PEMK_FLAG_STATE` on or shadow, else it stays `off` |

## Battles

| Setting | Default | Values | What it does |
|---|---|---|---|
| `PEMK_BATTLE_ENFORCE_TEAMS` | `off` | `off` / `shadow` / `on` | a team's legality: species line, sets, the first-sight lock on IVs, shiny and gender. Detection only today, every mode logs |
| `PEMK_BATTLE_ENFORCE_ENCOUNTERS` | `off` | `off` / `shadow` / `on` | wild encounters: the encounter table's own rolls (a step, a rod, Headbutt, Rock Smash, Sweet Scent), from the tables of the game's encounter version. `shadow` audits the client's against the tables. `on` has the server mint them: species, level, shiny, IVs. An event's battle, a roaming Pokemon and the Poke Radar's chains stay the game's: never minted, so their catches stay the client's (client origin), their EXP opens no reward window (a level-up from them reads as a SUSPECT jump under rewards) and their Pay Day is unproven (refused under money authority `on`) |
| `PEMK_BATTLE_ENFORCE_CATCHES` | `off` | `off` / `shadow` / `on` | the shakes of a Poke Ball. `on` has the server roll them. Needs encounters `on`: a catch with no mint stays the client's |
| `PEMK_BATTLE_ENFORCE_REWARDS` | `off` | `off` / `shadow` / `on` | the EXP and money a wild battle may pay. Detection only: an impossible jump is logged. Needs encounters on for the foe: a battle the game keeps (an event's, a roamer's, a Poke Radar chain's) has none, so its level-ups are logged |
| `PEMK_BATTLE_ENFORCE_EXP` | `off` | `off` / `shadow` / `on` | each owned Pokemon's EXP high-water. `shadow` flags a rollback: an old save, an edit. `on` raises the party back to it, never lowers |
| `PEMK_BATTLE_ENFORCE_RNG` | `off` | `off` / `shadow` / `on` | the battle seam. `shadow` records wild battles under the game's own RNG, the replay corpus. `on` draws them from server-seeded streams. Needs encounters `on`. Instrumentation, not rejection |
| `PEMK_BATTLE_ENFORCE_RESIM` | `off` | `off` / `shadow` / `on` | the replay's verdict acts. `shadow` audits what it would quarantine. `on` quarantines a refuted catch after `PEMK_RESIM_MIN_STRIKES`: un-tradeable, never destroyed. Needs rng `on` and the replay worker |
| `PEMK_RESIM_MIN_STRIKES` | `2` | `1` or more | distinct refuted battles before an account's quarantine arms |
| `PEMK_CORPUS_RETENTION_DAYS` | `30` | days (`0`: forever) | how long matched battle records are kept. Evidence is never pruned |
| `PEMK_ANOMALY_DETECTION` | `off` | `off` / `on` | per-account suspect counters across battles, into a review queue: `bin/pemk_quarantine.rb reports`. Never acts. Inert unless the layers above feed it |

## The tools

| Setting | Default | Values | What it does |
|---|---|---|---|
| `PEMK_OPERATOR` | the shell user | a name | who acts in the record: `bin/pemk_admin.rb` (bans, forgetting an account), `bin/pemk_badges.rb` |
| `PEMK_REPLAY_LOOP` | (unset: one pass) | seconds | `bin/pemk_replay.rb` as a daemon: the engine boots once and the queue is polled on this interval. What a real deployment runs |
| `PEMK_GAME_ROOT` | the server directory's parent | a path | `bin/pemk_replay.rb`: the game whose engine replays the battles |
| `PEMK_REPLAY_MARK` | `$TMPDIR/pemk_replay.current` | a path | `bin/pemk_replay.rb`: the record being replayed, on disk. One that kills the tool is marked an error at the next boot, never replayed first again |
| `REPLAY_LIMIT` | `100` (`500` as a daemon) | a number | `bin/pemk_replay.rb`: records per pass |
| `REPLAY_ID` | (unset) | a record id | `bin/pemk_replay.rb`: replay exactly one record |
| `REPLAY_FORCE` | (unset) | `on` | `bin/pemk_replay.rb`, with `REPLAY_ID`: replay it even where its status is triage evidence (after a triage decision) |
| `REPLAY_DRY` | (unset) | `on` | `bin/pemk_replay.rb`: print the verdicts, update nothing |
| `REPLAY_FAULT_ID` | (unset) | a record id | **tests only**: `bin/pemk_replay.rb` fails on this record |
| `REPLAY_FAULT` | (unset) | `db` / `die` / anything else | **tests only**: how it fails. `db`: the database away. `die`: the tool dies. Else a Ruby error |

The clients have settings of their own (`mmo_config.txt`, and `PEMK_AUTOPILOT` /
`PEMK_INSTANCE` for the autotest): see [`Plugins/PEMK/README.md`](../Plugins/PEMK/README.md)
and [`AUTOTEST.md`](AUTOTEST.md).

## Reading on

- The ramp an operator follows, setting by setting: [`GETTING-STARTED.md`](GETTING-STARTED.md).
- What each check secures and its honest limits: [`ARCHITECTURE-SECURITY.md`](ARCHITECTURE-SECURITY.md).
- Items: [`ITEM-AUTHORITY-DESIGN.md`](ITEM-AUTHORITY-DESIGN.md). Money: [`MONEY-AUTHORITY-DESIGN.md`](MONEY-AUTHORITY-DESIGN.md) and [`TRAINER-PROOF-DESIGN.md`](TRAINER-PROOF-DESIGN.md). Badges: [`BADGE-AUTHORITY-DESIGN.md`](BADGE-AUTHORITY-DESIGN.md). Battles: [`LAYER-D-BATTLE-DESIGN.md`](LAYER-D-BATTLE-DESIGN.md).
- Running the server, banning and forgetting an account: [`../server/README.md`](../server/README.md).
