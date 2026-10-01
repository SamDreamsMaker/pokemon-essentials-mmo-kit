# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

# Badge authority B1 (docs/BADGE-AUTHORITY-DESIGN.md), shadow: each badge a client
# reports is judged by the battle that gives it. Brock's badge after a real win waits
# for its replay, and the proven win would grant it. Modified clients' badges - Brock's
# with no battle, every badge at once - are what enforcement would refuse; Brock's after a
# claim with no record on its seed waits for one; after a claim with no seed, no replay
# can prove it.
# On a copy of the demo's export with the stock house's badge write (an edited demo has
# none): the server names it as what keeps it from owning the badges.
WORLD_088 = File.join(Dir.tmpdir, "pemk_world_088.json")
begin
  File.delete(WORLD_088) if File.exist?(WORLD_088)   # never a stale copy: no file, no badges
  world = JSON.parse(File.read(File.join(Autotest::SERVER_DIR, "data", "world.json")))
  (world["badge_sources"] ||= { "list" => [], "unknown" => [] })["unknown"] <<
    { "map" => 3, "event" => 7, "page" => 0, "script" => "for i in 0...16; $player.badges[i] = true; end" }
  File.write(WORLD_088, JSON.generate(world))
rescue StandardError => e
  warn "088: no fixture world (#{e.class}: #{e.message})"
end

Autotest.scenario "a badge is judged by the battle that gives it",
                  flags: { PEMK_BATTLE_ENFORCE_RNG: "on", PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on",
                           PEMK_MONEY_AUTHORITY: "shadow", PEMK_BATTLE_ENFORCE_TEAMS: "on",
                           PEMK_BATTLE_ENFORCE_EXP: "on", PEMK_TRAINER_PROOF: "shadow",
                           PEMK_BADGE_AUTHORITY: "shadow", PEMK_WORLD: WORLD_088 },
                  budget: 480 do |s|
  s.check("the server says what keeps it from owning the badges: the house's debug badges") do
    s.server.grep(/badge authority cannot own: a badge set the export cannot read: map 3 event 7/).any?
  end
  a = s.player(:a)
  a.new_game("Leader")
  id = s.account_id(a)
  a.fast!
  a.add_pokemon!("WARTORTLE", 40)          # beats Brock's rock types
  a.warp!(10, 6, 6)                        # in front of Brock, out of the Camper's sight
  a.wait_until!("idle within 10", timeout: 20)
  a.talk_to!(3, timeout: 60)
  a.converse
  s.check("Brock's battle started") { a.in_battle?(10) }
  a.fight_battle
  a.converse

  verdict = s.wait_for("Brock's badge is judged as it reaches the server", seconds: 30) do
    s.server.grep(/badge: account #{id} badge 0 /).first
  end
  s.check("Brock's badge waits for its win's replay", verdict) do
    verdict.include?("PENDING: the win over LEADER_Brock Brock waits for its replay")
  end
  claim = s.wait_for("the prize claim names its battle", seconds: 30) do
    s.db[:money_claims].where(account_id: id, kind: "trainer").exclude(trainer_battle_id: nil).first
  end
  record = s.db[:battle_records].where(trainer_battle_id: claim[:trainer_battle_id], outcome: 1).first
  out, = Open3.capture2e({ "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "REPLAY_ID" => record[:id].to_s,
                           "PEMK_WORLD" => WORLD_088 },
                         "bundle", "exec", "ruby", "bin/pemk_replay.rb", chdir: Autotest::SERVER_DIR)
  File.write(File.join(s.dir, "replay.txt"), out.lines.grep(/^  #/).join)
  s.check("Brock's battle replays as it was played") do
    s.db[:battle_records].where(id: record[:id]).get(:replay_status) == "match"
  end
  s.wait_for("the proven win would grant badge 0", seconds: 20) do
    s.server.grep(/badge: account #{id} WOULD-GRANT badge 0 \(claim #{claim[:nonce]}'s win is proven\)/).first
  end
  s.check("the honest player's badge is never judged a cheat") do
    s.server.grep(/badge: account #{id} badge \d+ WOULD-REFUSE/).empty?
  end

  # A modified client: Brock's badge with no battle, then every badge at once.
  rogue = s.rogue(:r)
  rid = rogue.account_id
  rogue.send_env({ type: :pos, map: 10, x: 6, y: 6, dir: 8, speed: 3 })
  rogue.send_env({ type: :econ, field: :badges, value: 0b1, seq: 1 })
  rogue.wait_for(:econ_ack, :econ_rej)
  rogue.send_env({ type: :econ, field: :badges, value: 0xFFFF, seq: 2 })
  rogue.wait_for(:econ_ack, :econ_rej)
  s.check("Brock's badge with no battle would be refused") do
    s.server.grep(/badge: account #{rid} badge 0 WOULD-REFUSE: no win over LEADER_Brock Brock was claimed/).any?
  end
  s.check("every badge at once would be refused, in one line") do
    s.server.grep(/badge: account #{rid} badges #{(1..15).to_a.join(', ')} WOULD-REFUSE: nothing the exports read gives it/).any?
  end

  brock = ["LEADER_Brock", "Brock", 0, 10, 3]
  claim = { type: :money_claim, nonce: 1, amount: 1400, amulet: false, happy_hour: false, map: 10, trainers: [brock] }
  # Brock's seed asked and his prize claimed on it, no battle recorded: no win on the seed.
  seeded = s.rogue(:seeded)
  seeded.send_env({ type: :pos, map: 10, x: 6, y: 6, dir: 8, speed: 3 })
  sleep 0.3
  seeded.send_env({ type: :trainer_battle_req, nonce: 1, trainers: [brock] })
  seed = seeded.wait_for(:trainer_battle_seed)[:env][:seed]
  seeded.send_env(claim.merge(seed: seed))
  seeded.wait_for(:money_claim_ack)
  seeded.send_env({ type: :econ, field: :badges, value: 0b1, seq: 1 })
  seeded.wait_for(:econ_ack, :econ_rej)
  s.check("a claim on Brock's seed with no battle recorded explains nothing") do
    s.server.grep(/badge: account #{seeded.account_id} badge 0 WAITING: the win over LEADER_Brock Brock has no record yet/).any?
  end

  # Brock's prize claimed with no seed (the daily allowance's path): no replay proves it.
  unseeded = s.rogue(:unseeded)
  unseeded.send_env({ type: :pos, map: 10, x: 6, y: 6, dir: 8, speed: 3 })
  sleep 0.3
  unseeded.send_env(claim)
  unseeded.wait_for(:money_claim_ack)
  unseeded.send_env({ type: :econ, field: :badges, value: 0b1, seq: 1 })
  unseeded.wait_for(:econ_ack, :econ_rej)
  s.check("a win claimed with no seed is unprovable") do
    s.server.grep(/badge: account #{unseeded.account_id} badge 0 UNPROVABLE: the win over LEADER_Brock Brock was claimed with no seed/).any?
  end
end
