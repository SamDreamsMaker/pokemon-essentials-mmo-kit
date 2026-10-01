# frozen_string_literal: true

# Money authority M1c: Pay Day's coins are claimed where the engine pays them. With the
# server minting wild encounters (D2 on), a Meowth scatters coins on Route 1: the claim
# names the foe the server minted, is judged paid for exactly what the engine paid, and
# the mint is marked as paid for, so it cannot back another claim. The shadow balance
# explains every coin.
Autotest.scenario "Pay Day's coins are claimed and judged",
                  flags: { PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on", PEMK_MONEY_AUTHORITY: "shadow" },
                  budget: 360 do |s|
  a = s.player(:a)
  a.new_game("Payday")
  id = s.account_id(a)
  a.fast!
  a.add_pokemon!("MEOWTH", 19)             # learned Pay Day at 12, kept until 20; Route 1's foes are 11-14
  a.warp!(5, 18, 20)                       # Route 1
  a.wait_until!("idle within 10", timeout: 20)
  before = a.state.dig("trainer", "money")

  a.find_wild_battle
  a.fight_battle(prefer: "PAYDAY")
  a.converse
  coins = a.state.dig("trainer", "money") - before
  claim = -> { s.db[:money_claims].where(account_id: id, kind: "payday").first }
  s.wait_for("the Pay Day claim reaches the server", seconds: 20) { claim.call }

  s.check("Pay Day scattered coins") { coins.positive? }
  s.check("the claim is judged paid, for what the engine paid") do
    claim.call.values_at(:verdict, :accepted, :amount) == ["paid", coins, coins]
  end
  s.check("the minted foe is marked as paid for") do
    s.db[:encounter_rolls].where(account_id: id).exclude(payday_at: nil).count == 1
  end
  s.check("the shadow balance explains every coin") do
    s.server.grep(/money: account #{id} (UNEXPLAINED|WOULD-REFUSE|SUSPECT)/).empty?
  end
end
