# frozen_string_literal: true

# Debug mode stays off where the server says (PEMK_CLIENT_DEBUG; the autotest runs at
# `autopilot`: off, the autopilot obeyed). A debug launch plays with debug mode off; an
# event's `$DEBUG = true` - what the stock demo's house helper runs - is undone before the
# next command; F9 opens no debug menu.
Autotest.scenario "debug mode stays off where the server says", budget: 300 do |s|
  s.check("the server says so at boot") { s.server.grep(/client debug = autopilot/).any? }
  a = s.player(:a)
  a.new_game("Locked")
  a.fast!
  s.check("a debug launch plays with debug mode off") { a.state["debug"] == false }
  s.check("the player is told once") { a.log_tail(200).count { |l| l.include?("debug: turned off") } == 1 }
  s.check("an event's $DEBUG = true is undone at once") { a.set_debug!("on")["debug"] == false }
  s.check("and stays undone") { a.state["debug"] == false }
  s.check("the autopilot is obeyed at this level") { a.add_pokemon!("PIDGEY", 5)["added"] == true }
  a.press!("F9")
  a.ap("wait_until menu within 2", timeout: 10)
  s.check("F9 opens no debug menu") { st = a.state; Array(st["menus"]).empty? && Array(st["screens"]).empty? }
end
