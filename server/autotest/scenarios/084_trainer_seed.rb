# frozen_string_literal: true

require "open3"

# Trainer proof P2 (docs/TRAINER-PROOF-DESIGN.md). Under battle rng `on` a trainer battle
# asks its placement's seed as the trainer loads, and runs on it: its record leaves
# before the prize claim, names the seed, is bound to it and passes the seed walk; the
# replay derives every draw from the seed - the trainer's AI's too - and ends the same.
# A second battle at the same placement runs on the same seed: no seed to shop for.
Autotest.scenario "a trainer battle runs on its placement's seed",
                  flags: { PEMK_BATTLE_ENFORCE_RNG: "on", PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on" },
                  budget: 540 do |s|
  a = s.player(:a)
  a.new_game("Seeded")
  id = s.account_id(a)
  a.fast!
  a.add_pokemon!("WARTORTLE", 20)
  records = -> { s.db[:battle_records].where(account_id: id).order(:id).all }
  fight = lambda do |name, event, at|
    a.warp!(*at) unless a.state.dig("map", "id") == 10   # (back after a blackout)
    a.wait_until!("idle within 10", timeout: 20)
    a.heal!
    count = records.call.size
    a.talk_to(event, timeout: 60)
    a.converse
    s.check("#{name}'s battle started") { a.in_battle?(10) }
    a.fight_battle
    a.converse
    s.wait_for("#{name}'s battle is recorded", seconds: 30) { records.call.size > count }
  end

  a.warp!(10, 6, 14)                       # the Cedolan Gym's entrance
  fight.("Liam", 4, [10, 6, 14])
  a.warp!(10, 6, 6)                        # in front of Brock, out of the Camper's sight
  fight.("Brock", 3, [10, 6, 6])
  a.set_selfswitch!(10, 3, "A", "off")     # Brock again, as after a loss
  fight.("Brock again", 3, [10, 6, 6])

  recs  = records.call
  seeds = s.db[:trainer_battles].where(account_id: id).order(:id).select_map(%i[id seed])
  s.check("the client asked, and got, a seed for each") { a.log_tail(400).count { |l| l.include?("trainer battle seeded") } == 3 }
  s.check("each battle ran on its placement's seed") do
    recs.map { |r| r[:mode] } == %w[on on on] && seeds.size == 2 &&
      recs.map { |r| r[:battle_seed] } == [seeds[0][1], seeds[1][1], seeds[1][1]]
  end
  # A seed holds one won battle (P4): Brock won twice, the first win gives way to the second.
  s.check("each seed holds its last battle") { recs.last[:trainer_battle_id] == seeds[1][0] }
  s.check("each record passed the seed walk") { recs.map { |r| r[:replay_status] } == %w[walk_ok walk_ok walk_ok] }
  lines = recs.map do |r|
    out, = Open3.capture2e({ "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "REPLAY_ID" => r[:id].to_s },
                           "bundle", "exec", "ruby", "bin/pemk_replay.rb", chdir: Autotest::SERVER_DIR)
    out.lines.grep(/^  #/).join
  end
  File.write(File.join(s.dir, "replay.txt"), lines.join)
  s.check("each replays to a match, every draw from the seed") do
    records.call.map { |r| r[:replay_status] } == %w[match match match]
  end
end
