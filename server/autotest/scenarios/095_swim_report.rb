# frozen_string_literal: true

require "json"
require "tmpdir"

# Mode keys, the move half, with the real client: the game lets a player surf only with
# the badges and a party Pokemon knowing Surf, and the server asks the same - from the
# party the client reports before the swim's first frame. An honest player with both
# surfs on under PEMK_POS_ENFORCE=on: no line, no flag, no snap-back - which is only so
# if the report reached the server first (a swim judged with no party is sent back).
# On a copy of the demo's export that asks for the move, whatever the export on disk says.
ROUTE8_095 = 69
WORLD_095  = File.join(Dir.tmpdir, "pemk_world_095.json")
begin
  File.delete(WORLD_095) if File.exist?(WORLD_095)
  world = JSON.parse(File.read(File.join(Autotest::SERVER_DIR, "data", "world.json")))
  raise "the export has no field keys" unless world["field_keys"].is_a?(Hash)

  world["field_keys"]["surf_move"] = true
  world["field_keys"]["dive_move"] = true
  File.write(WORLD_095, JSON.generate(world))
rescue StandardError => e
  warn "095: no fixture world (#{e.class}: #{e.message})"
end

Autotest.scenario "a surfer's party is known before its first stroke",
                  flags: { PEMK_POS_ENFORCE: "on", PEMK_BADGE_AUTHORITY: "off", PEMK_ANOMALY_DETECTION: "on",
                           PEMK_WORLD: WORLD_095 }, budget: 300 do |s|
  s.check("the server asks for the badges and the move") do
    s.server.grep(/mode keys: surf needs 4 badges, dive 7 badges \(a swim with no key is sent back to the shore\)/).any? &&
      s.server.grep(/mode keys: a surfer needs a Pokemon knowing Surf or Dive, a diver needs a Pokemon knowing Dive/).any?
  end
  a = s.player(:a)
  a.new_game("Swimmer")
  id = s.account_id(a)
  a.fast!
  a.set_selfswitch!(ROUTE8_095, 5, "A", "on")   # the swimmer Ariel, beaten: she does not stop the surfer
  a.add_pokemon!("SLOWPOKE", 30)                # it knows Surf at 30
  4.times { |i| a.set_badge!(i, "on") }         # the four badges Surf needs, as a gym leader's event writes them
  a.warp!(ROUTE8_095, 26, 12)                   # the grass above the harbor's pier
  a.wait_until!("idle within 10", timeout: 20)
  a.walk_to!(27, 12, timeout: 30)
  s.wait_for("the server has the player on Route 8", seconds: 20) do
    s.server.grep(/posaudit: account #{id} illegal_warp .*->#{ROUTE8_095}\(/).any?
  end
  where = lambda do
    st = a.state
    [st.dig("map", "id"), st.dig("player", "x"), st.dig("player", "y"), st.dig("player", "mode")]
  end

  a.walk_to!(26, 12, timeout: 30)
  a.face!("left")
  a.interact!
  a.converse("Yes")                             # "Would you like to use Surf on it?"
  s.check("the player surfs off the shore") { where.call == [ROUTE8_095, 25, 12, "surf"] }
  a.walk_to!(24, 12, timeout: 30)
  sleep 3                                       # a snap-back, had the server judged the swim with no party, lands within a second
  s.check("and swims on: the server knew its party") { where.call == [ROUTE8_095, 24, 12, "surf"] }
  s.check("no key was missing") { s.server.grep(/account #{id} (surf|dive) with no key/).empty? }
  s.check("nothing was flagged") { s.db[:player_flags].where(account_id: id, kind: "mode_illegal").empty? }
end
