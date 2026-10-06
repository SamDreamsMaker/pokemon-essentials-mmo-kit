# frozen_string_literal: true

# Field gates (detection), on the demo's real export: Route 3's Cut tree at (17,14) and its
# headbutt tree at (22,20). A modified client that steps onto them with no key is told;
# one holding the badge and a Pokemon knowing Cut is not. A transfer from another map
# starts what the server judges (the maps a player stands on were loaded anew).
ROUTE3_097 = 31

Autotest.scenario "a step onto a Cut tree with no key is told",
                  flags: { PEMK_POS_ENFORCE: "shadow" }, budget: 120 do |s|
  s.check("the export lists the gates") { s.server.grep(/world data .* field gates \(\d+ obstacles, \d+ headbutt trees/).any? }
  caps = %w[money_claims trainer_proof save_ack badge_hold badge_alone debug_lock presence_v2 swim_report field_report]

  rogue = s.rogue(:r, caps: caps)
  rogue.send_env({ type: :pos, map: 1, x: 9, y: 7, dir: 2, mode: :walk })              # elsewhere first
  rogue.send_env({ type: :pos, map: ROUTE3_097, x: 16, y: 14, dir: 6, mode: :walk })
  rogue.send_env({ type: :pos, map: ROUTE3_097, x: 17, y: 14, dir: 6, mode: :walk })   # onto the tree
  rogue.send_env({ type: :pos, map: ROUTE3_097, x: 21, y: 20, dir: 6, mode: :walk })
  rogue.send_env({ type: :pos, map: ROUTE3_097, x: 22, y: 20, dir: 6, mode: :walk })   # onto the headbutt tree
  s.check("the Cut tree is told") do
    s.wait_for("the cut line", seconds: 10) do
      s.server.grep(/fieldaudit: account #{rogue.account_id} crossed a cut gate \(event \d+\) with no key \(badge 1 needed; no Pokemon knowing CUT\) at 31\(17,14\)/).any?
    end
  end
  s.check("the headbutt tree too") { s.server.grep(/fieldaudit: account #{rogue.account_id} crossed a headbutt tree at 31\(22,20\)/).any? }

  honest = s.rogue(:h, caps: caps)
  honest.send_env({ type: :team_check, seq: 1, team: [{ "species" => "FARFETCHD", "level" => 30, "moves" => ["CUT"] }] })
  honest.wait_for(:team_ack)
  honest.send_env({ type: :econ, field: :badges, value: 0b10, seq: 1 })                 # the badge Cut needs (the client's word here)
  honest.wait_for(:econ_ack, :econ_rej)
  sleep 1   # the badges are read again at once, off the reactor
  honest.send_env({ type: :pos, map: 1, x: 9, y: 7, dir: 2, mode: :walk })
  honest.send_env({ type: :pos, map: ROUTE3_097, x: 16, y: 14, dir: 6, mode: :walk })
  honest.send_env({ type: :pos, map: ROUTE3_097, x: 17, y: 14, dir: 6, mode: :walk })  # the tree it cut
  sleep 2
  s.check("a player with the key is not") { s.server.grep(/fieldaudit: account #{honest.account_id} /).empty? }
end
