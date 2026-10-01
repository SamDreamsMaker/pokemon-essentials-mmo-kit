# frozen_string_literal: true

# Where the server denies debug mode (PEMK_CLIENT_DEBUG=deny, the default), a debug
# launch's autopilot - one environment variable away for any player - only reads once
# logged in: no key, no item, no warp. Debug mode itself stays off.
Autotest.scenario "where the server denies debug mode, the autopilot only reads",
                  flags: { PEMK_CLIENT_DEBUG: "deny" }, budget: 240 do |s|
  s.check("the server says so at boot") { s.server.grep(/client debug = deny/).any? }
  a = s.player(:a)
  # a debug launch skips the title; the load screen logs in with the configured account
  # (a key is harmless until then, refused after)
  st = s.wait_for("the login", seconds: 120) do
    now = a.state
    next now if now.dig("online", "logged_in")

    a.ap("press C")
    nil
  end
  s.check("logged in, debug mode is off") { st["debug"] == false }
  refused = a.ap("press C")
  s.check("a key is refused") { refused["ok"] == false && refused["error"].to_s.include?("locked by the server") }
  s.check("so is a change to the game") do
    reply = s.wait_for("a game loaded", seconds: 60) { r = a.ap("get_switch 1"); r if r["ok"] }
    added = a.ap("add_item POTION 5")
    reply["ok"] && added["ok"] == false && added["error"].to_s.include?("locked by the server")
  end
  s.check("the state still answers") { a.ap("state")["ok"] == true }
end
