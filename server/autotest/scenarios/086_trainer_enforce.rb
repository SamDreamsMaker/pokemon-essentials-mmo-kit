# frozen_string_literal: true

require "open3"

# Trainer proof P4 (docs/TRAINER-PROOF-DESIGN.md): under money enforcement, a trainer's
# prize is held until its battle's replay proves it. An honest win over Camper Liam is
# held - neither the ledger nor the game has the prize yet - then replayed, proven and
# paid in full at the game's next ask: both have it. A modified client that claims
# Liam's prize with no battle behind it gets the day's small allowance at most; one that
# makes Brock's battle up on his seed is held, then refused once its record is judged.
Autotest.scenario "a trainer's prize is paid once its battle is proven",
                  flags: { PEMK_MONEY_AUTHORITY: "on", PEMK_ITEM_AUTHORITY: "on", PEMK_PICKUP_ENFORCE: "on",
                           PEMK_GIFT_ENFORCE: "on", PEMK_SHOP_ENFORCE: "on", PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on",
                           PEMK_BATTLE_ENFORCE_RNG: "on", PEMK_BATTLE_ENFORCE_TEAMS: "on",
                           PEMK_BATTLE_ENFORCE_EXP: "on", PEMK_TRAINER_PROOF: "on", PEMK_MONEY_UNPROVEN_DAILY: "100" },
                  budget: 480 do |s|
  a = s.player(:a)
  a.new_game("Proven")
  id = s.account_id(a)
  a.fast!
  s.check("the server holds trainer prizes for their proof") do
    s.server.grep(/trainer proof = on \(a trainer prize is held until its battle's replay proves it/).any?
  end
  ledger = -> { s.db[:economy_balances].where(account_id: id, field: "money").get(:balance) }
  money  = -> { a.state.dig("trainer", "money") }
  s.wait_for("the ledger has the start money", seconds: 15) { ledger.call }
  s.check("the game holds the server's money") { s.wait_for("the game", seconds: 15) { money.call == ledger.call } }

  a.add_pokemon!("WARTORTLE", 20)
  a.warp!(10, 6, 14)                       # the Cedolan Gym's entrance
  a.wait_until!("idle within 10", timeout: 20)
  before = ledger.call
  a.talk_to(4, timeout: 60)                # Camper Liam
  a.converse
  s.check("Liam's battle started") { a.in_battle?(10) }
  a.fight_battle
  a.converse

  claim = -> { s.db[:money_claims].where(account_id: id, kind: "trainer").first }
  s.wait_for("the prize claim is held", seconds: 30) { claim.call && claim.call[:verdict] == "held" }
  s.check("nothing is paid while it is held") { ledger.call == before && claim.call[:credited].zero? }
  s.check("the game holds no prize yet either") { s.wait_for("the game", seconds: 20) { money.call == before } }
  record = s.wait_for("its battle's record", seconds: 20) do
    s.db[:battle_records].where(trainer_battle_id: claim.call[:trainer_battle_id], outcome: 1).first
  end
  s.check("the server acknowledged the record") do
    s.wait_for("the acknowledgement", seconds: 10) { a.log_tail(400).any? { |l| l.include?("battlerng: record") && l.include?("acknowledged") } }
  end

  out, = Open3.capture2e({ "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "REPLAY_ID" => record[:id].to_s },
                         "bundle", "exec", "ruby", "bin/pemk_replay.rb", chdir: Autotest::SERVER_DIR)
  File.write(File.join(s.dir, "replay.txt"), out.lines.grep(/^  #/).join)
  s.check("proven, then paid at the game's next ask") do
    s.wait_for("the payment", seconds: 40) do
      c = claim.call
      c[:proof] == "proven" && c[:verdict] == "paid" && c[:credited].positive? && ledger.call == before + c[:credited]
    end
  end
  s.check("the game holds what the server paid") { s.wait_for("the game", seconds: 20) { money.call == ledger.call } }

  # A modified client: Liam's prize claimed with no battle behind it...
  rogue = s.rogue(:r, caps: %w[money_claims trainer_proof save_ack])
  rogue.send_env({ type: :pos, map: 10, x: 6, y: 6, dir: 8, speed: 3 })
  sleep 0.3
  rogue.send_env({ type: :money_claim, nonce: 76, amount: 176, amulet: false, happy_hour: false, map: 10,
                   trainers: [["CAMPER", "Liam", 0, 10, 4]] })
  s.check("a prize with no battle behind it gets the day's allowance at most") do
    ack = rogue.wait_for(:money_claim_ack)[:env]
    ack[:verdict] == "allowance" && ack[:accepted] == 100
  end
  # ... and Brock's battle made up on his seed: the right bounds, values it chose
  brock = ["LEADER_Brock", "Brock", 0, 10, 3]
  rogue.send_env({ type: :trainer_battle_req, nonce: 1, trainers: [brock] })
  seed = rogue.wait_for(:trainer_battle_seed)[:env][:seed]
  log = [100, 0, 16, 0].pack("N*")
  body = PEMK::Wire.encode_primitive({ v: 1, kind: "trainer", truncated: false,
                                       draws: { b: { n: 2, fp: "0" * 16, log: log },
                                                a: { n: 0, fp: "0" * 16, log: "".b },
                                                r: { n: 0, fp: "0" * 16, log: "".b } } })
  rogue.send_env({ type: :battle_record, mode: "on", engine_fp: "ab" * 8, outcome: 1, rounds: 1,
                   draws_battle: 2, draws_ai: 0, draws_run: 0, fp_battle: "0" * 16, fp_ai: "0" * 16,
                   fp_run: "0" * 16, truncated: false, desynced: false, battle_seed: seed, rec_nonce: 5 }, body)
  rogue.wait_for(:battle_record_ack)
  rogue.send_env({ type: :money_claim, nonce: 77, amount: 1400, amulet: false, happy_hour: false, map: 10,
                   trainers: [brock], seed: seed })
  s.check("the made-up battle's prize is held first") { rogue.wait_for(:money_claim_ack)[:env][:verdict] == "held" }
  rogue.wait_for(:money_claim_ready, seconds: 30)
  rogue.send_env({ type: :money_claim, nonce: 77, amount: 1400, amulet: false, happy_hour: false, map: 10,
                   trainers: [brock], seed: seed })
  s.check("then refused: its draws are not its seed's") do
    rogue.wait_for(:money_claim_ack)[:env][:verdict] == "refuted" &&
      s.db[:money_claims].where(account_id: rogue.account_id, nonce: 77).get(:proof) == "refuted"
  end
  s.check("the modified client was paid the allowance, nothing more") do
    s.db[:money_claims].where(account_id: rogue.account_id).sum(:credited).to_i == 100
  end
end
