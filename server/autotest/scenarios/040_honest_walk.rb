# frozen_string_literal: true

# Position enforcement snaps a player back from a blocked tile or a map change that
# matches no door, spawn or map edge. An honest walk must never be corrected: out
# of the house, across Lappet Town, over the edge into Route 1 and back, into the
# Pokemon Lab and out, and home, down the bedroom stairs first. Only real moves: no
# debug warp here.
Autotest.scenario "an honest walk is never corrected", flags: { PEMK_POS_ENFORCE: "on" } do |s|
  a = s.player(:a)
  a.new_game("Walker")
  id = s.account_id(a)

  a.enter!(3)                              # the bedroom stairs (a warp within the map)
  a.wait_until!("idle within 10", timeout: 20)
  a.enter!(1)                              # the house's front door
  a.wait_until!("map 2 within 10", timeout: 20)
  a.wait_until!("idle within 5", timeout: 15)
  a.walk_to!(14, 0, timeout: 60)           # Lappet Town's north exit
  a.cross("UP", 5)                         # Route 1
  a.walk_to!(18, 20, timeout: 60)
  a.walk_to!(18, 23, timeout: 60)
  a.cross("DOWN", 2)                       # back to Lappet Town
  a.enter!(2, timeout: 60)                 # the Pokemon Lab: Oak's welcome starts at
  a.wait_until!("map 4 within 10", timeout: 20)   # once and walks the player to him
  a.converse
  a.talk_to!(4)                            # the grass ball: Bulbasaur, no nickname
  a.converse("Yes", "No")
  a.enter!(7, timeout: 60)                 # the exit lets a player with a starter out
  a.wait_until!("map 2 within 10", timeout: 20)
  a.wait_until!("idle within 5", timeout: 15)
  a.enter!(1, timeout: 60)                 # home
  a.wait_until!("map 3 within 10", timeout: 20)
  a.wait_until!("idle within 5", timeout: 15)

  # Oak's welcome walks the player in a move route, whose steps the game does not
  # announce: the audit logs that as a teleport, which it never corrects.
  s.check("the walk ends at home, with Bulbasaur") do
    a.state.dig("map", "id") == 3 && a.party_species == ["BULBASAUR"]
  end
  s.check("the server saw no blocked step and no impossible warp") do
    s.server.grep(/posaudit: account #{id} (noclip|illegal_warp)/).empty?
  end
  s.check("it corrected nothing") { s.server.grep(/posenforce/).empty? }
  s.check("the client was never snapped back") { a.log_tail(400).none? { |l| l.include?("poscorrect: snapped") } }
  s.check("an honest walk has the game's pace") { s.server.grep(/posaudit: account #{id} paces/).empty? }
end
