# frozen_string_literal: true

require "open3"

# Trainer proof (docs/TRAINER-PROOF-DESIGN.md): a Pokemon from another trainer obeys
# only as far as the badges allow, and the game rolls for it every turn. With a traded
# level-14 Squirtle and no badge, the win over Camper Liam is full of disobedience - its
# replay rolls the same (the record says the Pokemon is foreign and how many badges) and
# the prize is proven.
Autotest.scenario "a traded Pokemon's disobedience is replayed as the game rolled it",
                  flags: { PEMK_BATTLE_ENFORCE_RNG: "on", PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on",
                           PEMK_MONEY_AUTHORITY: "shadow", PEMK_BATTLE_ENFORCE_TEAMS: "on",
                           PEMK_BATTLE_ENFORCE_EXP: "on", PEMK_TRAINER_PROOF: "shadow" },
                  budget: 480 do |s|
  a = s.player(:a)
  a.new_game("Trader")
  id = s.account_id(a)
  a.fast!
  a.add_pokemon!("SQUIRTLE", 14, "foreign")   # obeys up to level 10 with no badge: often not
  a.warp!(10, 6, 14)                       # the Cedolan Gym's entrance
  a.wait_until!("idle within 10", timeout: 20)
  a.talk_to(4, timeout: 60)                # Camper Liam
  a.converse
  s.check("Liam's battle started") { a.in_battle?(10) }
  a.fight_battle(prefer: "WATERGUN", seconds: 300)
  a.converse

  claim = s.wait_for("the prize claim names its battle", seconds: 30) do
    s.db[:money_claims].where(account_id: id, kind: "trainer").exclude(trainer_battle_id: nil).first
  end
  record = s.db[:battle_records].where(trainer_battle_id: claim[:trainer_battle_id], outcome: 1).first
  body = PEMK::Wire.decode_primitive(record[:record].to_s)
  s.check("the record says the Squirtle is another trainer's, and no badge") do
    body[:init][:player][0][:foreign] == true && body[:init][:badges].zero?
  end
  out, = Open3.capture2e({ "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "REPLAY_ID" => record[:id].to_s },
                         "bundle", "exec", "ruby", "bin/pemk_replay.rb", chdir: Autotest::SERVER_DIR)
  File.write(File.join(s.dir, "replay.txt"), out.lines.grep(/^  #/).join)
  s.check("the replay rolls its disobedience as the game did") do
    s.db[:battle_records].where(id: record[:id]).get(:replay_status) == "match"
  end
  proof = s.wait_for("the claim's verdict", seconds: 20) do
    s.db[:money_claims].where(account_id: id, nonce: claim[:nonce]).get(:proof)
  end
  s.check("the prize is proven") { proof == "proven" }
end
