# Automated in-game testing

The kit can play the real game on its own and report what happened. Two pieces:

- **The autopilot** (`Plugins/PEMK/011_Autopilot/`) lets a script drive a game window
  and read its state: keys, menus, messages, battles, walking, text entry.
- **Autotest** (`server/autotest/`) runs scenarios with it: each one gets its own
  isolated server and fresh accounts, plays, checks the game and the database, and
  writes a report.

Nothing here is active in a normal game. The autopilot only switches on for a debug
launch (`Game.exe debug`) that also has `PEMK_AUTOPILOT` set.

## Running the scenarios

From the server's WSL setup (see [INSTALL-WINDOWS.md](INSTALL-WINDOWS.md)):

```bash
cd "/mnt/c/<your game folder>/server"
bin/autotest.sh            # every scenario in server/autotest/scenarios
bin/autotest.sh fossil     # only the ones whose name or file matches
```

Each scenario:

1. starts its own PEMK server in the test process, on port 9997 (`AUTOTEST_PORT`)
   and the `pemk_autotest` database. Your dev server and dev database are never
   touched;
2. opens game windows **minimized**, so you can keep working while they play, on
   fresh accounts that the login creates from generated credentials;
3. plays, checks, and closes everything, even on failure.

Every wait is bounded and every scenario has a time budget (240 s by default). The
results land in `autotest-reports/<run>/report.md`. A failed scenario comes with each
window's state, a screenshot, its log, and the server's log.

The first run of a session recompiles the plugins if their sources changed.

## Writing a scenario

A scenario is a Ruby file in `server/autotest/scenarios/`:

```ruby
# From scenarios/011_fossil_latch.rb
Autotest.scenario "the fossil NPCs' latch is never banked", flags: { PEMK_FLAG_STATE: "on" } do |s|
  a = s.player(:a)                   # a window on a fresh account
  a.new_game("Fossil")               # plays the intro to the player's house
  id = s.account_id(a)
  a.add_item!("HELIXFOSSIL")
  a.warp!(11, 7, 9)                  # map 11 (the Pokémon Institute), tile 7,9
  a.wait_until!("idle within 10", timeout: 20)
  a.talk_to!(2)                      # walks up to event 2 and talks
  a.converse("Yes", "HELIXFOSSIL")   # answers the question, picks the fossil
  s.check("the reviver keeps the fossil") { a.get_selfswitch!(11, 2, "A")["value"] }
  # ...
  s.check("the latch never reaches the ledger") do
    s.db[:progression_facts].where(account_id: id, fact_key: "ss:11:2:A").count.zero?
  end
end
```

- `flags:` sets the server's `PEMK_*` environment for this scenario.
- `s.player(:a)` launches a window; `s.player(:b)` a second one on its own account.
- Every autopilot verb is a method: `a.walk_to(3, 4)`, or with `!` to fail the scenario
  when the game refuses (`a.walk_to!(3, 4)`).
- `a.converse(*answers)` reads a conversation, answering each menu, item choice or text
  prompt in turn.
- `a.hard_kill` closes a window like a crash; `a.relaunch` starts it again on the same
  account.
- Two players: `s.together(-> { a.new_game("Alice") }, -> { b.new_game("Bob") })` runs
  both at once; `a.pause_menu("Trade Player")` opens the pause menu and picks an entry;
  `b.answer_when_asked("Yes", "Yes", "Eevee")` waits for the other player's question,
  then answers it; `a.remote_names` lists the players a window draws.
- `s.rogue(:r)` is a client on its own account that sends raw frames
  (`rogue.send_env({ type: :trade_invite, ... })`), like a modified game would:
  `scenarios/030_rogue_names.rb` uses one against a real window.
- `s.check(name) { ... }` records a check; `s.wait_for(what) { ... }` polls until a
  server write lands; `s.db` is the test database.

## Driving a window by hand

```powershell
$env:PEMK_INSTANCE  = "ap1"           # its own config, account, log and save file
$env:PEMK_AUTOPILOT = "autopilot\ap1" # the command channel directory
Start-Process Game.exe -ArgumentList debug -WindowStyle Minimized
```

Then, from Git Bash or WSL: `tools/autopilot/ap.sh autopilot/ap1 <verb> [args]`.

| Verbs | What they do |
|---|---|
| `state`, `screenshot`, `events`, `event_pages ID` | read the game: scene, open screens, message, menus, party, battle, and the log; the map's events and their scripts |
| `press`, `hold`, `release`, `wait`, `wait_until` | keys, time, and waiting for a condition (`idle`, `message`, `menu`, `battle`, `decision`, `map 7`...) |
| `dismiss`, `choose`, `type`, `pick` | read messages, pick a menu entry, answer a text prompt or an item choice |
| `walk_to`, `face`, `interact`, `talk_to`, `enter`, `warp` | move on the map, talk to an NPC, go through a door |
| `battle mode keys\|agent\|auto`, `decide` | play a battle: by keys, one decision at a time, or with a plain built-in policy |
| `set_switch`, `get_switch`, `add_item`, `add_pokemon`, `heal`, `money`, `bp`, `save`... | set a scene up quickly and read it back (with `PEMK_ITEM_AUTHORITY` on, a scenario's `add_item!` credits the account first, so a setup item is not reported `UNEXPLAINED`; `s.unexplained_items(a)` lists what the ledger still owes) |
| `set_raw_var`, `set_raw_switch`, `hold_saves on\|off` | change a value the way a memory edit does; keep the save from reaching the server, to kill the game before it lands |
| `pc_deposit`, `pc_withdraw`, `get_pc`, `give_held`, `take_held`, `get_held` | move items between the bag, the PC and a party Pokemon the way the engine does, and read them back |
| `partner TYPE NAME VERSION`, `partner none` | put a trainer at the player's side the way an event does (`pbRegisterPartner`), or take them away |
| `set_debug on\|off` | set `$DEBUG` the way an event's script does (the stock demo's house helper): a server that keeps debug mode off undoes it at once |
| `fast`, `advance`, `abort` | skip animations and key-wait windows, cancel a running command |

`verbs` lists them all.

## Safety

- The autopilot is off unless the launch is `debug` **and** `PEMK_AUTOPILOT` is set: a
  player build is never remote-controlled. Any player can make such a launch, though, so
  the server decides what it may do once logged in (`PEMK_CLIENT_DEBUG`): `deny` (the
  default) keeps debug mode off and lets the autopilot only read (state, screenshot,
  events, waits - no key, no setter); `autopilot` keeps debug mode off and obeys it (the
  harness's level: never a public server); `allow` changes nothing (a dev server,
  `server/bin/dev-server.sh`). A scenario that needs debug mode itself sets
  `PEMK_CLIENT_DEBUG: "allow"` in its flags (080 surfs with no badge).
- Its channel is two files in a local folder; it opens no port.
- Its setters go through the game's normal code, so an online server sees them as the
  client claims they are, like any other change.
