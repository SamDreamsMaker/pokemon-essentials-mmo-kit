require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# M4 Layer C one-shot pickup ledger: the first pickup of a tile is :new, a repeat is
# :dup, keyed per account+tile.
class PickupsTest < Minitest::Test
  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:pickups].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete   # cascades to pickups
    @a  = @db[:accounts].insert(email: "pk-a@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @b  = @db[:accounts].insert(email: "pk-b@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @pk = PEMK::Pickups.new(@db)
  end

  def teardown
    @db&.disconnect
  end

  def test_first_is_new_repeat_is_dup
    assert_equal :new, @pk.record(@a, 5, 12, 8)
    assert_equal :dup, @pk.record(@a, 5, 12, 8)
    assert_equal :dup, @pk.record(@a, 5, 12, 8)
  end

  def test_a_different_tile_is_new
    assert_equal :new, @pk.record(@a, 5, 12, 8)
    assert_equal :new, @pk.record(@a, 5, 12, 9)   # same map, different y
    assert_equal :new, @pk.record(@a, 6, 12, 8)   # different map
  end

  def test_keyed_per_account
    assert_equal :new, @pk.record(@a, 5, 12, 8)
    assert_equal :new, @pk.record(@b, 5, 12, 8)   # another account taking the same tile is new
    assert_equal :dup, @pk.record(@a, 5, 12, 8)
  end

  def test_taken_predicate
    refute @pk.taken?(@a, 5, 12, 8)
    @pk.record(@a, 5, 12, 8)
    assert @pk.taken?(@a, 5, 12, 8)
    refute @pk.taken?(@b, 5, 12, 8)
  end

  # Dev/QA reset: clear() forgets ONLY this account's tiles, reports the row count, and
  # leaves the tiles re-pickable (:new again); a second clear is a no-op (0 rows).
  def test_clear_forgets_only_this_account
    @pk.record(@a, 5, 12, 8)
    @pk.record(@a, 5, 12, 9)
    @pk.record(@b, 5, 12, 8)

    assert_equal 2, @pk.clear(@a)          # both of A's rows, not B's
    refute @pk.taken?(@a, 5, 12, 8)
    refute @pk.taken?(@a, 5, 12, 9)
    assert @pk.taken?(@b, 5, 12, 8)        # B untouched
    assert_equal :new, @pk.record(@a, 5, 12, 8)   # re-pickable after the wipe
    assert_equal 0, @pk.clear(999_999)             # nonexistent account -> 0 rows
  end
end
