require "minitest/autorun"
require "sequel"
require "open3"

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

  def replay(id)
    env = { "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "REPLAY_ID" => id.to_s, "PEMK_GAME_ROOT" => @game_root }
    out, status = Open3.capture2e(env, RbConfig.ruby, "-W0", File.join(SERVER_ROOT, "bin", "pemk_replay.rb"),
                                  chdir: SERVER_ROOT)
    assert status.success?, out
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

  # No record stops the tool: one it fails on is stored as an error (its prize
  # unprovable), and the others are replayed.
  def test_a_record_the_tool_fails_on_stops_nothing
    base = W.decode_primitive(File.binread(FIXTURE))
    init = base[:init].merge(player: base[:init][:player].map { |f| f.merge(uid: 2**70) })   # past any id
    body = base.merge(mode: "on", seed: 2001, kind: "trainer", trainers: [["LEADER_Brock", "Brock", 0]], init: init)
    id = record(seed_row(2001, 9), 2001, W.encode_primitive(body))
    row = replay(id)
    assert_equal "error", row[:replay_status]
    assert_match(/the replay tool failed on this record/, row[:replay_detail])
  end
end
