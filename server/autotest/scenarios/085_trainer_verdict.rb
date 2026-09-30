# frozen_string_literal: true

require "open3"

# Trainer proof P3 (docs/TRAINER-PROOF-DESIGN.md). A prize claim names the seed its battle
# ran on; the battle's record, replayed on the real engine with the trainer's AI re-run
# and the player's team checked against the server's own (owned, locked, no EXP beyond
# what it saw), gives the claim its verdict. An honest win over Camper Liam is proven and
# spends the placement's seed. A modified client that asks Brock's seed, makes up the
# battle and claims his prize is refuted. Shadow: verdicts only, nothing held yet.
Autotest.scenario "a trainer's prize is proven by its battle's replay",
                  flags: { PEMK_BATTLE_ENFORCE_RNG: "on", PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on",
                           PEMK_MONEY_AUTHORITY: "shadow", PEMK_BATTLE_ENFORCE_TEAMS: "on",
                           PEMK_BATTLE_ENFORCE_EXP: "on", PEMK_TRAINER_PROOF: "shadow" },
                  budget: 480 do |s|
  a = s.player(:a)
  a.new_game("Proven")
  id = s.account_id(a)
  a.fast!
  a.add_pokemon!("WARTORTLE", 20)
  a.warp!(10, 6, 14)                       # the Cedolan Gym's entrance
  a.wait_until!("idle within 10", timeout: 20)
  a.talk_to(4, timeout: 60)                # Camper Liam
  a.converse
  s.check("Liam's battle started") { a.in_battle?(10) }
  a.fight_battle
  a.converse

  claim = s.wait_for("the prize claim names its battle", seconds: 30) do
    s.db[:money_claims].where(account_id: id, kind: "trainer").exclude(trainer_battle_id: nil).first
  end
  record = s.db[:battle_records].where(trainer_battle_id: claim[:trainer_battle_id], outcome: 1).first
  out, = Open3.capture2e({ "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "REPLAY_ID" => record[:id].to_s },
                         "bundle", "exec", "ruby", "bin/pemk_replay.rb", chdir: Autotest::SERVER_DIR)
  File.write(File.join(s.dir, "replay.txt"), out.lines.grep(/^  #/).join)
  s.check("the replay agrees, and the team is the server's") do
    s.db[:battle_records].where(id: record[:id]).get(:team_check) == "ok"
  end
  proof = s.wait_for("the claim's verdict", seconds: 20) do
    s.db[:money_claims].where(account_id: id, nonce: claim[:nonce]).get(:proof)
  end
  s.check("the prize is proven") { proof == "proven" }
  s.check("the placement's seed is spent") do
    s.db[:trainer_battles].where(id: claim[:trainer_battle_id]).get(:state) == "proven"
  end

  # A modified client asks Brock's seed, makes the battle up and claims his prize.
  rogue = s.rogue(:r)
  rogue.send_env({ type: :pos, map: 10, x: 6, y: 6, dir: 8, speed: 3 })
  sleep 0.3
  rogue.send_env({ type: :trainer_battle_req, nonce: 1, trainers: [["LEADER_Brock", "Brock", 0, 10, 3]] })
  seed = rogue.wait_for(:trainer_battle_seed)[:env][:seed]
  log = [100, 0, 16, 0].pack("N*")        # the right bounds, values it chose
  body = PEMK::Wire.encode_primitive({ v: 1, kind: "trainer", truncated: false,
                                       draws: { b: { n: 2, fp: "0" * 16, log: log },
                                                a: { n: 0, fp: "0" * 16, log: "".b },
                                                r: { n: 0, fp: "0" * 16, log: "".b } } })
  rogue.send_env({ type: :battle_record, mode: "on", engine_fp: "ab" * 8, outcome: 1, rounds: 1,
                   draws_battle: 2, draws_ai: 0, draws_run: 0, fp_battle: "0" * 16, fp_ai: "0" * 16,
                   fp_run: "0" * 16, truncated: false, desynced: false, battle_seed: seed }, body)
  sleep 0.5
  rogue.send_env({ type: :money_claim, nonce: 77, amount: 1400, amulet: false, happy_hour: false, map: 10,
                   trainers: [["LEADER_Brock", "Brock", 0, 10, 3]], seed: seed })
  rproof = s.wait_for("the made-up battle's verdict", seconds: 30) do
    s.db[:money_claims].where(account_id: rogue.account_id, nonce: 77).get(:proof)
  end
  s.check("the made-up battle's prize is refuted") { rproof == "refuted" }
  s.check("the server says what it would hold, and why") do
    s.server.grep(/trainerproof: account #{rogue.account_id} claim 77 WOULD-HOLD \(refuted\): the record's draws/).any?
  end
end
