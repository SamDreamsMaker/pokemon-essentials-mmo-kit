# frozen_string_literal: true

# Presence v2 (PEMK_PRESENCE_DEDUP, on by default): a player standing still costs its map
# nothing - its heartbeat repeats reach no updated client - yet stays drawn. Two windows on
# one map: each sees the other; ten seconds of standing still later (a timeout of the old
# kind would drop them within three), each still does; one leaves the map and the other
# drops it, it comes back and is drawn again at once.
Autotest.scenario "a player standing still stays drawn and costs nothing", budget: 360 do |s|
  s.check("the server keeps idle players to itself") { s.server.grep(/presence dedup = on/).any? }
  a = s.player(:a)
  b = s.player(:b)
  s.together(-> { a.new_game("Alice") }, -> { b.new_game("Bob") })
  a.warp!(7, 38, 30)
  b.warp!(7, 40, 30)
  s.check("each window draws the other") do
    s.wait_for("each window draws the other", seconds: 30) do
      a.remote_names.include?("Bob") && b.remote_names.include?("Alice")
    end
  end
  a.ap!("wait 600", timeout: 30)   # ten seconds, nobody moves
  s.check("ten seconds standing still later, still drawn") do
    a.remote_names.include?("Bob") && b.remote_names.include?("Alice")
  end
  b.warp!(7, 20, 10)               # elsewhere on the same map
  s.check("a step elsewhere on the map is seen") do
    s.wait_for("Bob's new tile", seconds: 15) do
      r = Array(a.state["remotes"]).find { |x| x["name"] == "Bob" }
      r && [r["x"], r["y"]] == [20, 10]
    end
  end
  b.warp!(10, 6, 6)                # another map (the gym, out of the Camper's sight)
  s.check("a player leaving the map is dropped") do
    s.wait_for("Bob gone", seconds: 15) { !a.remote_names.include?("Bob") }
  end
  b.warp!(7, 40, 30)
  s.check("back on the map, drawn again at once") do
    s.wait_for("Bob back", seconds: 15) { a.remote_names.include?("Bob") && b.remote_names.include?("Alice") }
  end
end
