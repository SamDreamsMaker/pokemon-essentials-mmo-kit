# frozen_string_literal: true

# Server-minted wild encounters (D2) mint the encounter table's own roll and nothing else.
# The invisible Kecleon of Route 3 is an event's battle - WildBattle.start(:KECLEON, 30),
# for a player holding the Silph Scope - and it stays the game's even when an encounter a
# Repel turned away left the encounter type set: the server used to mint a Route 3 roll in
# its place (and the event, its self switch set after the battle, was spent).
ROUTE3_096 = 31

Autotest.scenario "an event's battle stays the game's after a repelled encounter",
                  flags: { PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on" }, budget: 300 do |s|
  a = s.player(:a)
  a.new_game("Hunter")
  id = s.account_id(a)
  a.fast!
  a.add_pokemon!("MACHOP", 30)      # above Route 3's wild levels (12-17): a Repel turns every one away
  a.add_item!("SILPHSCOPE", 1)      # what the invisible Kecleon shows itself to
  a.repel!(250)
  a.warp!(ROUTE3_096, 45, 45)       # below the Kecleon (event 28, at 45,44)
  a.wait_until!("idle within 10", timeout: 20)

  # The nearest grass, walked to and fro until an encounter is rolled - and turned away.
  pair = a.grass_pairs.first
  raise Autotest::Failure, "no grass on Route 3" unless pair

  deadline = Autotest.mono + 120
  type = nil
  until (type = a.state.dig("flags", "encounter_type"))
    raise Autotest::Failure, "no encounter rolled in 120 s" if Autotest.mono > deadline
    raise Autotest::Failure, "a wild battle started through the Repel" if a.in_battle?

    pair.each { |x, y| a.walk_to(x, y, timeout: 30) }
  end
  s.check("an encounter the Repel turned away left its type set") { type == "Land" }

  # The Kecleon has no graphic: it is met where it stands, with USE.
  a.walk_to!(45, 44, timeout: 60)
  s.check("the player stands on the Kecleon's tile") { a.state.dig("player", "x") == 45 && a.state.dig("player", "y") == 44 }
  a.interact!
  a.converse
  foe = Array(a.state.dig("battle", "battlers")).find { |b| b["side"] == "foe" }
  s.check("the battle is the event's: a Kecleon at 30 (#{foe&.values_at('species', 'level').inspect})") do
    foe && foe["species"] == "KECLEON" && foe["level"] == 30
  end
  s.check("the server minted nothing") { s.server.grep(/encounter: account #{id} MINT/).empty? }
end
