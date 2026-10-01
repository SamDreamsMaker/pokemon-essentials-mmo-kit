# frozen_string_literal: true

# The passability export counts every water tile as a wall, and the server used to
# trust any client that said it was surfing or diving - through walls too. The world
# export now marks the water, and where Dive goes down. An honest player surfs Route 8,
# dives to the map below, walks there, comes back up and lands: nothing may be flagged
# (shadow logs what `on` would correct). A modified client that surfs into the cliff,
# dives from shallow water or walks through a wall underwater is flagged each time.
ROUTE8     = 69
UNDERWATER = 70

# It surfs and dives with no badge and no Pokemon: through debug mode (PEMK_CLIENT_DEBUG allow).
Autotest.scenario "a surfer crosses water, and only water",
                  flags: { PEMK_POS_ENFORCE: "shadow", PEMK_CLIENT_DEBUG: "allow" }, budget: 420 do |s|
  a = s.player(:a)
  a.new_game("Swimmer")                    # no Pokemon yet: no wild battle on the water
  id = s.account_id(a)
  a.fast!
  a.set_selfswitch!(ROUTE8, 5, "A", "on")  # the swimmer Ariel, beaten: she does not stop the surfer

  # The debug warp is a map change no door explains: wait until the server has logged
  # it, then judge only what follows.
  a.warp!(ROUTE8, 26, 12)                  # the grass above the harbor's pier
  a.wait_until!("idle within 10", timeout: 20)
  a.walk_to!(27, 12, timeout: 30)          # a step on land sends the position
  s.wait_for("the server has the player on Route 8", seconds: 20) do
    s.server.grep(/posaudit: account #{id} illegal_warp .*->#{ROUTE8}\(/).any?
  end
  mark = s.server.lines.size
  flagged = -> { s.server.lines[mark..].grep(/posaudit: account #{id} |posenforce\[shadow\]: account #{id} /) }
  where = lambda do
    st = a.state
    [st.dig("map", "id"), st.dig("player", "x"), st.dig("player", "y"), st.dig("player", "mode")]
  end

  a.walk_to!(26, 12, timeout: 30)
  a.face!("left")
  a.interact!
  a.converse("Yes")                        # "Would you like to surf on it?"
  s.check("the player surfs off the shore") { where.call == [ROUTE8, 25, 12, "surf"] }

  a.walk_to!(12, 21, timeout: 60)          # across the bay to the deep water
  a.interact!
  a.converse("Yes")                        # "The sea is deep here. Would you like to use Dive?"
  a.wait_until!("map #{UNDERWATER} within 10", timeout: 20)
  a.wait_until!("idle within 5", timeout: 15)
  s.check("Dive takes the player to the same tile below") { where.call == [UNDERWATER, 12, 21, "dive"] }

  a.walk_to!(13, 22, timeout: 30)
  # A snap-back (what `on` sends for a refused move) keeps a swimmer swimming: on foot
  # on water it could never move again, and a diver could never come up.
  # A snap-back the server itself sent would name a tile it holds; this one is the
  # harness's, so the player turns on the spot (which reports the tile) and the server
  # holds it before the next move is judged.
  sent_back = lambda do |to, what|
    s.server.tell(id, type: :pos_correct, map: to[0], x: to[1], y: to[2])
    ok = (s.wait_for(what, seconds: 15) { where.call == to } rescue false)
    a.face!("up")
    a.face!("down")
    ok && (s.wait_for("the server holds it", seconds: 10) { s.server.last_pos(id) == to[0, 3] } rescue false)
  end
  s.check("a diver sent back still dives") { sent_back.([UNDERWATER, 12, 21, "dive"], "the diver sent back") }
  a.walk_to!(13, 22, timeout: 30)
  a.interact!
  a.converse("Yes")                        # "Light is filtering down from above..."
  a.wait_until!("map #{ROUTE8} within 10", timeout: 20)
  a.wait_until!("idle within 5", timeout: 15)
  s.check("the player comes back up, surfing") { where.call == [ROUTE8, 13, 22, "surf"] }
  s.check("a surfer sent back still surfs") { sent_back.([ROUTE8, 14, 22, "surf"], "the surfer sent back") }
  s.check("a surfer sent back below dives there") do
    sent_back.([UNDERWATER, 14, 22, "dive"], "the surfer sent back below")
  end
  a.wait_until!("idle within 5", timeout: 15)
  a.interact!
  a.converse("Yes")                        # up again
  a.wait_until!("map #{ROUTE8} within 10", timeout: 20)
  a.wait_until!("idle within 5", timeout: 15)

  a.walk_to!(25, 12, timeout: 60)
  a.walk_to!(26, 12, timeout: 30)          # onto the shore: a jump off the water
  a.wait_until!("idle within 5", timeout: 15)
  # The surf ends just after the jump lands.
  landed = (s.wait_for("the landing", seconds: 10) { where.call == [ROUTE8, 26, 12, "walk"] } rescue false)
  s.check("the player lands on the shore, walking") { landed }
  s.check("the server flagged none of it") { flagged.call.empty? }

  # A modified client, frame by frame, beside the same shore: the cliff at (25,10)
  # stands over the water at (25,11).
  rogue = s.rogue(:r)
  rid = rogue.account_id
  frame = ->(map, x, y, mode) { rogue.send_env({ type: :pos, map: map, x: x, y: y, dir: 2, speed: 3, mode: mode }) }
  seen = lambda do |what, pattern|
    s.wait_for(what, seconds: 15) { s.server.grep(pattern).any? }
  end
  frame.(ROUTE8, 26, 11, :walk)            # its first frame: taken as it is
  sleep 0.3
  frame.(ROUTE8, 25, 11, :surf)            # onto the water
  sleep 0.3
  frame.(ROUTE8, 25, 10, :surf)            # into the cliff
  seen.("the surfer in the cliff", /posaudit: account #{rid} noclip #{ROUTE8}\(25,11\)->#{ROUTE8}\(25,10\) mode=surf/)
  frame.(ROUTE8, 25, 11, :surf)            # back onto the water
  sleep 0.3
  frame.(UNDERWATER, 25, 11, :dive)        # "dives" from shallow water
  seen.("the dive from shallow water", /posaudit: account #{rid} illegal_warp #{ROUTE8}\(25,11\)->#{UNDERWATER}\(25,11\)/)
  frame.(UNDERWATER, 25, 10, :dive)        # and walks through the rock below
  seen.("the diver in the rock", /posaudit: account #{rid} noclip #{UNDERWATER}\(25,11\)->#{UNDERWATER}\(25,10\) mode=dive/)
  s.check("the water under the rogue was never flagged") do
    s.server.grep(/posaudit: account #{rid} \w+ \S+->#{ROUTE8}\(25,11\)/).empty?
  end
  s.check("each of its three moves would be corrected") do
    s.server.grep(/posenforce\[shadow\]: account #{rid} WOULD-CORRECT/).size == 3
  end
end
