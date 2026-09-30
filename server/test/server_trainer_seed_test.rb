require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"
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

# Trainer proof P2 (docs/TRAINER-PROOF-DESIGN.md): under battle rng `on` a trainer battle
# asks for its seed. The placement must be one the export knows, on the player's map; the
# answer is that placement's open seed, the same however often it is asked, so no seed
# can be shopped for. A record on it is bound and walked, attempt after attempt.
class ServerTrainerSeedTest < Minitest::Test
  W = PEMK::Wire

  FIXTURE = Tempfile.new(["pemk_world", ".json"])
  FIXTURE.write(JSON.generate(
    "schema_version" => 3, "trainer_marks" => true,
    "maps" => { "10" => { "name" => "Gym", "width" => 20, "height" => 20, "objects" => [],
                          "trainers" => [
                            { "event_id" => 4, "x" => 5, "y" => 5, "type" => "CAMPER", "name" => "Liam", "version" => 0 },
                            { "event_id" => 3, "x" => 6, "y" => 1, "type" => "LEADER_Brock", "name" => "Brock",
                              "version" => 0 },
                            # a double battle: one call names both
                            { "event_id" => 7, "x" => 8, "y" => 8, "type" => "LASS", "name" => "Amy", "version" => 0,
                              "calls" => [0] },
                            { "event_id" => 7, "x" => 9, "y" => 8, "type" => "LASS", "name" => "May", "version" => 0,
                              "calls" => [0] }
                          ] },
                "5" => { "name" => "Route", "width" => 20, "height" => 20, "objects" => [] } }
  ))
  FIXTURE.flush
  LIAM  = ["CAMPER", "Liam", 0, 10, 4].freeze
  BROCK = ["LEADER_Brock", "Brock", 0, 10, 3].freeze
  TWIN_A = ["LASS", "Amy", 0, 10, 7].freeze

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:battle_records].delete rescue nil
    @db[:trainer_battles].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @logs = []
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(rng: "on", env: {})
    env = ENV.to_h.merge("PEMK_WORLD" => FIXTURE.path, "PEMK_BATTLE_ENFORCE_RNG" => rng).merge(env)
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
  end

  def send_env(sock, env, body = nil); sock.write(W.encode_split(env, body)); end

  def recv(sock, timeout = 5)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)[:env]
    end
  end

  def authed_conn(email, map: 10)
    c = TCPSocket.new("127.0.0.1", @port)
    send_env(c, { type: :register, email: email, password: "password1" }); recv(c)
    send_env(c, { type: :login, email: email, password: "password1" })
    login = recv(c)
    send_env(c, { type: :pos, map: map, x: 5, y: 6 })
    [c, login]
  end

  def ask(c, trainer, nonce = 1)
    send_env(c, { type: :trainer_battle_req, nonce: nonce, trainers: [trainer] })
    recv(c)
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    loop do
      v = yield
      return v if v
      flunk "condition not met within #{timeout}s" if Time.now > deadline
      sleep 0.05
    end
  end

  def test_one_placement_one_seed
    start_server
    c, login = authed_conn("ts1@t.co")
    assert_equal true, login[:trainer_seed], "the login says to ask"
    assert_equal false, login[:record_ack], "trainer proof off: no record kept for it"
    first = ask(c, LIAM, 7)
    assert_equal [:trainer_battle_seed, 7], [first[:type], first[:nonce]]
    assert_kind_of Integer, first[:seed]
    assert_equal first[:seed], ask(c, LIAM, 8)[:seed], "asked again: the same seed"
    refute_equal first[:seed], ask(c, BROCK)[:seed], "another placement: its own"
    assert_equal 2, @db[:trainer_battles].count
    c.close
  end

  def test_what_is_denied
    start_server
    c, = authed_conn("ts2@t.co", map: 5)
    assert_equal [:trainer_battle_deny, "not_here"], ask(c, LIAM).values_at(:type, :reason)
    send_env(c, { type: :pos, map: 10, x: 5, y: 5 })
    assert_equal "unknown", ask(c, ["CAMPER", "Nobody", 0, 10, 4])[:reason]
    assert_equal "unknown", ask(c, ["CAMPER", "Liam", 0, 10, 3])[:reason], "Liam is not on event 3"
    assert_equal "bad", ask(c, ["CAMPER", "Liam", "0", 10, 4])[:reason]
    send_env(c, { type: :trainer_battle_req, nonce: 1, trainers: [LIAM, BROCK] })
    assert_equal "bad", recv(c)[:reason], "one trainer at a time (P2)"
    assert_equal 0, @db[:trainer_battles].count
    c.close

    @server.stop
    start_server(rng: "shadow")
    c, login = authed_conn("ts3@t.co")
    assert_equal false, login[:trainer_seed]
    assert_equal "off", ask(c, LIAM)[:reason]
    c.close
  end

  def test_a_new_seed_after_a_win_or_a_day
    start_server
    c, = authed_conn("ts4@t.co")
    seed = ask(c, LIAM)[:seed]
    @db[:trainer_battles].where(seed: seed).update(state: "proven")   # a win proven on it (P3)
    won = ask(c, LIAM)[:seed]
    refute_equal seed, won
    @db[:trainer_battles].where(seed: won).update(issued_at: Time.now - (25 * 3600))
    later = ask(c, LIAM)[:seed]
    refute_equal won, later, "a day later: expired"
    assert_equal "expired", @db[:trainer_battles].where(seed: won).get(:state)
    c.close
  end

  # --- records on the seed -------------------------------------------------------

  def walk_body(seed, bounds, outcome: 1)
    prng = PEMK::Prng.new(seed, PEMK::Prng::STREAM_BATTLE)
    log = bounds.map { |b| [b, prng.rand_below(b)] }.flatten.pack("N*")
    h = 0xcbf29ce484222325
    log.each_byte { |b| h = ((h ^ b) * 0x100000001b3) & ((1 << 64) - 1) }
    body = W.encode_primitive({ v: 1, kind: "trainer", truncated: false,
                                draws: { b: { n: bounds.size, fp: format("%016x", h), log: log },
                                         a: { n: 0, fp: "0" * 16, log: "".b },
                                         r: { n: 0, fp: "0" * 16, log: "".b } } })
    env = { type: :battle_record, mode: "on", engine_fp: "ab" * 8, outcome: outcome, rounds: 2,
            draws_battle: bounds.size, draws_ai: 0, draws_run: 0, fp_battle: format("%016x", h),
            fp_ai: "0" * 16, fp_run: "0" * 16, truncated: false, desynced: false, battle_seed: seed }
    [env, body]
  end

  # P3: the prize claim names its battle's seed; once the record is replayed, the claim
  # gets the verdict and a proven win spends the placement's seed.
  def test_a_claim_on_the_seed_gets_the_replay_s_verdict
    start_server(env: { "PEMK_MONEY_AUTHORITY" => "shadow", "PEMK_TRAINER_PROOF" => "shadow" })
    c, = authed_conn("ts6@t.co")
    seed = ask(c, LIAM)[:seed]
    row = @db[:trainer_battles].where(seed: seed).get(:id)
    send_env(c, *walk_body(seed, [100, 16]))
    rec = wait_for { @db[:battle_records].first }
    send_env(c, { type: :money_claim, nonce: 41, amount: 176, amulet: false, happy_hour: false, map: 10,
                  trainers: [LIAM], seed: seed })
    wait_for { @db[:money_claims].where(nonce: 41).get(:trainer_battle_id) == row }
    # the replay tool's verdict, as it writes it
    @db[:battle_records].where(id: rec[:id]).update(replay_status: "match", replay_prize: 176, team_check: "ok")
    @server.instance_variable_set(:@last_proof_sweep, nil)
    wait_for { @db[:money_claims].where(nonce: 41).get(:proof) == "proven" }
    assert(@logs.any? { |l| l.include?("claim 41 PROVEN") }, @logs.grep(/trainerproof/).inspect)
    assert_equal "proven", @db[:trainer_battles].where(id: row).get(:state)
    refute_equal seed, ask(c, LIAM)[:seed], "the next battle here gets a new seed"
    c.close
  end

  # P2 as it was, P4 as a switch: with trainer proof off, a claim on the seed is judged as
  # M1 judges it and linked to nothing.
  def test_trainer_proof_off_links_nothing
    start_server(env: { "PEMK_MONEY_AUTHORITY" => "shadow" })
    c, = authed_conn("ts8@t.co")
    seed = ask(c, LIAM)[:seed]
    send_env(c, { type: :money_claim, nonce: 42, amount: 176, amulet: false, happy_hour: false, map: 10,
                  trainers: [LIAM], seed: seed })
    wait_for { @db[:money_claims].where(nonce: 42).get(:verdict) }
    assert_nil @db[:money_claims].where(nonce: 42).get(:trainer_battle_id)
    assert(@logs.any? { |l| l.include?("server: trainer proof = off") }, @logs.grep(/trainer proof/).inspect)
    c.close
  end

  # P4: a battle this trainer may share with another is never seeded.
  def test_a_trainer_that_shares_a_battle_gets_no_seed
    start_server(env: { "PEMK_MONEY_AUTHORITY" => "shadow", "PEMK_TRAINER_PROOF" => "shadow" })
    c, = authed_conn("ts9@t.co")
    assert_equal "unprovable", ask(c, TWIN_A)[:reason]
    assert_kind_of Integer, ask(c, LIAM)[:seed], "one alone in its battle: seeded"
    c.close
    @server.stop
    start_server   # trainer proof off: P2 as it was
    c, = authed_conn("ts10@t.co")
    assert_kind_of Integer, ask(c, TWIN_A)[:seed]
    c.close
  end

  def test_each_attempt_on_the_seed_is_bound_and_walked
    start_server
    c, = authed_conn("ts5@t.co")
    seed = ask(c, LIAM)[:seed]
    row = @db[:trainer_battles].where(seed: seed).get(:id)
    send_env(c, *walk_body(seed, [100, 16, 2], outcome: 2))     # an attempt, lost
    send_env(c, *walk_body(seed, [100, 16, 2, 4]))              # another, on the same seed, won
    recs = wait_for { (r = @db[:battle_records].order(:id).all).size == 2 && r }
    assert_equal [row, row], recs.map { |r| r[:trainer_battle_id] }
    assert_equal %w[walk_ok walk_ok], recs.map { |r| r[:replay_status] }
    # won again with no claim on the first win: the seed's one win is the new one (P4)
    send_env(c, *walk_body(seed, [100, 16, 2, 4]))
    wait_for { @db[:battle_records].count == 3 }
    assert_equal [row, nil, row], @db[:battle_records].order(:id).select_map(:trainer_battle_id)
    # ... but a win a claim holds keeps its place: another is a copy, dropped
    @db[:money_claims].insert(account_id: @db[:trainer_battles].where(id: row).get(:account_id), nonce: 1, kind: "trainer",
                              verdict: "held", mode: "on", amount: 176, accepted: 176, map: 10,
                              trainers: [LIAM].to_json, trainer_battle_id: row, created_at: Time.now)
    send_env(c, *walk_body(seed, [100, 16, 2, 4]))
    wait_for { @logs.any? { |l| l.include?("duplicate record for the won battle on trainer seed #{row}") } }
    env, body = walk_body(seed, [100, 16], outcome: 2)
    rec = W.decode_primitive(body)
    rec[:draws][:b][:log] = [100, 0, 16, 0].pack("N*")            # the same bounds, values the seed never gave
    send_env(c, env, W.encode_primitive(rec))
    bad = wait_for { @db[:battle_records].count == 4 && @db[:battle_records].order(:id).last }
    assert_equal "walk_mismatch", bad[:replay_status]
    c.close
  end

  def test_a_spent_seed_binds_no_more_battles
    start_server
    c, = authed_conn("ts7@t.co")
    seed = ask(c, LIAM)[:seed]
    @db[:trainer_battles].where(seed: seed).update(state: "proven")
    send_env(c, *walk_body(seed, [100, 16], outcome: 2))
    rec = wait_for { @db[:battle_records].first }
    assert_nil rec[:trainer_battle_id], "an old seed's record binds nothing"
    c.close
  end
end
