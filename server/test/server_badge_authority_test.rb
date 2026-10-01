require "minitest/autorun"
require "socket"
require "timeout"
require "json"
require "tempfile"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# Badge authority B1 over the wire (shadow): each badge a client's frame adds is judged
# by the battle that gives it and logged - explained, pending, unprovable, or what
# enforcement would refuse - and a proof sweep says which badges a win would grant or
# drop. Nothing is refused yet.
class ServerBadgeAuthorityTest < Minitest::Test
  W = PEMK::Wire
  BROCK = ["LEADER_Brock", "Brock", 0, 10, 3].freeze

  def self.world(badge_sources)
    file = Tempfile.new(["pemk_world", ".json"])
    file.write(JSON.generate(
      "schema_version" => 3, "trainer_marks" => true, "partners" => { "list" => [], "computed" => false },
      "maps" => { "10" => { "name" => "Gym", "width" => 20, "height" => 20, "objects" => [],
                            "trainers" => [{ "event_id" => 3, "x" => 6, "y" => 5, "type" => "LEADER_Brock",
                                             "name" => "Brock", "version" => 0, "calls" => [0] }] } },
      "badge_sources" => badge_sources
    ))
    file.flush
    file
  end

  BROCK_SOURCE = { "badge" => 0, "map" => 10, "event" => 3, "page" => 0, "trainers" => [["LEADER_Brock", "Brock", 0]] }.freeze
  # Brock's badge, and nothing else: the server could own every badge.
  OWNED = world("list" => [BROCK_SOURCE], "unknown" => [])
  # ... with a badge given by talking and a set the export cannot read (the demo's house).
  BLOCKED = world("list" => [BROCK_SOURCE, { "badge" => 1, "map" => 3, "event" => 7, "page" => 0 }],
                  "unknown" => [{ "map" => 3, "event" => 7, "page" => 0, "script" => "$player.badges[i] = true" }])

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[money_claims money_payouts money_shadow battle_records trainer_battles economy_ledger economy_balances
       monster_transfers monsters enforcement_events player_flags badge_baselines].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(extra = {}, world: OWNED)
    env = ENV.to_h.merge("PEMK_WORLD" => world.path, "PEMK_MONEY_AUTHORITY" => "shadow", "PEMK_BADGE_AUTHORITY" => "shadow",
                         "PEMK_BATTLE_ENFORCE_RNG" => "on", "PEMK_TRAINER_PROOF" => "shadow",
                         "PEMK_ANOMALY_DETECTION" => "on").merge(extra)
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
  end

  def logs
    @seen ||= []
    @seen << @logs.pop until @logs.empty?
    @seen
  end

  def wait_log(pattern, timeout = 5)
    deadline = Time.now + timeout
    loop do
      return true if logs.any? { |l| l.match?(pattern) }
      flunk "no log #{pattern.inspect} within #{timeout}s:\n#{logs.grep(/badge|trainerproof/).join("\n")}" if Time.now > deadline
      sleep 0.05
    end
  end

  def send_env(s, e, body = nil) = s.write(W.encode_split(e, body))

  def recv_type(s, *types)
    Timeout.timeout(5) do
      loop do
        h = s.read(4)
        return nil if h.nil?

        env = W.decode_envelope(s.read(h.unpack1("N")), false)[:env]
        return env if types.include?(env[:type])
      end
    end
  end

  # +caps+: what the client says it can do ("trainer_proof": it asks its battles' seeds)
  def login(email, caps: nil)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :register, email: email, password: "password1" })
    recv_type(s, :register_ok, :register_err)
    send_env(s, { type: :login, email: email, password: "password1", caps: caps }.compact)
    lo = recv_type(s, :login_ok)
    send_env(s, { type: :pos, map: 10, x: 6, y: 6, dir: 8 })
    [s, lo]
  end

  def badges(s, mask, seq)
    send_env(s, { type: :econ, field: :badges, value: mask, seq: seq })
    recv_type(s, :econ_ack, :econ_rej)
  end

  def flags(kind = "badge_unexplained") = @db[:player_flags].where(kind: kind).select_map(%i[account_id count])

  def test_each_new_badge_is_judged
    start_server
    assert(logs.any? { |l| l.include?("badge authority = shadow (each new badge judged") })
    refute(logs.any? { |l| l.include?("badge authority cannot own") }, "nothing keeps the server from owning them")
    refute(logs.any? { |l| l.include?("boot pass") }, "a shadow boot runs no pass over the accounts")
    s, lo = login("b1@t.co")
    id = lo[:account_id]
    badges(s, 0b11, 1)
    wait_log(/account #{id} badge 0 WOULD-REFUSE: no win over LEADER_Brock Brock was claimed/)
    wait_log(/account #{id} badge 1 WOULD-REFUSE: nothing the exports read gives it/)
    assert_equal 0b11, @db[:economy_balances].where(account_id: id, field: "badges").get(:balance), "shadow refuses nothing"
    assert_equal 0, @db[:badge_baselines].where(account_id: id).get(:mask), "what it held before its first judged frame"
    Timeout.timeout(5) { sleep 0.05 until flags == [[id, 1]] }   # one flag a frame
    badges(s, 0b111, 1)   # its seq again: the ledger's answer stands, nothing is judged
    badges(s, 0b11, 2)
    badges(s, (1 << 4000) - 1, 3)   # over the cap: the ledger refuses it, nothing is judged
    badges(s, -1, 4)
    assert_equal :econ_rej, badges(s, 0b111, 0)[:type], "a bad seq: the ledger refuses it, nothing is judged"
    assert_equal :econ_rej, badges(s, 0b111, "5")[:type]
    badges(s, 0b11100, 5)
    wait_log(/account #{id} badges 2, 3, 4 WOULD-REFUSE: nothing the exports read gives it/)   # one line, not three
    badges(s, 0, 6)       # the mask sent back and forth: what was said is not said again
    badges(s, 0b11100, 7)
    sleep 0.2
    assert_equal 3, logs.count { |l| l.include?("account #{id} badge") }, "nothing else is judged"
    Timeout.timeout(5) { sleep 0.05 until flags == [[id, 2]] }
    assert_equal 0, @db[:badge_baselines].where(account_id: id).get(:mask), "the first baseline stays"
  end

  # With what the server cannot own (a badge given by talking, a set the export cannot
  # read), a refusal is no sign: the game may give it. Logged, never flagged.
  def test_what_the_server_cannot_own_flags_no_one
    start_server(world: BLOCKED)
    assert(logs.any? { |l| l.include?("badge authority cannot own:") && l.include?("badge 1 is given with no battle") })
    s, lo = login("b6@t.co")
    id = lo[:account_id]
    badges(s, 0b11, 1)
    wait_log(/account #{id} badge 0 WOULD-REFUSE: no win over LEADER_Brock Brock was claimed/)
    wait_log(/account #{id} badge 1 WOULD-REFUSE: no battle gives it/)
    sleep 0.3
    assert_empty flags
  end

  def walk_body(seed)
    prng = PEMK::Prng.new(seed, PEMK::Prng::STREAM_BATTLE)
    log = [100, 16].map { |b| [b, prng.rand_below(b)] }.flatten.pack("N*")
    h = 0xcbf29ce484222325
    log.each_byte { |b| h = ((h ^ b) * 0x100000001b3) & ((1 << 64) - 1) }
    body = W.encode_primitive({ v: 1, kind: "trainer", truncated: false,
                                draws: { b: { n: 2, fp: format("%016x", h), log: log },
                                         a: { n: 0, fp: "0" * 16, log: "".b }, r: { n: 0, fp: "0" * 16, log: "".b } } })
    [{ type: :battle_record, mode: "on", engine_fp: "ab" * 8, outcome: 1, rounds: 2, draws_battle: 2, draws_ai: 0,
       draws_run: 0, fp_battle: format("%016x", h), fp_ai: "0" * 16, fp_run: "0" * 16, truncated: false,
       desynced: false, battle_seed: seed }, body]
  end

  # A won battle with Brock, its record sent, its prize claimed -> its trainer_battles row.
  def won_claim(s, nonce)
    send_env(s, { type: :trainer_battle_req, nonce: nonce, trainers: [BROCK] })
    seed = recv_type(s, :trainer_battle_seed)[:seed]
    send_env(s, *walk_body(seed))
    send_env(s, { type: :money_claim, nonce: nonce, amount: 1400, amulet: false, happy_hour: false, map: 10,
                  trainers: [BROCK], seed: seed })
    recv_type(s, :money_claim_ack)
    @db[:trainer_battles].where(seed: seed).get(:id)
  end

  def replayed(row, status)
    @db[:battle_records].where(trainer_battle_id: row, outcome: 1)
                        .update(replay_status: status, replay_prize: 1400, team_check: "ok")
  end

  # A win over Brock: pending while its replay is to come, granted once it is proven -
  # a refuted one grants nothing, and drops the badge it showed.
  def test_a_proven_win_explains_its_badge
    start_server
    s, lo = login("b2@t.co")
    id = lo[:account_id]
    row = won_claim(s, 9)
    badges(s, 0b1, 1)
    wait_log(/account #{id} badge 0 PENDING: the win over LEADER_Brock Brock waits for its replay/)
    s2, lo2 = login("b3@t.co")
    id2 = lo2[:account_id]
    row2 = won_claim(s2, 9)
    badges(s2, 0b1, 1)
    wait_log(/account #{id2} badge 0 PENDING/)
    replayed(row, "match")
    replayed(row2, "walk_mismatch")
    @server.instance_variable_set(:@last_proof_sweep, nil)
    wait_log(/account #{id} WOULD-GRANT badge 0 \(claim 9's win is proven\)/)
    wait_log(/trainerproof: account #{id2} claim 9 WOULD-HOLD \(refuted\)/)
    wait_log(/account #{id2} WOULD-DROP badge 0 \(claim 9's win is refuted: the win over LEADER_Brock Brock is refuted\)/)
    refute(logs.any? { |l| l.include?("account #{id2} WOULD-GRANT") }, "a refuted win grants nothing")
    row10 = won_claim(s, 10)   # Brock again: a battle made up, refuted - the badge stays proven
    @db[:money_claims].where(account_id: id, nonce: 10).update(verdict: "paid")   # (a claim that pays)
    replayed(row10, "walk_mismatch")
    @server.instance_variable_set(:@last_proof_sweep, nil)
    wait_log(/trainerproof: account #{id} claim 10 WOULD-HOLD \(refuted\)/)
    sleep 0.3
    badges(s, 0b1, 2)   # a frame after it on the mailbox: the sweep's badges are judged by then
    refute(logs.any? { |l| l.include?("account #{id} WOULD-DROP") }, "a badge its proven win explains drops not")
    s3, lo3 = login("b4@t.co")
    @db[:money_claims].where(account_id: id, nonce: 9).update(account_id: lo3[:account_id])   # the proven win, another's
    badges(s3, 0b1, 1)
    wait_log(/account #{lo3[:account_id]} badge 0 EXPLAINED: the win over LEADER_Brock Brock is proven/)
    sleep 0.2
    assert_equal [[id2, 1]], flags, "a badge pending or explained flags no one - one its refuted win dropped does"
  end

  # A claim a fresh login voids (its client killed before its save) takes the badge its win
  # showed - an honest client's too, so no one is flagged.
  def test_a_void_drops_the_badge_its_claim_showed
    start_server
    s, lo = login("b9@t.co")
    id = lo[:account_id]
    won_claim(s, 9)
    badges(s, 0b1, 1)
    wait_log(/account #{id} badge 0 PENDING/)
    s.close
    login("b9@t.co")   # a fresh login: the claim no save sealed is void
    wait_log(/account #{id} WOULD-DROP badge 0 \(claim 9 is void: no win over LEADER_Brock Brock was claimed\)/)
    sleep 0.2
    assert_empty flags
  end

  # What an account held before the badge authority judged it is legacy (B2's cutover):
  # a frame dropping one of those bits and giving it back is not judged.
  def test_what_was_held_before_is_not_judged
    start_server
    s, lo = login("b10@t.co")
    id = lo[:account_id]
    @db[:economy_balances].insert(account_id: id, field: "badges", balance: 0b1, last_seq: 0)
    badges(s, 0b11, 1)
    wait_log(/account #{id} badge 1 WOULD-REFUSE/)
    assert_equal 0b1, @db[:badge_baselines].where(account_id: id).get(:mask)
    badges(s, 0b10, 2)   # a stale session's mask, without it
    badges(s, 0b11, 3)   # ... and it back
    won_claim(s, 9)      # Brock fought again, and the claim voided: the badge held before stays
    s.close
    login("b10@t.co")
    wait_log(/money: account #{id} voided 1 unsealed prize claim/)
    sleep 0.2
    assert_empty logs.grep(/account #{id} (badge 0|WOULD-DROP badge 0)/), "a bit of the baseline is never judged"
  end

  # A claim and no record (the claim voided at each fresh login, its seed claimed again):
  # no battle was won on the seed.
  def test_a_claim_with_no_record_explains_nothing
    start_server
    s, lo = login("b7@t.co")
    id = lo[:account_id]
    send_env(s, { type: :trainer_battle_req, nonce: 1, trainers: [BROCK] })
    seed = recv_type(s, :trainer_battle_seed)[:seed]
    send_env(s, { type: :money_claim, nonce: 1, amount: 1400, amulet: false, happy_hour: false, map: 10,
                  trainers: [BROCK], seed: seed })
    recv_type(s, :money_claim_ack)
    badges(s, 0b1, 1)
    wait_log(/account #{id} badge 0 WAITING: the win over LEADER_Brock Brock has no record yet/)
    send_env(s, *walk_body(seed))   # its record comes: the badge it holds is not judged again
    sleep 0.3
    badges(s, 0b11, 2)
    wait_log(/account #{id} badge 1 WOULD-REFUSE/)
    refute(logs.any? { |l| l.include?("account #{id} badge 0 PENDING") }, "only what a frame adds is judged")
  end

  # A win claimed with no seed (the client was offline as it began, or its seed came
  # late): no replay can prove it. A client that asks for its battles' seeds is flagged
  # for it (twice opens a review); an older one never asks.
  def test_a_win_claimed_with_no_seed_is_unprovable
    start_server
    ids = [nil, %w[trainer_proof]].each_with_index.map do |caps, i|
      s, lo = login("b8#{i}@t.co", caps: caps)
      send_env(s, { type: :money_claim, nonce: 1, amount: 1400, amulet: false, happy_hour: false, map: 10,
                    trainers: [BROCK] })
      recv_type(s, :money_claim_ack)
      badges(s, 0b1, 1)
      wait_log(/account #{lo[:account_id]} badge 0 UNPROVABLE: the win over LEADER_Brock Brock was claimed with no seed/)
      lo[:account_id]
    end
    Timeout.timeout(5) { sleep 0.05 until flags("badge_unprovable") == [[ids[1], 1]] }
    assert_empty flags
  end

  def test_off_judges_nothing
    start_server({ "PEMK_BADGE_AUTHORITY" => "off" })
    assert(logs.any? { |l| l.include?("badge authority = off (nothing is judged)") })
    s, = login("b5@t.co")
    badges(s, 0b11, 1)
    sleep 0.2
    assert_empty logs.grep(/\Abadge:/)
    assert_empty @db[:badge_baselines].all
  end

  def test_without_claims_it_does_nothing
    start_server({ "PEMK_MONEY_AUTHORITY" => "off" })
    assert(logs.any? { |l| l.include?("WARNING badge authority does nothing") })
  end

  def test_without_trainer_proof_nothing_is_explained
    start_server({ "PEMK_TRAINER_PROOF" => "off" })
    assert(logs.any? { |l| l.include?("WARNING badge authority: no trainer proof") })
  end
end
