# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

# Badge authority B2 (docs/BADGE-AUTHORITY-DESIGN.md, section 4): owning the badges, the
# server has its clients fight a badge's battle alone - with a partner at the player's
# side it would get no seed, and no replay could prove the win. Here a copy of the demo's
# export says Camper Liam's win gives badge 1, and May is the player's partner (Liam has
# two Pokemon: she would join): the battle is fought alone, seeded, and its replay grants
# the badge. A client that cannot fight it alone must update.
WORLD_090 = File.join(Dir.tmpdir, "pemk_world_090.json")
begin
  world = JSON.parse(File.read(File.join(Autotest::SERVER_DIR, "data", "world.json")))
  (world["badge_sources"] ||= { "list" => [], "unknown" => [] })["list"] <<
    { "badge" => 1, "map" => 10, "event" => 4, "page" => 0, "trainers" => [["CAMPER", "Liam", 0]], "call" => 0 }
  File.write(WORLD_090, JSON.generate(world))
rescue StandardError => e
  warn "090: no fixture world (#{e.class}: #{e.message})"
end

Autotest.scenario "a badge's battle is fought alone",
                  flags: { PEMK_MONEY_AUTHORITY: "on", PEMK_ITEM_AUTHORITY: "on", PEMK_PICKUP_ENFORCE: "on",
                           PEMK_GIFT_ENFORCE: "on", PEMK_SHOP_ENFORCE: "on", PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on",
                           PEMK_BATTLE_ENFORCE_RNG: "on", PEMK_BATTLE_ENFORCE_TEAMS: "on",
                           PEMK_BATTLE_ENFORCE_EXP: "on", PEMK_TRAINER_PROOF: "on", PEMK_BADGE_AUTHORITY: "on",
                           PEMK_WORLD: WORLD_090 },
                  budget: 480 do |s|
  s.check("the server owns the badges, its clients fight their battles alone") do
    s.server.grep(/badge authority ENFORCED .*badge_alone/).any?
  end
  refused = begin
    s.rogue(:old, caps: %w[money_claims trainer_proof save_ack badge_hold])
    false
  rescue Autotest::Failure => e
    e.message.include?("update_required")
  end
  s.check("a client that cannot fight them alone must update") { refused }

  a = s.player(:a)
  a.new_game("Alone")
  id = s.account_id(a)
  a.fast!
  owned = -> { s.db[:economy_balances].where(account_id: id, field: "badges").get(:balance).to_i }
  a.add_pokemon!("WARTORTLE", 40)
  s.check("May is at the player's side") do
    a.partner!("POKEMONTRAINER_May", "May", 0)["partner"] == ["POKEMONTRAINER_May", "May", 1]
  end
  a.warp!(10, 5, 10)                       # out of Liam's sight: he looks right, from (3,8)
  a.wait_until!("idle within 10", timeout: 20)
  a.walk_to(5, 8, timeout: 30)             # into it: he walks up and challenges
  a.converse
  s.check("Liam's battle started") { a.in_battle?(10) }
  a.fight_battle
  a.converse

  claim = s.db[:money_claims].where(account_id: id, kind: "trainer").first
  s.check("its seed was asked: May did not join") { claim && !claim[:trainer_battle_id].nil? }
  record = claim && s.db[:battle_records].where(trainer_battle_id: claim[:trainer_battle_id], outcome: 1).first
  s.check("the win is recorded") { !record.nil? }
  if record
    out, = Open3.capture2e({ "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "REPLAY_ID" => record[:id].to_s,
                             "PEMK_WORLD" => WORLD_090 },
                           "bundle", "exec", "ruby", "bin/pemk_replay.rb", chdir: Autotest::SERVER_DIR)
    File.write(File.join(s.dir, "replay.txt"), out.lines.grep(/^  #/).join)
  end
  s.check("the replay proves the win, which grants Liam's badge") do
    s.wait_for("the grant", seconds: 30) { owned.call == 0b10 }
  end
  s.check("no flag on the honest player") do
    s.db[:player_flags].where(account_id: id, kind: %w[badge_unexplained badge_unprovable]).empty?
  end
ensure
  # the autotest database's other scenarios run a server that does not own the badges
  s.db[:badge_cutover].delete
end
