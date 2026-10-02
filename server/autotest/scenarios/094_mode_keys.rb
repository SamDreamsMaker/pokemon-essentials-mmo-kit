# frozen_string_literal: true

# Mode keys: a modified client that says it surfs with no Surf badge is sent back to the
# shore and flagged (PEMK_POS_ENFORCE=on); one with the badges and a Pokemon knowing Surf
# surfs on; one with the badges but no such Pokemon is sent back too. On the demo's export:
# Route 8's water off the harbor's pier (080 surfs it).
ROUTE8_094 = 69

Autotest.scenario "a swim with no key is sent back to the shore",
                  flags: { PEMK_POS_ENFORCE: "on", PEMK_ANOMALY_DETECTION: "on" }, budget: 120 do |s|
  s.check("the server checks the keys") { s.server.grep(/mode keys: surf needs/).any? }
  caps = %w[money_claims trainer_proof save_ack badge_hold badge_alone debug_lock presence_v2 swim_report]
  rogue = s.rogue(:r, caps: caps)
  rogue.send_env({ type: :pos, map: ROUTE8_094, x: 26, y: 12, dir: 4, mode: :walk })    # the grass above the pier
  rogue.send_env({ type: :pos, map: ROUTE8_094, x: 25, y: 12, dir: 4, mode: :surf })    # onto the water, no badge
  back = rogue.wait_for(:pos_correct)[:env]
  s.check("sent back to the shore") { back.values_at(:map, :x, :y) == [ROUTE8_094, 26, 12] }
  s.check("said") { s.server.grep(/posaudit: account #{rogue.account_id} surf with no key .* -> sent back to the shore/).any? }
  s.check("flagged") { s.wait_for("the flag", seconds: 10) { s.db[:player_flags].where(account_id: rogue.account_id, kind: "mode_illegal").any? } }

  honest = s.rogue(:h, caps: caps)
  honest.send_env({ type: :team_check, seq: 1, team: [{ "species" => "LAPRAS", "level" => 30, "moves" => ["SURF"] }] })   # a surfer in the party
  honest.wait_for(:team_ack)
  honest.send_env({ type: :econ, field: :badges, value: 0b1111, seq: 1 })               # four badges (the client's word here)
  honest.wait_for(:econ_ack, :econ_rej)
  sleep 1   # the keys are read again at once, off the reactor (a few ms)
  honest.send_env({ type: :pos, map: ROUTE8_094, x: 26, y: 12, dir: 4, mode: :walk })
  honest.send_env({ type: :pos, map: ROUTE8_094, x: 25, y: 12, dir: 4, mode: :surf })
  honest.send_env({ type: :pos, map: ROUTE8_094, x: 24, y: 12, dir: 4, mode: :surf })
  corrected = begin
    honest.wait_for(:pos_correct, seconds: 3)
    true
  rescue Autotest::Failure
    false
  end
  s.check("with the badges, the swim goes on") { !corrected }
  # the keys flag nothing here; badge authority in shadow does flag badges claimed with no win
  s.check("and the keys flag nothing") { s.db[:player_flags].where(account_id: honest.account_id, kind: "mode_illegal").empty? }

  nosurfer = s.rogue(:n, caps: caps)                                                      # the badges, no Pokemon knowing Surf
  nosurfer.send_env({ type: :team_check, seq: 1, team: [{ "species" => "PIKACHU", "level" => 30, "moves" => ["THUNDERBOLT"] }] })
  nosurfer.wait_for(:team_ack)
  nosurfer.send_env({ type: :econ, field: :badges, value: 0b1111, seq: 1 })
  nosurfer.wait_for(:econ_ack, :econ_rej)
  sleep 1
  nosurfer.send_env({ type: :pos, map: ROUTE8_094, x: 26, y: 12, dir: 4, mode: :walk })
  nosurfer.send_env({ type: :pos, map: ROUTE8_094, x: 25, y: 12, dir: 4, mode: :surf })
  back = nosurfer.wait_for(:pos_correct)[:env]
  s.check("with the badges but no surfer, sent back too") { back.values_at(:map, :x, :y) == [ROUTE8_094, 26, 12] }
  s.check("the line names the move") do
    s.server.grep(/account #{nosurfer.account_id} surf with no key \(a Pokemon knowing SURF or DIVE needed, the party knew none\)/).any?
  end
end
