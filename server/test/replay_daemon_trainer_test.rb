require "minitest/autorun"
require "sequel"
require "open3"
require "json"

root  = File.expand_path("..", __dir__)
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk_wire"

# Trainer proof P4's review: the replay tool replays a trainer record on its seed row's
# seed and against that row's trainer - never on what the record's body names. A body
# that says it ran on no seed, on another seed, or against another trainer is refuted
# before any replay (the one-shot tool, as an operator runs it; the engine boots in it).
class ReplayDaemonTrainerTest < Minitest::Test
  SERVER_ROOT = File.expand_path("..", __dir__)
  FIXTURE     = File.join(SERVER_ROOT, "test", "fixtures", "battle_records", "trainer_brock_loss.bin")
  W = PEMK::Wire

  def setup
    @game_root = ENV["PEMK_GAME_ROOT"] || File.expand_path("..", SERVER_ROOT)
    unless File.exist?(File.join(@game_root, "Data", "trainers.dat"))
      skip "game Data/*.dat not compiled (launch the game once) - replay tool skipped"
    end
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:battle_records].delete
    @db[:trainer_battles].delete
    @db[:money_claims].delete
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @me = @db[:accounts].insert(email: "daemon@t.co", password_hash: "x", status: "active", created_at: Time.now)
  end

  def teardown
    @db&.disconnect
  end

  def seed_row(seed, event)
    @db[:trainer_battles].insert(account_id: @me, map_id: 10, event_id: event, tr_type: "LEADER_Brock", tr_name: "Brock",
                                 tr_version: 0, seed: seed, issued_at: Time.now)
  end

  def record(row, seed, body)
    @db[:battle_records].insert(account_id: @me, mode: "on", record: Sequel.blob(body), outcome: 2,
                                replay_status: "walk_ok", trainer_battle_id: row, battle_seed: seed, created_at: Time.now)
  end

  def replay(id, extra = {})
    env = { "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "REPLAY_ID" => id.to_s, "PEMK_GAME_ROOT" => @game_root }.merge(extra)
    out, status = Open3.capture2e(env, RbConfig.ruby, "-W0", File.join(SERVER_ROOT, "bin", "pemk_replay.rb"),
                                  chdir: SERVER_ROOT)
    assert status.success?, out
    @out = out
    @db[:battle_records].where(id: id).first
  end

  def test_a_trainer_record_is_replayed_as_its_seed_row_says
    base = W.decode_primitive(File.binread(FIXTURE))
    cases = {
      base                                                         => /the record says it ran on no seed/,
      base.merge(mode: "on", seed: 9999)                           => /another seed than its battle's/,
      base.merge(mode: "on", seed: 1003, trainers: [["CAMPER", "Liam", 0]]) => /another trainer than its seed's/
    }
    cases.each_with_index do |(body, why), i|
      seed = 1001 + i
      id = record(seed_row(seed, 3 + i), seed, W.encode_primitive(body))   # one open seed per placement
      row = replay(id)
      assert_equal "mismatch", row[:replay_status], row[:replay_detail]
      assert_match why, row[:replay_detail]
    end
  end

  # The whole queue, as a pass runs it, with a fault injected on one record.
  def run_tool(fault_id, fault = nil)
    env = { "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "PEMK_GAME_ROOT" => @game_root,
            "REPLAY_FAULT_ID" => fault_id.to_s, "REPLAY_FAULT" => fault.to_s, "PEMK_REPLAY_MARK" => @mark }
    Open3.capture2e(env, RbConfig.ruby, "-W0", File.join(SERVER_ROOT, "bin", "pemk_replay.rb"), chdir: SERVER_ROOT)
  end

  def row(id) = @db[:battle_records].where(id: id).first

  # A record passing every check before the replay (its replay then runs).
  def replayable_body(seed)
    base = W.decode_primitive(File.binread(FIXTURE))
    W.encode_primitive(base.merge(mode: "on", seed: seed, kind: "trainer", trainers: [["LEADER_Brock", "Brock", 0]]))
  end

  # Badge authority B2 (PEMK_BADGE_AUTHORITY=on): a record saying the player had a badge that
  # an earlier win still waiting for its replay gives waits for that win - replayed once the
  # count is decided. With the authority off, no more badges than owned, as P4 had it.
  def test_a_record_waits_for_the_badges_it_counts
    on = { "PEMK_BADGE_AUTHORITY" => "on" }
    win_row = seed_row(2001, 3)   # Brock's placement: the demo's export says his win gives badge 0
    @db[:battle_records].insert(account_id: @me, mode: "on", record: Sequel.blob("x"), outcome: 1, replay_status: "pending",
                                trainer_battle_id: win_row, battle_seed: 2001, created_at: Time.now)
    @db[:money_claims].insert(account_id: @me, nonce: 1, kind: "trainer", verdict: "held", mode: "on", amount: 1400,
                              accepted: 1400, map: 10, trainers: [["LEADER_Brock", "Brock", 0, 10, 3]].to_json,
                              created_at: Time.now, trainer_battle_id: win_row)
    counting = lambda do |seed, event|
      body = W.decode_primitive(replayable_body(seed))
      record(seed_row(seed, event), seed, W.encode_primitive(body.merge(init: body[:init].merge(badges: 1))))
    end
    id = counting.(2002, 4)
    assert_equal "walk_ok", replay(id, on)[:replay_status], "no verdict yet"
    assert_match(/##{id}: waits - 1 badges in the record, the server knows 0, 1 more wait for their replay/, @out)
    refute_equal "walk_ok", replay(id)[:replay_status], "the authority off: nothing waits (no more than owned, P4)"
    @db[:money_claims].where(nonce: 1).update(proof: "proven")   # its win proven: the badge owned
    @db[:economy_balances].insert(account_id: @me, field: "badges", balance: 0b1, last_seq: 0)
    refute_equal "walk_ok", replay(counting.(2003, 5), on)[:replay_status], "the badge owned: replayed"
  end

  # No record stops the tool: one it fails on is stored as an error (its prize
  # unprovable) and the next is replayed. The database away is no record's fault: the
  # pass stops, the record waits. One the tool died on (no Ruby error to catch) is an
  # error at the next boot, never replayed first again.
  def test_a_record_the_tool_fails_on_stops_nothing
    @mark = File.join(Dir.tmpdir, "pemk_replay_test_#{Process.pid}.mark")
    shadow = W.encode_primitive(W.decode_primitive(File.binread(FIXTURE)))
    failing = record(seed_row(2001, 9), 2001, shadow)
    after   = record(seed_row(2002, 10), 2002, shadow)
    normal  = record(seed_row(2004, 12), 2004, replayable_body(2004))   # marked, replayed, unmarked
    out, status = run_tool(failing)
    assert status.success?, out
    assert_equal "error", row(failing)[:replay_status]
    assert_match(/the replay tool failed on this record \(RuntimeError\)/, row(failing)[:replay_detail])
    assert_equal "mismatch", row(after)[:replay_status], "the next one is replayed"
    refute_equal "walk_ok", row(normal)[:replay_status]
    refute File.exist?(@mark), "no record left marked after a pass"

    away = record(seed_row(2003, 11), 2003, replayable_body(2003))
    _, status = run_tool(away, "db")
    refute status.success?, "the pass stops"
    assert_equal "walk_ok", row(away)[:replay_status], "the record waits for the next pass"
    refute File.exist?(@mark)

    _, status = run_tool(away, "die")
    refute status.success?
    assert_equal away, File.read(@mark).to_i, "the record it died on is marked"
    out, status = run_tool(0)
    assert status.success?, out
    assert_equal ["error", "the replay tool died replaying this record"], row(away).values_at(:replay_status, :replay_detail)
    refute File.exist?(@mark)
  ensure
    File.delete(@mark) if @mark && File.exist?(@mark)
  end

  # A record a verdict let go of, replayed again: still on its seed row's seed, against
  # its trainer (found by the seed it named).
  def test_a_record_let_go_is_still_its_seed_s_battle
    @mark = File.join(Dir.tmpdir, "pemk_replay_test_#{Process.pid}.mark")
    shadow = W.encode_primitive(W.decode_primitive(File.binread(FIXTURE)))
    seed_row(4001, 14)
    id = @db[:battle_records].insert(account_id: @me, mode: "on", record: Sequel.blob(shadow), outcome: 2,
                                     replay_status: "walk_ok", battle_seed: 4001, created_at: Time.now)
    out, status = run_tool(0)
    assert status.success?, out
    assert_equal "mismatch", row(id)[:replay_status]
    assert_match(/the record says it ran on no seed/, row(id)[:replay_detail])
  ensure
    File.delete(@mark) if @mark && File.exist?(@mark)
  end

  # A team no game fields is refuted before any replay; a uid past any id is no Pokemon
  # the server has (not a database error).
  def test_a_team_no_game_fields
    base = W.decode_primitive(File.binread(FIXTURE))
    on = base.merge(mode: "on", kind: "trainer", trainers: [["LEADER_Brock", "Brock", 0]])
    twice = on.merge(seed: 3001, init: base[:init].merge(player: [base[:init][:player][0].merge(uid: 5)] * 2))
    row = replay(record(seed_row(3001, 12), 3001, W.encode_primitive(twice)))
    assert_equal "mismatch", row[:replay_status]
    assert_match(/one Pokemon twice in the player.s team/, row[:replay_detail])
    big = on.merge(seed: 3002, init: base[:init].merge(player: base[:init][:player].first(1).map { |f| f.merge(uid: 2**70) }))
    row = replay(record(seed_row(3002, 13), 3002, W.encode_primitive(big)))
    refute_equal "error", row[:replay_status], row[:replay_detail]
  end
end
