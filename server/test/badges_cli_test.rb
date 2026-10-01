require "minitest/autorun"
require "open3"
require "rbconfig"
require "sequel"
require "json"
require "tempfile"

# The operator's badge console (bin/pemk_badges.rb), run as the operator runs it: a grant
# is the server's own (owned, with its reason); `unowned` lists the wins that own no badge
# - an honest player's battle begun offline among them.
class BadgesCliTest < Minitest::Test
  CLI = File.expand_path("../bin/pemk_badges.rb", __dir__)

  WORLD = Tempfile.new(["pemk_world", ".json"])
  WORLD.write(JSON.generate(
    "schema_version" => 3, "trainer_marks" => true,
    "maps" => { "10" => { "name" => "Gym", "width" => 20, "height" => 20, "objects" => [] } },
    "badge_sources" => { "list" => [{ "badge" => 0, "map" => 10, "event" => 3, "page" => 0,
                                      "trainers" => [["LEADER_Brock", "Brock", 0]] }], "unknown" => [] }
  ))
  WORLD.flush

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    %i[money_claims battle_records trainer_battles monster_transfers monsters enforcement_events].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @id = @db[:accounts].insert(email: "gym@t.co", password_hash: "x", status: "active", created_at: Time.now)
  end

  def teardown
    @db&.disconnect
  end

  def badges(*args)
    out, status = Open3.capture2e({ "PEMK_OPERATOR" => "tester", "PEMK_WORLD" => WORLD.path }, RbConfig.ruby, CLI,
                                  *args.map(&:to_s), chdir: File.expand_path("..", __dir__))
    [out, status.success?]
  end

  def test_grant_and_list
    out, ok = badges("grant", "gym@t.co", 2, "battle begun offline")
    assert ok, out
    assert_match(/granted badge 2 to account #{@id} \(gym@t\.co\) - it owns 2/, out)
    assert_equal 0b100, @db[:economy_balances].where(account_id: @id, field: "badges").get(:balance)
    assert_equal [[2, "operator", "tester: battle begun offline"]],
                 @db[:badge_grants].where(account_id: @id).select_map(%i[badge evidence source])
    out, = badges("list", @id)
    assert_match(/owns 2; pending none; shown 2/, out)
    assert_match(/badge 2: operator tester: battle begun offline/, out)
    out, ok = badges("grant", @id, 63)
    refute ok, "past the cap"
    assert_match(/name a badge: 0 to 62/, out)
  end

  def test_unowned
    @db[:money_claims].insert(account_id: @id, nonce: 7, kind: "trainer", verdict: "allowance", mode: "on", amount: 1400,
                              accepted: 1400, map: 10, trainers: [["LEADER_Brock", "Brock", 0, 10, 3]].to_json,
                              created_at: Time.now)
    out, ok = badges("unowned")
    assert ok, out
    assert_match(/account #{@id} claim 7 .*: badge 0 - claimed with no seed \(bin\/pemk_badges\.rb grant #{@id} 0/, out)
    assert_match(/1 win\(s\) owning no badge/, out)
    badges("grant", @id, 0)
    assert_match(/0 win\(s\) owning no badge/, badges("unowned", "gym@t.co").first, "owned now")
  end
end
