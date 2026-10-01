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

# Badge authority B2 (docs/BADGE-AUTHORITY-DESIGN.md) over the wire: under enforcement a
# frame never moves the badges - the answer is what the client shows, its owned badges and
# those its wins waiting for their replay will give - and a proven win grants its badges in
# its proof's own transaction. The boot pass makes each ledger what the server owns.
class ServerBadgeEnforceTest < Minitest::Test
  W = PEMK::Wire

  WORLD = Tempfile.new(["pemk_world", ".json"])
  WORLD.write(JSON.generate(
    "schema_version" => 3, "trainer_marks" => true, "partners" => { "list" => [], "computed" => false },
    "maps" => {
      "31" => { "name" => "Gym", "width" => 20, "height" => 20, "objects" => [], "trainers" => [
        { "event_id" => 7, "x" => 2, "y" => 2, "type" => "LASS", "name" => "Anna", "version" => 0, "calls" => [0] },
        { "event_id" => 8, "x" => 3, "y" => 2, "type" => "CAMPER", "name" => "Liam", "version" => 0, "calls" => [0] }
      ] }
    },
    "badge_sources" => { "list" => [
      { "badge" => 0, "map" => 31, "event" => 7, "page" => 0, "trainers" => [["LASS", "Anna", 0]], "call" => 0 },
      { "badge" => 1, "map" => 31, "event" => 8, "page" => 0, "trainers" => [["CAMPER", "Liam", 0]], "call" => 0 }
    ], "unknown" => [] }
  ))
  WORLD.flush

  BATTLE = Tempfile.new(["pemk_battle", ".json"])
  src = JSON.parse(File.read(File.expand_path("../data/battle_data.json", __dir__)))
  src["trainer_types"] = { "LASS" => { "base_money" => 20 }, "CAMPER" => { "base_money" => 16 } }
  src["trainers"] = [
    { "type" => "LASS", "name" => "Anna", "version" => 0, "party" => [["RATTATA", 20, nil, %w[TACKLE]]] },
    { "type" => "CAMPER", "name" => "Liam", "version" => 0, "party" => [["SANDSHREW", 11, nil, %w[SCRATCH]]] }
  ]
  BATTLE.write(JSON.generate(src))
  BATTLE.flush

  ANNA = ["LASS", "Anna", 0, 31, 7].freeze
  LIAM = ["CAMPER", "Liam", 0, 31, 8].freeze
  CAPS = %w[money_claims trainer_proof save_ack badge_hold].freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[money_claims money_payouts money_shadow money_daily battle_records trainer_battles encounter_rolls economy_ledger
       economy_balances inventory_snapshots party_snapshots monster_transfers monsters enforcement_events player_flags
       badge_baselines badge_grants badge_cutover].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  # +enforce+: as if trainer proof and money enforced (a fixture clears none of their
  # preconditions)
  def start_server(extra = {}, enforce: true)
    env = ENV.to_h.merge("PEMK_WORLD" => WORLD.path, "PEMK_BATTLE_DATA" => BATTLE.path, "PEMK_MONEY_AUTHORITY" => "on",
                         "PEMK_BATTLE_ENFORCE_RNG" => "on", "PEMK_TRAINER_PROOF" => "on", "PEMK_BADGE_AUTHORITY" => "on",
                         "PEMK_ANOMALY_DETECTION" => "on").merge(extra)
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
    return unless enforce

    @server.instance_variable_set(:@money_enforce, true)
    @server.instance_variable_set(:@trainer_enforce, true)
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
      flunk "no log #{pattern.inspect} within #{timeout}s:\n#{logs.grep(/badge/).join("\n")}" if Time.now > deadline
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

  def login(email = "badge@t.co", caps: CAPS)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :register, email: email, password: "password1" })
    recv_type(s, :register_ok, :register_err)
    send_env(s, { type: :login, email: email, password: "password1", caps: caps })
    lo = recv_type(s, :login_ok, :login_err)
    send_env(s, { type: :pos, map: 31, x: 5, y: 5, dir: 2 }) if lo[:type] == :login_ok
    [s, lo]
  end

  def record_frame(seed, rec_nonce)
    prng = PEMK::Prng.new(seed, PEMK::Prng::STREAM_BATTLE)
    log = [100, 16].map { |b| [b, prng.rand_below(b)] }.flatten.pack("N*")
    h = 0xcbf29ce484222325
    log.each_byte { |b| h = ((h ^ b) * 0x100000001b3) & ((1 << 64) - 1) }
    body = W.encode_primitive({ v: 1, kind: "trainer", truncated: false,
                                draws: { b: { n: 2, fp: format("%016x", h), log: log },
                                         a: { n: 0, fp: "0" * 16, log: "".b }, r: { n: 0, fp: "0" * 16, log: "".b } } })
    [{ type: :battle_record, mode: "on", engine_fp: "ab" * 8, outcome: 1, rounds: 2, draws_battle: 2, draws_ai: 0,
       draws_run: 0, fp_battle: format("%016x", h), fp_ai: "0" * 16, fp_run: "0" * 16, truncated: false,
       desynced: false, battle_seed: seed, rec_nonce: rec_nonce }, body]
  end

  # A won battle with +trainer+: its seed, its record, its prize claimed (held) -> the seed
  def won(s, trainer, nonce, amount)
    send_env(s, { type: :trainer_battle_req, nonce: nonce, trainers: [trainer] })
    seed = recv_type(s, :trainer_battle_seed)[:seed]
    send_env(s, *record_frame(seed, 100 + nonce))
    recv_type(s, :battle_record_ack)
    ack = nil
    send_env(s, { type: :money_claim, nonce: nonce, trainers: [trainer], amount: amount, map: 31, seed: seed })
    ack = recv_type(s, :money_claim_ack)
    assert_equal "held", ack[:verdict]
    seed
  end

  def replayed(seed, status: "match", prize: 400)
    row = @db[:trainer_battles].where(seed: seed).get(:id)
    @db[:battle_records].where(trainer_battle_id: row, outcome: 1)
                        .update(replay_status: status, replay_prize: prize, team_check: "ok")
    @server.instance_variable_set(:@last_proof_sweep, nil)
  end

  def badges(s, mask, seq)
    send_env(s, { type: :econ, field: :badges, value: mask, seq: seq })
    recv_type(s, :econ_ack, :econ_rej)
  end

  def owned(lo) = @db[:economy_balances].where(account_id: lo[:account_id], field: "badges").get(:balance).to_i

  def test_a_client_that_cannot_hold_its_badge_frame_must_update
    start_server
    _, lo = login(caps: CAPS - ["badge_hold"])
    assert_equal [:login_err, "update_required"], lo.values_at(:type, :reason)
  end

  # An honest win: its badge shown at once (pending), owned once its replay proves it.
  def test_a_win_shows_its_badge_then_owns_it
    start_server
    s, lo = login
    sd = won(s, ANNA, 1, 400)
    assert_equal [:econ_ack, 0b1], badges(s, 0b1, 1).values_at(:type, :value), "shown while its replay is to come"
    assert_equal 0, owned(lo), "not owned yet"
    assert_equal [:econ_rej, 0b1], badges(s, 0b11, 2).values_at(:type, :value), "a badge no win gives: not shown"
    assert_equal [:econ_rej, 0b1], badges(s, 0, 3).values_at(:type, :value), "a stale save's 0 drops nothing"
    assert_equal [:econ_rej, 0b1], badges(s, 0b11, 2).values_at(:type, :value), "a frame again: the same answer"
    assert_equal 0, owned(lo)
    wait_log(/account #{lo[:account_id]} badge 1 REFUSED: no win over CAMPER Liam was claimed/)
    replayed(sd)
    wait_log(/account #{lo[:account_id]} GRANTED badge 0 \(claim 1's win is proven\)/)
    assert_equal 0b1, owned(lo)
    assert_equal [[0, "proof", 1]], @db[:badge_grants].where(account_id: lo[:account_id]).select_map(%i[badge evidence claim_nonce])
    assert_equal [:econ_ack, 0b1], badges(s, 0b1, 4).values_at(:type, :value)
    s.close
    _, lo2 = login
    assert_equal 0b1, lo2[:econ][:badges], "a relogin shows what it owns"
  end

  # Login shows what the client should: owned and pending, and the badges always (0 too).
  def test_login_shows_owned_and_pending
    start_server
    _, fresh = login("fresh@t.co")
    assert_equal 0, fresh[:econ][:badges], "an account with no badges row: 0, named"
    s, lo = login
    won(s, ANNA, 1, 400)
    s.close
    _, again = login   # a fresh login: no save named the claim - voided, its badge with it
    assert_equal 0, again[:econ][:badges], "a claim no save sealed: void, nothing pending"
    wait_log(/account #{lo[:account_id]} DROPPED badge 0 \(claim 1 is void/)
    s, = login
    won(s, ANNA, 2, 400)
    @db[:money_claims].where(account_id: lo[:account_id], nonce: 2).update(sealed_at: Time.now)   # its save named it
    s.close
    _, again = login
    assert_equal 0b1, again[:econ][:badges], "its win waiting for its replay: shown"
    assert_equal 0, owned(lo)
  end

  # A made-up win: pending until its replay refutes it, then gone from what it shows.
  def test_a_refuted_win_drops_its_badge
    start_server
    s, lo = login
    sd = won(s, ANNA, 1, 400)
    assert_equal 0b1, badges(s, 0b1, 1)[:value]
    replayed(sd, status: "mismatch")
    wait_log(/account #{lo[:account_id]} DROPPED badge 0 \(claim 1's win is refuted/)
    assert_equal [:econ_rej, 0], badges(s, 0b1, 2).values_at(:type, :value)
    assert_equal 0, owned(lo)
    assert_empty @db[:badge_grants].all
  end

  # A win no replay could prove (the server's side) drops the badge it showed - no flag for
  # it: its next frame says UNPROVABLE, the one sign that counts.
  def test_an_unreplayable_win_drops_its_badge_unflagged
    start_server
    s, lo = login
    sd = won(s, ANNA, 1, 400)
    assert_equal 0b1, badges(s, 0b1, 1)[:value]
    replayed(sd, status: "error")
    wait_log(/account #{lo[:account_id]} DROPPED badge 0 \(claim 1's win is unprovable/)
    sleep 0.3
    assert_empty @db[:player_flags].where(account_id: lo[:account_id]).all
  end

  # No badge frame raises the ledger, whatever it says.
  def test_a_frame_never_raises_the_badges
    start_server
    s, lo = login
    assert_equal [:econ_rej, 0], badges(s, (1 << 62) - 1, 1).values_at(:type, :value)
    assert_equal 0, owned(lo)
    assert_equal 0, login("badge@t.co")[1][:econ][:badges], "login names the badges, 0 too"
  end

  # What keeps the server from owning the badges (a set the export cannot read): `on`
  # runs as shadow - the frame applies as it did, nothing is held.
  def test_on_with_a_blocker_runs_as_shadow
    blocked = Tempfile.new(["pemk_world", ".json"])
    doc = JSON.parse(File.read(WORLD.path))
    doc["badge_sources"]["unknown"] = [{ "map" => 3, "event" => 7, "page" => 0, "script" => "$player.badges[i] = true" }]
    blocked.write(JSON.generate(doc))
    blocked.flush
    start_server({ "PEMK_WORLD" => blocked.path })
    s, lo = login(caps: CAPS - ["badge_hold"])
    assert_equal :login_ok, lo[:type], "no client must update"
    assert_equal [:econ_ack, 0b11], badges(s, 0b11, 1).values_at(:type, :value)
    assert_equal 0b11, owned(lo)
    refute @server.send(:badge_enforce?), "trainer proof and money enforce, the blocker stands"
  ensure
    blocked&.close!
  end

  def put_badges(id, mask) = @db[:economy_balances].insert(account_id: id, field: "badges", balance: mask, last_seq: 0)

  def account(email) = @db[:accounts].insert(email: email, password_hash: "x", status: "active", created_at: Time.now)

  def proven_claim(id, trainer, nonce, voided: false)
    @db[:money_claims].insert(account_id: id, nonce: nonce, kind: "trainer", verdict: "paid", mode: "on", amount: 400,
                              accepted: 400, map: 31, trainers: [trainer].to_json, created_at: Time.now, proof: "proven",
                              voided_at: voided ? Time.now : nil)
  end

  # The boot pass: each ledger becomes what the server owns.
  def test_the_boot_pass
    a = account("a@t.co")   # never judged: all it holds is legacy at the cutover
    put_badges(a, 0b11)
    b = account("b@t.co")   # its baseline: badge 0; its proven win over Liam: badge 1; badge 2 from nowhere
    put_badges(b, 0b111)
    @db[:badge_baselines].insert(account_id: b, mask: 0b1, taken_at: Time.now)
    proven_claim(b, LIAM, 5, voided: true)
    c = account("c@t.co")   # granted badge 1, lost in a period the authority was off
    @db[:badge_grants].insert(account_id: c, badge: 1, evidence: "operator", granted_at: Time.now)
    start_server({}, enforce: false)
    assert(logs.any? { |l| l.include?("(dry run) boot pass (the cutover): 3 account(s)") }, "a shadow boot only says it")
    assert_equal 0b11, @db[:economy_balances].where(account_id: a, field: "badges").get(:balance)

    @server.instance_variable_set(:@money_enforce, true)
    @server.instance_variable_set(:@trainer_enforce, true)
    @server.send(:badge_boot_pass)
    held = ->(id) { @db[:economy_balances].where(account_id: id, field: "badges").get(:balance).to_i }
    grants = ->(id) { @db[:badge_grants].where(account_id: id).order(:badge).select_map(%i[badge evidence]) }
    assert_equal [0b11, 0b11, 0b10], [held.(a), held.(b), held.(c)]
    assert_equal [[0, "legacy"], [1, "legacy"]], grants.(a)
    assert_equal [[0, "legacy"], [1, "proof"]], grants.(b)
    assert_equal [[1, "operator"]], grants.(c)
    assert(logs.any? { |l| l.include?("boot account #{b}: owns 0, 1; legacy 0; proven 1 (claim 5); removed 2 (nothing the exports read gives it)") })
    assert_equal 1, @db[:player_flags].where(account_id: b, kind: "badge_unexplained").get(:count)
    refute @db[:badge_cutover].empty?

    d = account("d@t.co")   # a badge gained while the authority was off, after the cutover
    put_badges(d, 0b1)
    audit = @server.instance_variable_get(:@badge_audit)
    real = audit.method(:plan)
    planned = []
    audit.define_singleton_method(:plan) { |id, held, cutover:| planned << id; real.(id, held, cutover: cutover) }
    @server.send(:badge_boot_pass)
    assert_equal [d], planned, "after the cutover: only an account whose ledger is not its grants"
    assert_equal 0, held.(d), "after the cutover, nothing is legacy"
    assert(logs.any? { |l| l.include?("boot pass: 1 account(s)") }, "the others own what they hold already")
    assert_nil @db[:player_flags].where(account_id: d).get(:count), "a period off trusted the clients: no sign"

    g = account("g@t.co")   # an operator's grant lands between the pass's plan and its write: it stays
    put_badges(g, 0b11)
    audit.define_singleton_method(:plan) do |id, held, cutover:|   # (self: the audit - @db, its database)
      out = real.(id, held, cutover: cutover)
      PEMK::Ledger.new(@db, {}).grant_bits(id, 0b10, reason: "operator", grants: [{ badge: 1, evidence: "operator" }]) if id == g
      out
    end
    @server.send(:badge_boot_pass)
    assert_equal 0b10, held.(g), "badge 0 removed, badge 1 granted meanwhile kept"

    e = account("e@t.co")   # an account the pass fails on keeps what it holds; the pass is done again
    put_badges(e, 0b11)
    put_badges(account("f@t.co"), 0b1)
    audit.define_singleton_method(:plan) { |id, held, cutover:| id == e ? raise("a fault") : real.(id, held, cutover: cutover) }
    pass_at = @db[:badge_cutover].get(:pass_at)
    @server.send(:badge_boot_pass)
    assert_equal 0b11, held.(e)
    assert_equal 0, held.(@db[:accounts].where(email: "f@t.co").get(:id)), "the others judged"
    assert(logs.any? { |l| l.include?("the boot pass skipped account #{e}: RuntimeError: a fault") })
    assert_equal pass_at, @db[:badge_cutover].get(:pass_at), "not a whole pass"
  end
end
