require "minitest/autorun"
require "sequel"
require "json"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/proof_checks"
require "pemk/trainer_proofs"
require "pemk/money_claims"
require "pemk/battle_data"
require "pemk/team_audit"

# Trainer proof P3 (docs/TRAINER-PROOF-DESIGN.md). The player's team in a trainer record
# must be the server's own Pokemon (ProofChecks); a prize claim naming its battle's seed
# gets the replay's verdict (TrainerProofs): proven, refuted or unprovable - and a proven
# win spends the placement's seed.
class TrainerProofsTest < Minitest::Test
  STATS = %w[HP ATTACK DEFENSE SPECIAL_ATTACK SPECIAL_DEFENSE SPEED].freeze
  LIAM  = ["CAMPER", "Liam", 0, 10, 4].freeze

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))   # plain, as the replay tool's: jsonb as text
    @db[:battle_records].delete
    @db[:trainer_battles].delete
    @db[:money_claims].delete
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @me    = account("me@t.co")
    @other = account("other@t.co")
    @proofs = PEMK::TrainerProofs.new(@db)
    @now = Time.now
  end

  def teardown
    @db&.disconnect
  end

  def account(email)
    @db[:accounts].insert(email: email, password_hash: "x", status: "active", created_at: Time.now)
  end

  def mon(owner, ivs: nil, exp: nil, status: "active", shiny: false)
    uid = @db[:monsters].insert(owner_account_id: owner, issuer_account_id: owner, client_nonce: rand(1 << 40),
                                species: "WARTORTLE", level_at_issue: 20, personal_id: 1, status: status)
    if ivs
      @db[:monster_blocks].insert(uid: uid, species: "WARTORTLE", level: 20, ivs: ivs.to_json, evs: "{}",
                                  moves: "[]", shiny: shiny, gender: 0)
    end
    @db[:monster_stats].insert(uid: uid, exp: exp, level: 20) if exp
    uid
  end

  def frame(uid, iv: 10, exp: 5000, shiny: false, gender: 0)
    { uid: uid, iv: STATS.to_h { |s| [s, iv] }, exp: exp, shiny: shiny, gender: gender }
  end

  def team(*frames) = { init: { player: frames } }

  def test_the_player_team_must_be_the_server_s
    ivs = STATS.to_h { |s| [s, 10] }
    ok  = mon(@me, ivs: ivs, exp: 6000)
    assert_equal [:ok, nil], PEMK::ProofChecks.player_team(@db, @me, team(frame(ok)))
    assert_equal :ok, PEMK::ProofChecks.player_team(@db, @me, team(frame(ok, iv: 31)))[0], "Hyper Training"
    {
      frame(mon(@other))                    => /not this account's/,
      frame(mon(@me, status: "quarantined")) => /quarantined, not active/,
      frame(ok, iv: 25)                     => /IV HP 25, locked at 10/,
      frame(ok, shiny: true)                => /shiny changed/,
      frame(ok, gender: 1)                  => /gender changed/,
      frame(ok, exp: 7000)                  => /EXP 7000, more than the 6000 the server has seen/
    }.each do |f, why|
      verdict, reason = PEMK::ProofChecks.player_team(@db, @me, team(f))   # one each: a team holds each once
      assert_equal :refuted, verdict, reason
      assert_match why, reason
    end
    verdict, reason = PEMK::ProofChecks.player_team(@db, @me, team(frame(ok), { uid: nil, exp: 1 }))
    assert_equal [:unprovable, "player 1: a Pokemon the server has not registered yet"], [verdict, reason]
  end

  # P4's review: with the game's battle data, the species a uid can be (the one first seen,
  # or an evolution of it) and a legal set. A move no data explains may come from an event
  # script: unprovable, not refuted.
  AUDIT = PEMK::TeamAudit.new(PEMK::BattleData.new(File.expand_path("../data/battle_data.json", __dir__)))

  def test_the_player_team_is_what_its_pokemon_can_be
    ok = mon(@me, ivs: STATS.to_h { |s| [s, 10] }, exp: 6000)
    set = ->(**kw) { frame(ok).merge(species: "WARTORTLE", level: 20, moves: %w[TACKLE BITE], ability: "TORRENT",
                                     nature: "HARDY", ev: STATS.to_h { |s| [s, 20] }).merge(kw) }
    check = ->(f) { PEMK::ProofChecks.player_team(@db, @me, team(f), audit: AUDIT) }
    assert_equal [:ok, nil], check.(set.())
    assert_equal :ok, check.(set.(species: "BLASTOISE"))[0], "an evolution"
    {
      set.(species: "PIKACHU")                                      => /species PIKACHU is not WARTORTLE or an evolution/,
      set.(species: "SQUIRTLE")                                     => /species SQUIRTLE is not WARTORTLE/,
      set.(ev: STATS.to_h { |s| [s, 100] })                         => /an illegal set: ev_total_over:600>510/,
      set.(item: "BICYCLE")                                         => /an illegal set: unholdable_item:BICYCLE/
    }.each do |f, why|
      verdict, reason = check.(f)
      assert_equal :refuted, verdict, reason
      assert_match why, reason
    end
    verdict, reason = check.(set.(moves: %w[TACKLE SPORE]))
    assert_equal [:unprovable, true], [verdict, reason.include?("illegal_move:SPORE")], reason
    # the six stats only: a key of the client's own is neither a stat nor a verdict's words
    assert_equal [:ok, nil], check.(set.(iv: STATS.to_h { |s| [s, 10] }.merge("\xFF".b => 99)))
    assert_equal [:refuted, "player 0 (uid #{ok}): no EXP in the record"], check.(set.(exp: nil))
    assert_equal [:ok, nil], PEMK::ProofChecks.player_team(@db, @me, team(set.(species: "PIKACHU"))),
                 "without the battle data: not judged"
    @db[:monster_blocks].where(uid: ok).update(species: "NOT_IN_THE_DATA")
    assert_equal :unprovable, check.(set.())[0], "what it was first seen as, the data no longer knows"
    @db[:monster_blocks].where(uid: ok).update(species: "WARTORTLE")
    @db[:monster_stats].where(uid: ok).delete
    assert_equal [:unprovable, "player 0 (uid #{ok}): no EXP the server has seen for it"], check.(set.())
    assert_equal "a?b", PEMK::ProofChecks.safe_text("a\xFF\u0000b".b)
  end

  # A team no game fields is refuted whatever each Pokemon is.
  def test_a_team_no_game_fields
    ok = mon(@me, ivs: STATS.to_h { |s| [s, 10] }, exp: 6000)
    others = Array.new(6) { mon(@me, ivs: STATS.to_h { |s| [s, 10] }, exp: 6000) }
    {
      team(*([ok] + others).map { |u| frame(u) })    => "more than 6 Pokemon in the player's team",
      team(frame(ok), frame(ok))                    => "one Pokemon twice in the player's team",
      team(frame(ok).merge(moves: %w[A B C D E]))   => "a Pokemon with more than 4 moves"
    }.each do |t, why|
      assert_equal [:refuted, why], PEMK::ProofChecks.player_team(@db, @me, t)
    end
    assert_equal [:unprovable, "player 0: a Pokemon the server has not registered yet"],
                 PEMK::ProofChecks.player_team(@db, @me, team(frame(ok).merge(uid: 2**70)))
  end

  # A trainer record is replayed on its seed row's seed, against the row's trainer -
  # never on what its body says.
  def test_a_record_is_its_seed_row_s_battle
    row = { seed: 77, tr_type: "CAMPER", tr_name: "Liam", tr_version: 0 }
    rec = { mode: "on", seed: 77, trainers: [["CAMPER", "Liam", 0]], kind: "trainer" }
    bound, why = PEMK::ProofChecks.bind_to_seed(rec, 77, row)
    assert_nil why
    assert_equal [77, "on"], bound.values_at(:seed, :mode)
    {
      rec.merge(mode: "shadow")                         => /ran on no seed/,
      rec.merge(kind: "wild")                           => /not a trainer battle's/,
      rec.merge(seed: 78)                               => /another seed/,
      rec.merge(trainers: [["LEADER_Brock", "Brock", 0]]) => /another trainer/,
      rec.merge(trainers: [["CAMPER", "Liam", 0], ["CAMPER", "Liam", 0]]) => /another trainer/
    }.each do |r, want|
      out, reason = PEMK::ProofChecks.bind_to_seed(r, 77, row)
      assert_nil out
      assert_match want, reason
    end
    assert_match(/another seed/, PEMK::ProofChecks.bind_to_seed(rec, 76, row)[1], "the envelope named another")
    assert_equal [[:CAMPER, "Liam", 0]].map { |t| t.map { |v| v.is_a?(Symbol) ? v.to_s : v } },
                 PEMK::ProofChecks.bind_to_seed(rec.merge(trainers: [[:CAMPER, "Liam", 0]]), 77, row)[0][:trainers]
                                  .map { |t| t.map { |v| v.is_a?(Symbol) ? v.to_s : v } }
  end

  # --- claims and verdicts -----------------------------------------------------------

  def seed_row(account, trainer = LIAM, seed: rand(1 << 50) + 1)
    @db[:trainer_battles].insert(account_id: account, map_id: trainer[3], event_id: trainer[4], tr_type: trainer[0],
                                 tr_name: trainer[1], tr_version: trainer[2], seed: seed, issued_at: @now)
    [@db[:trainer_battles].where(seed: seed).get(:id), seed]
  end

  def claim(account, nonce, amount: 176, trainers: [LIAM], at: @now)
    @db[:money_claims].insert(account_id: account, nonce: nonce, kind: "trainer", verdict: "paid", mode: "shadow",
                              amount: amount, accepted: amount, map: 10, trainers: trainers.to_json, created_at: at)
  end

  def record(row, status:, outcome: 1, prize: 176, team: "ok", detail: nil)
    @db[:battle_records].insert(account_id: @me, mode: "on", record: Sequel.blob("x"), outcome: outcome,
                                replay_status: status, trainer_battle_id: row, replay_prize: prize,
                                team_check: team, replay_detail: detail, created_at: @now)
  end

  def verdict(nonce) = @db[:money_claims].where(account_id: @me, nonce: nonce).get(:proof)

  def test_a_claim_is_linked_only_to_its_own_battle
    row, seed = seed_row(@me)
    claim(@me, 1)
    assert_nil @proofs.link_claim(@me, 1, seed, [["CAMPER", "Liam", 0, 10, 3]]), "another event"
    assert_nil @proofs.link_claim(@me, 1, seed + 1, [LIAM]), "another seed"
    assert_nil @proofs.link_claim(@other, 1, seed, [LIAM]), "another account"
    assert_equal row, @proofs.link_claim(@me, 1, seed, [LIAM])
    assert_equal row, @db[:money_claims].where(nonce: 1).get(:trainer_battle_id)
  end

  def linked(nonce, row, seed, **kw)
    claim(@me, nonce, **kw)
    @proofs.link_claim(@me, nonce, seed, kw[:trainers] || [LIAM])
  end

  def test_a_proven_win_spends_the_seed
    row, seed = seed_row(@me)
    linked(1, row, seed)
    record(row, status: "walk_ok")
    assert_empty @proofs.sweep(now: @now), "not replayed yet: no verdict"
    @db[:battle_records].where(trainer_battle_id: row).update(replay_status: "match")
    assert_equal [[@me, 1, :proven, nil]], @proofs.sweep(now: @now)
    assert_equal "proven", verdict(1)
    assert_equal "proven", @db[:trainer_battles].where(id: row).get(:state)
  end

  def test_what_refutes_or_leaves_a_claim_unprovable
    cases = {
      { status: "walk_mismatch" }                      => [:refuted, /draws are not its seed's/],
      { status: "mismatch", detail: "round 2: AI" }     => [:refuted, /the replay disagrees: round 2: AI/],
      { status: "match", team: "refuted", detail: "x" } => [:refuted, /the player's team/],
      { status: "match", prize: 999 }                  => [:refuted, /claimed 176, the replay paid 999/],
      { status: "match", team: "unprovable" }          => [:unprovable, /the player's team/],
      { status: "error" }                              => [:unprovable, /could not be replayed/],
      { status: "not_replayable", detail: "truncated" } => [:unprovable, /could not be replayed \(not_replayable: truncated/],
      { status: "match", prize: nil }                  => [:unprovable, /paid no prize/],
      # a game may edit its trainers as they load: not the player's doing (P4)
      { status: "mismatch", detail: "the trainer is not the game's data: foe team: the game's data has 2, the record 1" } =>
        [:unprovable, /\Athe trainer is not the game's data: foe team/]
    }
    cases.each_with_index do |(rec, (want, why)), i|
      trainer = ["CAMPER", "Liam", 0, 10, 100 + i]          # one open seed per placement: one each
      row, seed = seed_row(@me, trainer)
      linked(i + 1, row, seed, trainers: [trainer])
      record(row, **rec)
      _, _, got, reason = @proofs.sweep(now: @now).find { |_, n, _, _| n == i + 1 }
      assert_equal want, got, rec.inspect
      assert_match why, reason
      # judged without a win: the seed stays (no fresh one for a claim no replay proves),
      # the claim lets the battle go and the record the seed's one win
      assert_equal "open", @db[:trainer_battles].where(id: row).get(:state)
      assert_nil @db[:money_claims].where(nonce: i + 1).get(:trainer_battle_id)
      assert_empty @db[:battle_records].where(trainer_battle_id: row).all
    end
  end

  def test_a_claim_waits_for_its_record_then_is_unrecorded
    row, seed = seed_row(@me)
    linked(1, row, seed, at: @now - 60)
    record(row, status: "match", outcome: 2)             # a lost battle proves no prize
    assert_empty @proofs.sweep(now: @now)
    assert_equal [[@me, 1, :unrecorded, "no record of a won battle on its seed"]], @proofs.sweep(now: @now + 700)
  end

  # P4: the replay daemon's silence is no verdict - the claim waits, and is counted stale.
  def test_a_record_waiting_for_its_replay_gets_no_verdict
    row, seed = seed_row(@me)
    linked(1, row, seed, at: @now - 60)
    record(row, status: "walk_ok")
    assert_empty @proofs.sweep(now: @now)
    assert_equal 0, @proofs.stale
    assert_empty @proofs.sweep(now: @now + 3600), "an hour later: still no verdict"
    assert_equal 1, @proofs.stale
    assert_nil verdict(1)
  end

  # A void landing between the sweep's read and its verdict: the claim stays as the void
  # left it, the seed open.
  def test_a_claim_voided_while_judged_gets_no_verdict
    row, seed = seed_row(@me)
    linked(1, row, seed)
    rec = record(row, status: "match")
    claim = @db[:money_claims].where(nonce: 1).first
    @db[:money_claims].where(nonce: 1).update(voided_at: @now, trainer_battle_id: nil)
    assert_equal false, @proofs.send(:settle, claim, :proven, @db[:battle_records].where(id: rec).first, @now)
    assert_nil verdict(1)
    assert_equal "open", @db[:trainer_battles].where(id: row).get(:state)
  end

  # Judged without a win, the seed stays open and free: the next battle there, won and
  # claimed, is judged on its own record.
  def test_after_an_unprovable_verdict_the_seed_serves_the_next_battle
    row, seed = seed_row(@me)
    linked(1, row, seed)
    record(row, status: "error")
    assert_equal :unprovable, @proofs.sweep(now: @now).first[2]
    assert_equal row, linked(2, row, seed), "the next claim on the seed is linked"
    record(row, status: "match")
    assert_equal [[@me, 2, :proven, nil]], @proofs.sweep(now: @now)
    # a held claim its replay refused is not voided at a fresh login: its battle stays paid for
    row3, seed3 = seed_row(@me, ["CAMPER", "Liam", 0, 10, 99])
    linked(3, row3, seed3, trainers: [["CAMPER", "Liam", 0, 10, 99]])
    @db[:money_claims].where(nonce: 3).update(verdict: "held", proof: "refuted")
    @db[:money_claims].where(nonce: [1, 2]).update(verdict: "held")
    voided = PEMK::MoneyClaims.new(@db).void_unsealed(@me).map { |c| c[:nonce] }.sort
    assert_equal [1, 2], voided
    assert_nil @db[:money_claims].where(nonce: 3).get(:voided_at)
  end

  def test_a_voided_claim_is_not_judged
    row, seed = seed_row(@me)
    linked(1, row, seed)
    record(row, status: "match")
    @db[:money_claims].where(nonce: 1).update(voided_at: @now)
    assert_empty @proofs.sweep(now: @now)
    assert_equal "open", @db[:trainer_battles].where(id: row).get(:state)
  end

  def test_the_seed_row_of_a_claim
    row, seed = seed_row(@me)
    assert_equal row, @proofs.seed_row(@me, seed, [LIAM])[:id]
    assert_nil @proofs.seed_row(@me, seed, [["CAMPER", "Liam", 0, 10, 5]]), "another placement"
    assert_nil @proofs.seed_row(@other, seed, [LIAM]), "another account"
    assert_nil @proofs.seed_row(@me, seed.to_s, [LIAM]), "not a seed"
    assert_nil @proofs.seed_row(@me, seed, [LIAM, LIAM]), "two trainers"
    @db[:trainer_battles].where(id: row).update(state: "proven")
    assert_nil @proofs.seed_row(@me, seed, [LIAM]), "spent"
  end

  # One win, one prize: a seed holds one won battle and one claim (migration 044).
  def test_one_win_proves_one_claim
    row, seed = seed_row(@me)
    assert_equal row, linked(1, row, seed)
    assert_nil linked(2, row, seed), "another claim naming the same battle is not linked"
    record(row, status: "match")
    assert_raises(Sequel::UniqueConstraintViolation) { record(row, status: "match") }   # a copy of the win
    record(row, status: "match", outcome: 2)                                            # a lost attempt: fine
    assert_equal [[@me, 1, :proven, nil]], @proofs.sweep(now: @now)
    assert_nil verdict(2)
    assert_empty @proofs.sweep(now: @now + 700), "the unlinked claim is never judged on it"
    claim(@me, 3)
    assert_nil @proofs.link_claim(@me, 3, seed, [LIAM]), "a spent seed links no claim"
  end

  def test_a_repeatable_trainer_s_claim_is_judged_too
    row, seed = seed_row(@me)
    @db[:money_claims].insert(account_id: @me, nonce: 9, kind: "repeatable", verdict: "paid", mode: "shadow",
                              amount: 176, accepted: 176, map: 10, trainers: [LIAM].to_json, created_at: @now)
    @proofs.link_claim(@me, 9, seed, [LIAM])
    record(row, status: "match")
    assert_equal [[@me, 9, :proven, nil]], @proofs.sweep(now: @now)
  end
end
