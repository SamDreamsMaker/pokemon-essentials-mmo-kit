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

# Trainer proof P4 (docs/TRAINER-PROOF-DESIGN.md) over the wire: under enforcement a
# trainer prize is held until its battle's replay proves it, and the client's next ask
# pays it. A prize no replay can prove for a cause on the server's side comes from the
# day's small allowance; one that drops or swaps its battle's seed, or whose replay
# refutes it, is refused.
class ServerTrainerEnforceTest < Minitest::Test
  W = PEMK::Wire

  WORLD = Tempfile.new(["pemk_world", ".json"])
  WORLD.write(JSON.generate(
    "schema_version" => 3,
    "trainer_marks" => true,
    "partners" => { "list" => [["POKEMONTRAINER", "May", 0]], "computed" => false },
    "maps" => {
      "31" => { "name" => "Route", "width" => 20, "height" => 20, "objects" => [], "trainers" => [
        { "event_id" => 7, "x" => 2, "y" => 2, "type" => "LASS", "name" => "Anna", "version" => 0, "calls" => [0] },
        { "event_id" => 8, "x" => 3, "y" => 2, "type" => "CAMPER", "name" => "Liam", "version" => 0, "calls" => [0] },
        { "event_id" => 23, "x" => 8, "y" => 8, "type" => "TWINS", "name" => "Amy", "version" => 0, "calls" => [0] },
        { "event_id" => 23, "x" => 8, "y" => 8, "type" => "TWINS", "name" => "May", "version" => 0, "calls" => [0] }
      ] }
    }
  ))
  WORLD.flush

  BATTLE = Tempfile.new(["pemk_battle", ".json"])
  src = JSON.parse(File.read(File.expand_path("../data/battle_data.json", __dir__)))
  src["trainer_types"] = { "LASS" => { "base_money" => 20 }, "CAMPER" => { "base_money" => 16 },
                           "TWINS" => { "base_money" => 16 } }
  src["trainers"] = [
    { "type" => "LASS", "name" => "Anna", "version" => 0, "party" => [["RATTATA", 20, nil, %w[TACKLE]]] },
    { "type" => "CAMPER", "name" => "Liam", "version" => 0, "party" => [["SANDSHREW", 11, nil, %w[SCRATCH]]] },
    { "type" => "TWINS", "name" => "Amy", "version" => 0, "party" => [["PLUSLE", 10, nil, %w[SPARK]]] },
    { "type" => "TWINS", "name" => "May", "version" => 0, "party" => [["MINUN", 10, nil, %w[SPARK]]] },
    { "type" => "POKEMONTRAINER", "name" => "May", "version" => 0, "party" => [["TORCHIC", 10, "AMULETCOIN", %w[EMBER]]] }
  ]
  BATTLE.write(JSON.generate(src))
  BATTLE.flush

  ANNA  = ["LASS", "Anna", 0, 31, 7].freeze
  LIAM  = ["CAMPER", "Liam", 0, 31, 8].freeze
  TWINS = [["TWINS", "Amy", 0, 31, 23], ["TWINS", "May", 0, 31, 23]].freeze
  CAPS  = %w[money_claims trainer_proof save_ack].freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[money_claims money_payouts money_shadow money_daily battle_records trainer_battles encounter_rolls economy_ledger
       economy_balances inventory_snapshots party_snapshots monster_transfers monsters enforcement_events player_flags].each do |t|
      @db[t].delete rescue nil
    end
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(extra = {})
    env = ENV.to_h.merge("PEMK_WORLD" => WORLD.path, "PEMK_BATTLE_DATA" => BATTLE.path, "PEMK_MONEY_AUTHORITY" => "on",
                         "PEMK_BATTLE_ENFORCE_RNG" => "on", "PEMK_TRAINER_PROOF" => "on",
                         "PEMK_ANOMALY_DETECTION" => "on").merge(extra)   # flags counted (player_flags)
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
    # a fixture clears none of M3's preconditions: enforce as if they were met
    @server.instance_variable_set(:@money_enforce, true)
    @server.instance_variable_set(:@trainer_enforce, true)
  end

  def logs
    out = []
    out << @logs.pop until @logs.empty?
    out
  end

  def send_env(s, e, body = nil)
    s.write(W.encode_split(e, body))
  end

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

  def login(email = "enf@t.co", caps: CAPS)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :register, email: email, password: "password1" })
    recv_type(s, :register_ok, :register_err)
    send_env(s, { type: :login, email: email, password: "password1", caps: caps })
    lo = recv_type(s, :login_ok, :login_err)
    send_env(s, { type: :pos, map: 31, x: 5, y: 5, dir: 2 }) if lo[:type] == :login_ok
    [s, lo]
  end

  def seed(s, trainer)
    send_env(s, { type: :trainer_battle_req, nonce: 1, trainers: [trainer] })
    recv_type(s, :trainer_battle_seed, :trainer_battle_deny)
  end

  def claim(s, nonce, trainers, amount, **facts)
    send_env(s, { type: :money_claim, nonce: nonce, trainers: trainers, amount: amount, map: 31 }.merge(facts))
    recv_type(s, :money_claim_ack)
  end

  # A won battle's record on +seed+, as the client sends it (the seed walk passes).
  def record(s, seed, rec_nonce, outcome: 1)
    send_env(s, *record_frame(seed, rec_nonce, outcome: outcome))
    recv_type(s, :battle_record_ack)
  end

  def record_frame(seed, rec_nonce, outcome: 1)
    prng = PEMK::Prng.new(seed, PEMK::Prng::STREAM_BATTLE)
    bounds = [100, 16]
    log = bounds.map { |b| [b, prng.rand_below(b)] }.flatten.pack("N*")
    h = 0xcbf29ce484222325
    log.each_byte { |b| h = ((h ^ b) * 0x100000001b3) & ((1 << 64) - 1) }
    body = W.encode_primitive({ v: 1, kind: "trainer", truncated: false,
                                draws: { b: { n: 2, fp: format("%016x", h), log: log },
                                         a: { n: 0, fp: "0" * 16, log: "".b }, r: { n: 0, fp: "0" * 16, log: "".b } } })
    [{ type: :battle_record, mode: "on", engine_fp: "ab" * 8, outcome: outcome, rounds: 2, draws_battle: 2,
       draws_ai: 0, draws_run: 0, fp_battle: format("%016x", h), fp_ai: "0" * 16, fp_run: "0" * 16,
       truncated: false, desynced: false, battle_seed: seed, rec_nonce: rec_nonce }, body]
  end

  # The replay daemon's verdict on the won record of +seed+, as it writes it; then a sweep.
  def replayed(seed, status: "match", prize: 400, team: "ok", detail: nil)
    row = @db[:trainer_battles].where(seed: seed).get(:id)
    @db[:battle_records].where(trainer_battle_id: row, outcome: 1)
                        .update(replay_status: status, replay_prize: prize, team_check: team, replay_detail: detail)
    @server.instance_variable_set(:@last_proof_sweep, nil)
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    loop do
      v = yield
      return v if v
      return nil if Time.now > deadline

      sleep 0.05
    end
  end

  def claim_row(lo, nonce) = @db[:money_claims].where(account_id: lo[:account_id], nonce: nonce).first
  def balance(lo) = @db[:economy_balances].where(account_id: lo[:account_id], field: "money").get(:balance).to_i
  def keys(lo) = @db[:money_payouts].where(account_id: lo[:account_id]).select_map(:key).sort

  def test_a_proven_prize_is_held_then_paid_at_the_next_ask
    start_server
    s, lo = login
    before = balance(lo)
    sd = seed(s, ANNA)[:seed]
    assert_equal sd.class, Integer
    assert_equal 77, record(s, sd, 77)[:rec_nonce], "the record is acknowledged"
    assert_equal ["held", 0], claim(s, 1, [ANNA], 400, seed: sd).values_at(:verdict, :accepted)
    row = claim_row(lo, 1)
    assert_equal ["held", 400, 0], row.values_at(:verdict, :accepted, :credited), "its would-be pay kept"
    assert_equal ["event:31:7", "trainer:LASS:Anna:0"], keys(lo), "its battle's keys reserved"
    assert_equal before, balance(lo), "nothing paid yet"
    assert_equal ["held", 0], claim(s, 1, [ANNA], 400, seed: sd).values_at(:verdict, :accepted), "asked again: still held"

    replayed(sd)
    assert_equal 1, recv_type(s, :money_claim_ready)[:nonce], "the client is told to ask again"
    r = claim(s, 1, [ANNA], 400, seed: sd)
    assert_equal ["paid", 400, true], r.values_at(:verdict, :accepted, :first), "the ask that pays"
    assert_equal before + 400, balance(lo)
    assert_equal ["paid", 400, false], claim(s, 1, [ANNA], 400, seed: sd).values_at(:verdict, :accepted, :first)
    assert_equal before + 400, balance(lo), "paid once"
    assert_equal "proven", @db[:trainer_battles].where(seed: sd).get(:state)
    assert(logs.any? { |l| l.include?("prize claim 1 (400) proven: paid 400") })
  end

  def test_what_is_refused
    start_server
    s, lo = login
    before = balance(lo)
    sd = seed(s, ANNA)[:seed]
    r = claim(s, 1, [ANNA], 400, seed: sd + 1)
    assert_equal ["refuted", 0], r.values_at(:verdict, :accepted), "another seed"
    assert_equal "wrong_seed", claim_row(lo, 1)[:proof]
    assert_empty keys(lo), "a refused claim pays for no battle"

    # a claim whose replay refutes it: refused at the ask after the verdict
    sl = seed(s, LIAM)[:seed]
    record(s, sl, 78)
    assert_equal "held", claim(s, 3, [LIAM], 176, seed: sl)[:verdict]
    replayed(sl, status: "mismatch", detail: "round 2: AI chose move 1, the record move 0")
    recv_type(s, :money_claim_ready)
    assert_equal ["refuted", 0], claim(s, 3, [LIAM], 176, seed: sl).values_at(:verdict, :accepted)
    assert_equal ["event:31:8", "trainer:CAMPER:Liam:0"], keys(lo), "its battle stays paid for, for nothing"
    assert_equal before, balance(lo)
    assert_equal "repeat", claim(s, 4, [LIAM], 176, seed: sl)[:verdict], "the same battle again: paid for"
    assert(logs.any? { |l| l.include?("prize claim 3 (176) REFUSED: refuted") })
  end

  # One win, one prize: a second claim naming a battle a held claim waits on is refused.
  def test_a_second_claim_on_a_held_battle
    start_server
    s, lo = login
    sd = seed(s, ANNA)[:seed]
    record(s, sd, 84)
    assert_equal "held", claim(s, 1, [ANNA], 400, seed: sd)[:verdict]
    s2, lo2 = login("enf2@t.co")
    assert_equal "refuted", claim(s2, 2, [ANNA], 400, seed: sd)[:verdict], "another account's seed"
    @db[:money_payouts].where(account_id: lo[:account_id]).delete   # as if its keys were free
    assert_equal "refuted", claim(s, 3, [ANNA], 400, seed: sd)[:verdict], "the same battle, another nonce"
    assert_equal "wrong_seed", claim_row(lo, 3)[:proof]
    assert_nil lo2[:x]
  end

  def test_the_daily_allowance_pays_what_no_replay_can_prove
    start_server("PEMK_MONEY_UNPROVEN_DAILY" => "500")
    s, lo = login
    before = balance(lo)
    # no seed: a battle fought offline, a seed that came late - or never asked for
    seed(s, ANNA)
    assert_equal ["allowance", 400], claim(s, 1, [ANNA], 400).values_at(:verdict, :accepted)
    assert_equal ["event:31:7", "trainer:LASS:Anna:0"], keys(lo)
    # a double battle is never recorded: from the allowance - no room left today, so it
    # waits, asked again tomorrow
    r = claim(s, 2, TWINS, 320)
    assert_equal ["held", 0], r.values_at(:verdict, :accepted)
    assert_operator r[:wait], :>=, 60, "asked again when the allowance has room"
    assert_equal "unprovable", claim_row(lo, 2)[:proof]
    assert_equal before + 400, balance(lo)
    assert_equal ["held", 0], claim(s, 2, TWINS, 320).values_at(:verdict, :accepted), "still no room"
    team(s, ["MEOWTH", 12, %w[PAYDAY]])
    assert_equal "unproven", payday(s, 6, 60, trainer_claim: 2)[:verdict], "no replay will prove its prize: no wait"
    @db[:money_daily].where(account_id: lo[:account_id]).update(day: Date.today - 1)   # the next day
    assert_equal ["allowance", 320, true], claim(s, 2, TWINS, 320).values_at(:verdict, :accepted, :first)
    assert_equal before + 720, balance(lo)

    # held, then unprovable (the harness could not replay it): the allowance is spent
    s2, lo2 = login("enf2@t.co")
    sl = seed(s2, LIAM)[:seed]
    record(s2, sl, 79)
    assert_equal "held", claim(s2, 3, [LIAM], 176, seed: sl)[:verdict]
    replayed(sl, status: "error", detail: "NoMethodError")
    recv_type(s2, :money_claim_ready)
    assert_equal ["allowance", 176], claim(s2, 3, [LIAM], 176, seed: sl).values_at(:verdict, :accepted),
                 "each account has its own allowance"
  end

  # A prize over the whole allowance gets the allowance, on a day nothing was paid from
  # it; an allowance of 0 pays nothing and keeps nothing waiting.
  def test_a_prize_over_the_allowance
    start_server("PEMK_MONEY_UNPROVEN_DAILY" => "300")
    s, lo = login
    assert_equal ["allowance", 300], claim(s, 1, [ANNA], 400).values_at(:verdict, :accepted)
    assert_equal ["held", 0], claim(s, 2, [LIAM], 176).values_at(:verdict, :accepted), "none left today"
    @server.stop
    start_server("PEMK_MONEY_UNPROVEN_DAILY" => "0")
    s, = login("enf2@t.co")
    assert_equal ["allowance", 0], claim(s, 3, [ANNA], 400).values_at(:verdict, :accepted)
    assert_nil lo[:x]
  end

  def test_a_partner_battle_and_a_trainer_not_the_game_s_data
    start_server
    s, lo = login
    assert_equal ["allowance", 800], claim(s, 1, [ANNA], 800, amulet: true, partner: %w[POKEMONTRAINER May])
      .values_at(:verdict, :accepted), "a partner at the player's side (its Amulet Coin): never recorded"
    s2, lo2 = login("enf2@t.co")
    sd = seed(s2, ANNA)[:seed]
    record(s2, sd, 80)
    held = claim(s2, 3, [ANNA], 800, seed: sd, amulet: true, partner: %w[POKEMONTRAINER May])
    assert_equal "held", held[:verdict]
    assert_equal 400, claim_row(lo2, 3)[:accepted], "a battle recorded on its seed had no partner: no doubling"
    replayed(sd, status: "mismatch", detail: "the trainer is not the game's data: foe 0 level: the game's data has 20, the record 5")
    recv_type(s2, :money_claim_ready)
    assert_equal ["allowance", 400], claim(s2, 3, [ANNA], 800, seed: sd).values_at(:verdict, :accepted)
    assert_equal sd, seed(s2, ANNA)[:seed], "judged without a win: the same seed, no fresh one"
    assert_nil lo[:x]
  end

  # A refusal stands in every mode; a claim held without one is paid as M3 pays it once
  # enforcement is turned off - its money comes back to the game (held: true).
  def test_enforcement_turned_off_with_claims_held
    start_server
    s, lo = login
    sd = seed(s, ANNA)[:seed]
    record(s, sd, 85)
    assert_equal "held", claim(s, 1, [ANNA], 400, seed: sd)[:verdict]
    sl = seed(s, LIAM)[:seed]
    record(s, sl, 86)
    assert_equal "held", claim(s, 2, [LIAM], 176, seed: sl)[:verdict]
    replayed(sl, status: "walk_mismatch")
    recv_type(s, :money_claim_ready)
    @server.instance_variable_set(:@trainer_enforce, false)
    r = claim(s, 1, [ANNA], 400, seed: sd)
    assert_equal ["paid", 400, true, true], r.values_at(:verdict, :accepted, :first, :held)
    assert_equal ["refuted", 0], claim(s, 2, [LIAM], 176, seed: sl).values_at(:verdict, :accepted)
  end

  def team(s, *mons)
    send_env(s, { type: :team_check, team: mons.map { |sp, lv, mv| { "species" => sp, "level" => lv, "moves" => mv } }, seq: 1 })
    recv_type(s, :team_ack)
  end

  def payday(s, nonce, amount, **proof)
    send_env(s, { type: :money_claim, kind: :payday, nonce: nonce, amount: amount, map: 31 }.merge(proof))
    recv_type(s, :money_claim_ack)
  end

  # Pay Day in a trainer battle waits while its prize is held, and counts only a proven one.
  def test_pay_day_waits_for_its_prize_s_proof
    start_server
    s, lo = login
    team(s, ["MEOWTH", 12, %w[PAYDAY]])
    sd = seed(s, ANNA)[:seed]
    record(s, sd, 81)
    assert_equal "held", claim(s, 1, [ANNA], 400, seed: sd)[:verdict]
    assert_equal ["held", 0], payday(s, 2, 60, trainer_claim: 1).values_at(:verdict, :accepted)
    assert_nil claim_row(lo, 2), "not judged yet"
    replayed(sd)
    recv_type(s, :money_claim_ready)
    assert_equal "held", payday(s, 2, 60, trainer_claim: 1)[:verdict], "proven, not paid yet: it still waits"
    assert_equal "paid", claim(s, 1, [ANNA], 400, seed: sd)[:verdict]
    assert_equal ["paid", 60], payday(s, 2, 60, trainer_claim: 1).values_at(:verdict, :accepted)
    # a prize paid from the allowance proves no Pay Day - nor is its Pay Day a sign of a cheat
    assert_equal "allowance", claim(s, 3, [LIAM], 176)[:verdict]
    assert_equal "unproven", payday(s, 4, 60, trainer_claim: 3)[:verdict]
    sleep 0.3   # a flag is counted on a worker
    assert_nil @db[:player_flags].where(account_id: lo[:account_id], kind: "money_claim").get(:count)
  end

  # A claim over its bound is a sign under enforcement too, whatever the gate made of it.
  def test_a_claim_over_its_bound_is_flagged
    start_server
    s, lo = login
    sd = seed(s, ANNA)[:seed]
    record(s, sd, 96)
    assert_equal "held", claim(s, 1, [ANNA], 900, seed: sd)[:verdict]
    assert(wait_for { @db[:player_flags].where(account_id: lo[:account_id], kind: "money_suspect").get(:count) })
  end

  # A held claim is void at a fresh login like any unsealed one - unless a save whose blob
  # carries it sealed it. A money frame does not (it paid nothing), nor a save of a blob
  # from before the claim (a reconnect pushes the file on disk).
  def test_a_fresh_login_voids_a_held_claim_no_save_sealed
    start_server
    s, lo = login
    sd = seed(s, ANNA)[:seed]
    record(s, sd, 82)
    assert_equal "held", claim(s, 1, [ANNA], 400, seed: sd)[:verdict]
    send_env(s, { type: :econ, field: :money, value: balance(lo), seq: 1 })
    recv_type(s, :econ_ack, :econ_rej)
    send_env(s, { type: :save, seq: 1, claims: [] }, "an older blob")
    recv_type(s, :save_ok)
    sleep 0.2
    assert_nil claim_row(lo, 1)[:sealed_at], "neither a money frame nor a save without it seals it"
    shadow = -> { @db[:money_shadow].where(account_id: lo[:account_id]).get(:s) }
    before = shadow.call
    s.close
    s, = login
    refute_nil claim_row(lo, 1)[:voided_at]
    assert_equal before, shadow.call, "a held claim never reached the shadow balance: its void takes nothing out"
    assert_empty keys(lo), "its battle may be fought again"
    assert_equal "void", claim(s, 1, [ANNA], 400, seed: sd)[:verdict]
    # fought again, on the same seed: its row is free for the new claim, and its one win
    # for the new battle's record (judged on its own, not on the first fight's)
    assert_empty @db[:battle_records].where(trainer_battle_id: @db[:trainer_battles].where(seed: sd).get(:id)).all
    assert_equal 95, record(s, sd, 95)[:rec_nonce]
    refute_nil @db[:battle_records].where(client_nonce: 95).get(:trainer_battle_id)
    assert_equal "held", claim(s, 3, [ANNA], 400, seed: sd)[:verdict]

    sl = seed(s, LIAM)[:seed]
    record(s, sl, 83)
    assert_equal "held", claim(s, 2, [LIAM], 176, seed: sl)[:verdict]
    send_env(s, { type: :save, seq: 2, claims: (100..169).to_a + [2] }, "blob")   # the newest last
    recv_type(s, :save_ok)
    assert wait_for { claim_row(lo, 2)[:sealed_at] }, "a save whose blob carries it"
    s.close
    s, = login
    assert_nil claim_row(lo, 2)[:voided_at]
    assert_equal "held", claim(s, 2, [LIAM], 176, seed: sl)[:verdict]
  end

  # With the demo's own exports and every gate on (as autotest 079), trainer proof `on`
  # enforces - and runs as shadow, saying why, without the team lock or EXP tracking: a
  # record's IVs and levels would be its word.
  def test_what_enforcement_needs
    gates = { "PEMK_MONEY_AUTHORITY" => "on", "PEMK_ITEM_AUTHORITY" => "on", "PEMK_PICKUP_ENFORCE" => "on",
              "PEMK_GIFT_ENFORCE" => "on", "PEMK_SHOP_ENFORCE" => "on", "PEMK_BATTLE_ENFORCE_ENCOUNTERS" => "on",
              "PEMK_BATTLE_ENFORCE_RNG" => "on", "PEMK_TRAINER_PROOF" => "on", "PEMK_BATTLE_ENFORCE_TEAMS" => "on",
              "PEMK_BATTLE_ENFORCE_EXP" => "on" }
    demo = ENV.to_h.reject { |k, _| k.start_with?("PEMK_") }.merge("PEMK_BIND" => "127.0.0.1", "PEMK_PORT" => "0")
    enforces = lambda do |extra|
      @logs = Queue.new
      @server&.stop
      @server = PEMK::Server.new(config: PEMK::Config.new(env: demo.merge(gates).merge(extra)), logger: ->(m) { @logs << m })
      @server.start   # the boot says what it enforces
      @server.instance_variable_get(:@trainer_enforce)
    end
    assert_equal true, enforces.({})
    assert_equal false, enforces.("PEMK_BATTLE_ENFORCE_TEAMS" => "off")
    assert(logs.any? { |l| l.include?("runs as shadow until") && l.include?("the team lock is off") }, logs.inspect)
    assert_equal false, enforces.("PEMK_BATTLE_ENFORCE_EXP" => "off")
  end

  def test_an_older_client_must_update
    start_server
    _, lo = login(caps: %w[money_claims save_ack])
    assert_equal [:login_err, "update_required"], lo.values_at(:type, :reason)
    _, lo = login
    assert_equal ["on", true], lo.values_at(:trainer_proof, :record_ack)
  end

  # A trainer battle always draws: a record on its seed that claims none dodged the walk.
  # And a run of wild battles over the hourly cap holds back no trainer battle's record.
  def test_what_a_trainer_record_must_be
    start_server
    s, lo = login
    sd = seed(s, ANNA)[:seed]
    body = W.encode_primitive({ v: 1, kind: "trainer", truncated: false,
                                draws: { b: { n: 0, fp: "0" * 16, log: "".b }, a: { n: 0, fp: "0" * 16, log: "".b },
                                         r: { n: 0, fp: "0" * 16, log: "".b } } })
    send_env(s, { type: :battle_record, mode: "on", engine_fp: "ab" * 8, outcome: 1, rounds: 1, draws_battle: 0,
                  draws_ai: 0, draws_run: 0, fp_battle: "0" * 16, fp_ai: "0" * 16, fp_run: "0" * 16,
                  truncated: false, desynced: false, battle_seed: sd, rec_nonce: 92 }, body)
    recv_type(s, :battle_record_ack)
    assert_equal "no_log", @db[:battle_records].where(client_nonce: 92).get(:replay_status)

    120.times do |i|
      @db[:battle_records].insert(account_id: lo[:account_id], mode: "on", record: Sequel.blob("x"), outcome: 1,
                                  replay_status: "match", created_at: Time.now - i)
    end
    sl = seed(s, LIAM)[:seed]
    assert_equal 93, record(s, sl, 93)[:rec_nonce], "stored: its own hourly count"
    refute_nil @db[:battle_records].where(client_nonce: 93).get(:trainer_battle_id)
  end

  # A record the server could not store is not acknowledged: the client sends it again.
  def test_a_record_not_stored_is_not_acknowledged
    start_server
    s, = login
    sd = seed(s, ANNA)[:seed]
    records = @server.instance_variable_get(:@battle_records)
    records.define_singleton_method(:ingest) { |*| :error }
    send_env(s, *record_frame(sd, 94))
    assert_nil IO.select([s], nil, nil, 0.8), "no acknowledgement"
    records.singleton_class.remove_method(:ingest)
    assert_equal 94, record(s, sd, 94)[:rec_nonce], "sent again, stored, acknowledged"
  end

  # The record is sent until acknowledged: the same one again is a copy, acknowledged too.
  def test_a_record_sent_again_is_a_copy
    start_server
    s, lo = login
    sd = seed(s, ANNA)[:seed]
    record(s, sd, 90, outcome: 2)
    assert_equal 90, record(s, sd, 90, outcome: 2)[:rec_nonce]
    assert_equal 1, @db[:battle_records].where(account_id: lo[:account_id]).count
  end
end
