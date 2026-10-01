# frozen_string_literal: true

require "open3"
require "json"
require "tmpdir"

# Badge authority B2 (docs/BADGE-AUTHORITY-DESIGN.md): the server owns the badges. An
# honest win over Brock shows his badge at once - pending, not owned - and the replay that
# proves the win grants it; it stays across a relaunch. A modified client's badge frame
# raises nothing; a client that cannot hold its badge frame must update.
# The demo's export keeps the server from owning badges (the house's debug badges, partner
# May): this runs on a copy without them.
WORLD_089 = File.join(Dir.tmpdir, "pemk_world_089.json")
world = JSON.parse(File.read(File.join(Autotest::SERVER_DIR, "data", "world.json")))
world["badge_sources"]["unknown"] = []
world["badge_sources"]["list"].each { |src| src["no_partner"] = true if src["trainers"] }
File.write(WORLD_089, JSON.generate(world))

Autotest.scenario "the server owns the badges",
                  flags: { PEMK_MONEY_AUTHORITY: "on", PEMK_ITEM_AUTHORITY: "on", PEMK_PICKUP_ENFORCE: "on",
                           PEMK_GIFT_ENFORCE: "on", PEMK_SHOP_ENFORCE: "on", PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on",
                           PEMK_BATTLE_ENFORCE_RNG: "on", PEMK_BATTLE_ENFORCE_TEAMS: "on",
                           PEMK_BATTLE_ENFORCE_EXP: "on", PEMK_TRAINER_PROOF: "on", PEMK_BADGE_AUTHORITY: "on",
                           PEMK_WORLD: WORLD_089 },
                  budget: 540 do |s|
  s.check("the server owns the badges") { s.server.grep(/badge authority ENFORCED/).any? }
  refused = begin
    s.rogue(:old, caps: %w[money_claims trainer_proof save_ack])
    false
  rescue Autotest::Failure => e
    e.message.include?("update_required")
  end
  s.check("a client that cannot hold its badge frame must update") { refused }

  a = s.player(:a)
  a.new_game("Leader")
  id = s.account_id(a)
  a.fast!
  owned = -> { s.db[:economy_balances].where(account_id: id, field: "badges").get(:balance).to_i }
  shown = -> { a.state.dig("trainer", "badges") }
  a.add_pokemon!("WARTORTLE", 40)          # beats Brock's rock types
  a.warp!(10, 6, 6)                        # in front of Brock, out of the Camper's sight
  a.wait_until!("idle within 10", timeout: 20)
  a.talk_to!(3, timeout: 60)
  a.converse
  s.check("Brock's battle started") { a.in_battle?(10) }
  a.fight_battle
  a.converse

  s.wait_for("Brock's badge reaches the server, pending", seconds: 40) do
    s.server.grep(/badge: account #{id} badge 0 PENDING/).first
  end
  s.check("the game shows the badge at once") { s.wait_for("the badge", seconds: 10) { shown.call == 1 } }
  s.check("the server does not own it yet") { owned.call.zero? }
  claim = s.db[:money_claims].where(account_id: id, kind: "trainer").exclude(trainer_battle_id: nil).first
  record = s.db[:battle_records].where(trainer_battle_id: claim[:trainer_battle_id], outcome: 1).first
  out, = Open3.capture2e({ "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "REPLAY_ID" => record[:id].to_s,
                           "PEMK_WORLD" => WORLD_089 },
                         "bundle", "exec", "ruby", "bin/pemk_replay.rb", chdir: Autotest::SERVER_DIR)
  File.write(File.join(s.dir, "replay.txt"), out.lines.grep(/^  #/).join)
  s.check("the replay proves the win, which grants the badge") do
    s.wait_for("the grant", seconds: 30) { owned.call == 1 }
  end
  s.check("granted as a proven win's") do
    s.db[:badge_grants].where(account_id: id).select_map(%i[badge evidence]) == [[0, "proof"]]
  end
  s.check("the honest player's badge is never refused") do
    s.server.grep(/badge: account #{id} badge.* (REFUSED|UNPROVABLE)/).empty? &&
      s.db[:player_flags].where(account_id: id, kind: %w[badge_unexplained badge_unprovable]).empty?
  end
  a.relaunch
  s.check("after a relaunch, the badge is still there") { s.wait_for("the badge", seconds: 20) { shown.call == 1 } }

  # A modified client: every badge in one frame.
  rogue = s.rogue(:r, caps: %w[money_claims trainer_proof save_ack badge_hold])
  rogue.send_env({ type: :pos, map: 10, x: 6, y: 6, dir: 8, speed: 3 })
  rogue.send_env({ type: :econ, field: :badges, value: 0xFFFF, seq: 1 })
  answer = rogue.wait_for(:econ_ack, :econ_rej)[:env]
  s.check("a frame raises no badge") do
    answer[:type] == :econ_rej && answer[:value].zero? &&
      s.db[:economy_balances].where(account_id: rogue.account_id, field: "badges").get(:balance).to_i.zero?
  end
end
