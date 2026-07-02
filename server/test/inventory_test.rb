require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"   # full load -> DB.connect installs the pg_json extension

# Server-side bag record, DETECTION-ONLY: absolute {item_id=>qty} snapshot, jsonb
# whole-object write, high-water seq dedup, structural FLAG-not-reject validation.
class InventoryTest < Minitest::Test
  CAPS = { per_item: 99_999, distinct: 2000, total: 10_000_000 }.freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:accounts].delete   # cascades to inventory_snapshots
    @acct = @db[:accounts].insert(email: "inv@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @logs = []
    @inv  = PEMK::Inventory.new(@db, CAPS, logger: ->(m) { @logs << m })
  end

  def teardown
    @db&.disconnect
  end

  def row
    @db[:inventory_snapshots].where(account_id: @acct).first
  end

  def test_fresh_account_inserts_the_bag
    status = @inv.apply_inv(@acct, { POTION: 5, GREAT_BALL: 12 }, 1)
    assert_equal :ack, status[0]
    assert_empty status[1]
    r = row
    assert_equal({ "POTION" => 5, "GREAT_BALL" => 12 }, r[:bag])   # jsonb keys are strings
    assert_equal 2, r[:distinct_items]
    assert_equal 17, r[:total_qty]
    assert_equal false, r[:flagged]
    assert_equal 1, r[:last_seq]
  end

  def test_second_snapshot_replaces_the_whole_bag
    @inv.apply_inv(@acct, { POTION: 5, GREAT_BALL: 12 }, 1)
    @inv.apply_inv(@acct, { POTION: 3 }, 2)   # GREAT_BALL absent -> gone (whole-object write, no delete bookkeeping)
    assert_equal({ "POTION" => 3 }, row[:bag])
    assert_equal 1, row[:distinct_items]
    assert_equal 3, row[:total_qty]
  end

  def test_dup_and_stale_seq_do_not_mutate
    @inv.apply_inv(@acct, { POTION: 5 }, 3)
    assert_equal [:dup, []], @inv.apply_inv(@acct, { POTION: 999 }, 3)   # == last_seq
    assert_equal [:dup, []], @inv.apply_inv(@acct, { POTION: 999 }, 2)   # <  last_seq
    assert_equal({ "POTION" => 5 }, row[:bag])
    assert_equal 3, row[:last_seq]
  end

  def test_empty_bag_is_clean
    status = @inv.apply_inv(@acct, {}, 1)
    assert_equal :ack, status[0]
    assert_empty status[1]
    assert_equal false, row[:flagged]
    assert_equal 0, row[:distinct_items]
    assert_equal 0, row[:total_qty]
  end

  def test_bad_shape_rejected_and_not_written
    assert_equal [:rej, ["bad_shape"]], @inv.apply_inv(@acct, "notahash", 1)
    assert_equal [:rej, ["bad_shape"]], @inv.apply_inv(@acct, { POTION: 1 }, "notaseq")
    assert_nil row
  end

  def test_validate_flags_are_recorded_but_still_written
    status = @inv.apply_inv(@acct, { POTION: -5, MASTER_BALL: 200_000 }, 1)
    assert_equal :ack, status[0]
    assert_includes status[1], "bad_qty"
    assert_includes status[1], "over_item_cap"
    r = row
    assert_equal true, r[:flagged]
    assert_includes r[:flags], "bad_qty"      # adopted even when flagged, or the record drifts
  end

  def test_validate_bounds
    assert_empty @inv.validate({ POTION: 5, GREAT_BALL: 99_999 })
    assert_includes @inv.validate({ POTION: 100_000 }), "over_item_cap"
    assert_includes @inv.validate({ POTION: 10_000_001 }), "over_total"
    big = {}
    2001.times { |i| big[:"ITEM_#{i}"] = 1 }
    assert_includes @inv.validate(big), "too_many_items"
  end

  def test_snapshot_returns_bag_and_last_seq
    snap0 = @inv.snapshot(@acct)
    assert_nil snap0[:bag]              # unseeded (no row) -> nil: client keeps its blob bag
    assert_equal 0, snap0[:last_seq]
    @inv.apply_inv(@acct, { POTION: 5, GREAT_BALL: 2 }, 7)
    snap = @inv.snapshot(@acct)
    assert_equal({ POTION: 5, GREAT_BALL: 2 }, snap[:bag])   # symbolized for the client applier
    assert_equal 7, snap[:last_seq]
  end

  def test_snapshot_of_seeded_empty_bag_is_empty_not_nil
    @inv.apply_inv(@acct, {}, 1)
    assert_equal({}, @inv.snapshot(@acct)[:bag])   # seeded empty IS authoritative (overwrites), unlike unseeded nil
  end

  def test_oversized_bag_is_not_shipped_in_login_snapshot
    big = {}
    3000.times { |i| big[:"VERY_LONG_ITEM_NAME_NUMBER_#{i}"] = 1 }   # bytes exceed SHIP_MAX_BYTES
    @inv.apply_inv(@acct, big, 1)
    snap = @inv.snapshot(@acct)
    assert_nil snap[:bag]           # too big to ride login_ok -> nil (client keeps its blob bag, no login brick)
    assert_equal 1, snap[:last_seq] # seq still advances (the record exists)
  end

  def test_material_divergence_is_logged
    @inv.apply_inv(@acct, { POTION: 1 }, 1)
    incoming = { POTION: 1 }
    10.times { |i| incoming[:"NEW_#{i}"] = 1 }   # +10 appeared -> material >= DIVERGENCE_MIN(8)
    @inv.apply_inv(@acct, incoming, 2)
    assert(@logs.any? { |m| m.include?("divergence") }, "expected a coarse divergence log line")
  end
end
