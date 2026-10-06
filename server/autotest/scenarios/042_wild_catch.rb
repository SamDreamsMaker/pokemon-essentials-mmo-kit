# frozen_string_literal: true

# With the server minting wild encounters, rolling catches and bounding battle
# rewards (PEMK_BATTLE_ENFORCE_ENCOUNTERS, _CATCHES and _REWARDS on), an honest catch
# in the tall grass of Route 1 goes through: the server mints the wild Pokemon, rolls
# the ball's shakes, and the catch joins the party under a uid whose origin says it
# was caught in the wild. The catch's EXP levels the lead up, which the battle's
# reward window must cover (it once raised a SUSPECT level jump). A relaunch keeps
# it all.
Autotest.scenario "a wild Pokemon is caught under server authority",
                  flags: { PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on", PEMK_BATTLE_ENFORCE_CATCHES: "on",
                           PEMK_BATTLE_ENFORCE_REWARDS: "on" },
                  budget: 360 do |s|
  a = s.player(:a)
  a.new_game("Catcher")
  id = s.account_id(a)
  a.fast!                                  # no animations, no nickname prompt
  a.add_pokemon!("MAGIKARP", 3)            # any Route 1 catch's EXP levels it up
  a.add_item!("MASTERBALL", 1)             # thrown before the foe can move
  a.warp!(5, 18, 20)                       # Route 1
  a.wait_until!("idle within 10", timeout: 20)

  a.find_wild_battle
  foe = Array(a.state.dig("battle", "battlers")).find { |b| b["side"] == "foe" }
  raise Autotest::Failure, "no wild Pokemon in the battle" unless foe

  a.catch_with("MASTERBALL")
  a.converse
  wild = foe["species"]

  s.check("the server minted the wild #{wild}") do
    !s.server.grep(/encounter: account #{id} MINT map 5 \S+ v\d+ -> #{wild}@#{foe['level']}/).empty?
  end
  s.check("and rolled the ball that caught it") do
    !s.server.grep(/catch: account #{id} VERDICT #{wild}@\d+ .* CAUGHT/).empty?
  end
  s.check("the catch joined the party") { a.party_species == ["MAGIKARP", wild] }
  uid = s.wait_for("the catch gets a uid", seconds: 30) { Array(a.state["party"])[1]&.dig("uid") }
  s.check("its uid says it was caught in the wild") { s.db[:monsters].where(id: uid).get(:origin) == "wild_caught" }
  s.check("the minted roll is marked caught and claimed") do
    s.db[:encounter_rolls].where(account_id: id).exclude(caught_at: nil).exclude(claimed_at: nil).count == 1
  end
  s.check("the catch's EXP levelled the lead up") { Array(a.state["party"])[0]["level"] > 3 }
  s.check("the battle's reward window covers it") do
    s.wait_for("the level-up reaches the server", seconds: 30) do
      !s.server.grep(/reward: account #{id} battle#\d+ outcome=4 /).empty?
    end
    s.server.grep(/reward: account #{id} SUSPECT/).empty?
  end

  a.relaunch
  s.check("a relaunch keeps it") { a.party_species == ["MAGIKARP", wild] }
end
