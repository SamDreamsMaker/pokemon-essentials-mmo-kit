require "minitest/autorun"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/audit"   # DB-free detection-only sink — no full pemk load / no Postgres

# M4 Layer A detection-only audit: verdict = compare a client interaction claim to
# the read-only world model. LOG a mismatch, never reject/reply/mutate.
class AuditTest < Minitest::Test
  # Minimal read-model stub so this stays a pure unit (no filesystem / no WorldData).
  class FakeWorld
    def initialize(objects: {}, empty: false)
      @objects = objects                                   # [map,x,y] => {"item"=>...}
      @maps    = @objects.keys.map { |k| k[0] }.uniq
      @empty   = empty
    end

    def empty?;              @empty;                        end
    def map_known?(map_id);  @maps.include?(map_id);        end
    def object_at(m, x, y);  @objects[[m, x, y]];           end
  end

  def setup
    @logs   = []
    @logger = ->(m) { @logs << m }
  end

  def audit(world)
    PEMK::Audit.new(world, logger: @logger)
  end

  def claim(map:, x:, y:, item:, kind: :item, px: 12, py: 9)
    { type: :interact_claim, map: map, x: x, y: y, item: item, kind: kind, px: px, py: py }
  end

  def world_with_potion
    FakeWorld.new(objects: { [5, 12, 8] => { "kind" => "item", "item" => "POTION" } })
  end

  def test_matching_claim_is_silent
    assert_equal :match, audit(world_with_potion).check_interaction(42, claim(map: 5, x: 12, y: 8, item: :POTION))
    assert_empty @logs, "a legitimate pickup must not log"
  end

  # --- M4 Layer C: interaction distance (server-tracked position) --------------

  def test_pickup_while_standing_on_the_item_is_match
    v = audit(world_with_potion).check_interaction(42, claim(map: 5, x: 12, y: 8, item: :POTION), [5, 12, 8])
    assert_equal :match, v
    assert_empty @logs
  end

  def test_pickup_adjacent_to_the_player_is_match
    v = audit(world_with_potion).check_interaction(42, claim(map: 5, x: 12, y: 8, item: :POTION), [5, 12, 7])
    assert_equal :match, v
    assert_empty @logs
  end

  def test_pickup_far_from_the_player_is_too_far
    v = audit(world_with_potion).check_interaction(42, claim(map: 5, x: 12, y: 8, item: :POTION), [5, 1, 1])
    assert_equal :too_far, v
    assert(@logs.any? { |m| m.include?("too_far") && m.include?("server_pos=(5,1,1)") })
  end

  def test_pickup_on_a_different_map_than_the_player_is_too_far
    v = audit(world_with_potion).check_interaction(42, claim(map: 5, x: 12, y: 8, item: :POTION), [9, 12, 8])
    assert_equal :too_far, v
  end

  def test_distance_check_skipped_without_server_position
    # No server position (nil) -> distance not judged -> falls back to the L-A verdict.
    v = audit(world_with_potion).check_interaction(42, claim(map: 5, x: 12, y: 8, item: :POTION), nil)
    assert_equal :match, v
    assert_empty @logs
  end

  def test_wrong_item_takes_priority_over_distance
    # A non-matching item is a mismatch regardless of reach (distance only gates a match).
    v = audit(world_with_potion).check_interaction(42, claim(map: 5, x: 12, y: 8, item: :MASTER_BALL), [5, 1, 1])
    assert_equal :item_mismatch, v
  end

  def test_wrong_item_is_a_logged_mismatch
    v = audit(world_with_potion).check_interaction(42, claim(map: 5, x: 12, y: 8, item: :MASTER_BALL))
    assert_equal :item_mismatch, v
    assert(@logs.any? { |m| m.include?("item_mismatch") && m.include?("account 42") })
  end

  def test_empty_tile_is_no_object
    v = audit(world_with_potion).check_interaction(42, claim(map: 5, x: 1, y: 1, item: :POTION))
    assert_equal :no_object, v
    assert(@logs.any? { |m| m.include?("no_object") })
  end

  def test_unexported_map_is_unknown_map
    v = audit(world_with_potion).check_interaction(42, claim(map: 999, x: 0, y: 0, item: :POTION))
    assert_equal :unknown_map, v
    assert(@logs.any? { |m| m.include?("unknown_map") })
  end

  def test_no_export_yet_is_unchecked_and_silent
    v = audit(FakeWorld.new(empty: true)).check_interaction(42, claim(map: 5, x: 12, y: 8, item: :POTION))
    assert_equal :unchecked, v
    assert_empty @logs, "with no world exported there is nothing to flag"
  end

  def test_malformed_primitives_are_bad_and_silent
    v = audit(world_with_potion).check_interaction(42, claim(map: "5", x: 12, y: 8, item: :POTION))
    assert_equal :bad, v
    assert_empty @logs, "a malformed frame is not a cheat signal"
  end

  def test_never_replies_or_raises_on_garbage
    # A wildly malformed env must return a symbol, not raise (it runs on the reactor thread).
    assert_equal :bad, audit(world_with_potion).check_interaction(42, {})
  end

  def test_client_supplied_fields_are_truncated_in_the_log
    huge = "X" * 5000   # a malicious client could send a giant :item / :px string
    v = audit(world_with_potion).check_interaction(42, claim(map: 5, x: 12, y: 8, item: huge))
    assert_equal :item_mismatch, v
    line = @logs.find { |m| m.include?("item_mismatch") }
    assert line
    refute line.include?("X" * 33), "client-supplied fields must be truncated before logging"
  end
end
