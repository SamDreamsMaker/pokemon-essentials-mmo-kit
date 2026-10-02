# frozen_string_literal: true

require "time"
require "set"

module PEMK
  # Milestone 1 server: reactor + worker pool + a connection AUTH-GATE. A socket is
  # unauthenticated (only :ping/:register/:login/:auth accepted, everything else
  # dropped) until it presents valid credentials or a session token — this retires
  # the old client-claimed account_id and closes the impersonation hole. Blocking
  # work (Postgres, bcrypt) runs on the pool; replies come back via reactor.post so
  # connection state and socket writes stay single-threaded.
  #
  # Per-player mailbox routing, zone presence and the save store are the next
  # increments; authenticated gameplay frames are logged here for now.
  class Server
    # E4: a swap that would move a held item the server does not recognize.
    class TradeItemRefused < StandardError; end

    AUTH_TYPES     = %i[ping register login auth].freeze
    # Authenticated point-to-point frames the server relays to the :to account
    # (challenge handshake + the whole battle stream), the role the old in-process
    # relay played — now with server-trusted :from and no cross-client leakage.
    ADDRESSED      = %i[challenge challenge_accept challenge_decline battle_team
                        battle_start battle_choice battle_round battle_switch battle_end
                        trade_invite trade_accept trade_decline trade_offer trade_lock trade_cancel].freeze
    TRADE_TTL      = 15          # seconds a half-committed (lone) trade rendezvous lingers before timeout
    WORKERS        = 8
    LOGIN_MAX      = 10          # login/register attempts ...
    LOGIN_WINDOW   = 60          # ... per this many seconds, per IP

    def self.log(msg)
      $stdout.puts("#{Time.now.utc.iso8601} #{msg}")
      $stdout.flush
    end

    def initialize(config: Config.new, logger: nil)
      @config   = config
      @log      = logger || self.class.method(:log)
      @db       = DB.connect(@config.database_url, max_connections: WORKERS + 2)
      @accounts   = Accounts.new(@db)
      @sessions   = Sessions.new(@db)
      @bans       = Bans.new(@db)   # moderation: set and lifted by the operator (bin/pemk_admin.rb)
      @characters = Characters.new(@db)
      # Badges become monotonic once the sovereignty layer is on: they are progression,
      # and a reloaded save pushing 0 must not erase them.
      @ledger     = Ledger.new(@db, @config.economy_caps, monotonic: @config.flag_state == :on)
      @inventory  = Inventory.new(@db, @config.inventory_caps, logger: @log)
      @encounter_rolls = EncounterRolls.new(@db)   # M4 D3.2: persisted mints -> mon provenance
      # Provenance labeling only makes sense when the server actually mints encounters:
      # off/shadow would label every honest catch "client" (and invert the signal). With
      # rolls disabled, origin stays NULL = its documented "unknown" meaning.
      @monsters   = Monsters.new(@db, @config.monster_caps, logger: @log,
                                 rolls: (@config.battle_enforce_encounters == :on ? @encounter_rolls : nil),
                                 resim: @config.battle_enforce_resim)   # D8: birth states
      @trades     = Trades.new(@db, resim: @config.battle_enforce_resim)   # D8: provisional trade hold
      # M4 Layer A: read-only world model + detection-only interaction audit. Both are
      # in-memory and DB-free; a missing export just makes the audit a no-op.
      @world      = WorldData.new(@config.world_path, logger: @log)
      @battle     = BattleData.new(@config.battle_data_path, logger: @log)   # M4 Layer D read model
      @team_audit = TeamAudit.new(@battle, mode: @config.battle_enforce_teams,
                                  party_max: @config.monster_caps[:party_max], logger: @log)   # M4 Layer D D1
      # Audit item 5: the per-mon stat block (first-sight identity lock). Rides the
      # existing D1 team flag rather than adding a 12th knob.
      @monster_blocks = MonsterBlocks.new(@db, logger: @log) if @config.battle_enforce_teams != :off
      @encounter_mint = EncounterMint.new(@world, logger: @log)   # M4 Layer D D2 wild-encounter roller
      @catch_calc = CatchCalc.new(@battle)                        # M4 Layer D D3 capture adjudication
      # M4 Layer D D4 wild-battle reward bounds (detection). Only active when the operator
      # opts in; needs encounter context (foe mints) for meaningful windows.
      @reward_audit = if @config.battle_enforce_rewards != :off
                        RewardAudit.new(RewardCalc.new(@battle), @battle, logger: @log)
                      end
      # M4 Layer D D5: cross-battle anomaly detection -> review queue (never enforces).
      @anomaly = AnomalyDetector.new(@db, @world, logger: @log) if @config.anomaly_detection
      @last_anomaly_sweep = nil
      @anomaly_sweeping   = false
      # M4 Layer D D6: per-mon EXP high-water + rollback detection (part 1) + the :on
      # up-only restore (part 2). battle_data supplies per-species EXP sanity caps.
      @monster_stats = MonsterStats.new(@db, battle: @battle) if @config.battle_enforce_exp != :off
      # M4 Layer D D8: the re-sim verdict sweep (live-server writer of monster state).
      @resim = ResimVerdicts.new(@db, mode: @config.battle_enforce_resim,
                                 min_strikes: @config.resim_min_strikes, logger: @log) if @config.battle_enforce_resim != :off
      @last_resim_sweep = nil
      @resim_sweeping   = false
      # M4 Layer D D7 part 1: the battle-record corpus ingest (shadow + on).
      if @config.battle_enforce_rng != :off
        # Trainer proof P2: under `on` a trainer battle is seeded too, one seed per placement.
        @trainer_battles = TrainerBattles.new(@db) if @config.battle_enforce_rng == :on
        @battle_records = BattleRecords.new(@db, mode: @config.battle_enforce_rng, logger: @log,
                                                 trainer_battles: @trainer_battles)
      end
      # Audit item 4: switches/variables/self-switches detection shadow.
      if @config.flag_state != :off
        @flag_state = FlagState.new(@db, policy: manifest_policy, facts: manifest_fact_keys,
                                    repeatable: manifest_repeatable, latched: manifest_latched,
                                    enforce: @config.flag_enforce, logger: @log)
      end
      @gift_claims = GiftClaims.new(@db, logger: @log) if @config.flag_state != :off
      @gift_grants = GiftGrants.new(@db, logger: @log) if @config.gift_enforce != :off   # step 6
      @trade_deliveries = TradeDeliveries.new(@db, logger: @log) if @config.trade_redelivery
      @shop_deals = ShopDeals.new(@db) if @config.shop_enforce == :on   # E3: a deal runs once, asked again by its nonce
      @money_claims = MoneyClaims.new(@db) if @config.money_authority != :off   # money authority M1a: prize claims judged
      # Trainer proof: a claim naming its battle's seed gets the replay's verdict (P3); under
      # `on` it is held until that verdict (P4 - decided below, with M3).
      if @config.trainer_proof != :off && @trainer_battles && @money_claims
        @trainer_proofs = TrainerProofs.new(@db, logger: @log)
      end
      @last_proof_sweep = nil
      @proof_sweeping   = false
      if @config.money_authority == :off
        (MoneyShadow.clear(@db) rescue nil)   # M1b: rows would go stale without the measurement
      else
        @money_shadow = MoneyShadow.new(@db, start_money: @battle.start_money, cap: @config.economy_caps.fetch(:money))
        @money_daily  = MoneyDaily.new(@db)   # the day's local sales (PEMK_MONEY_LOCAL_DAILY)
      end
      @money_enforce = false   # M3, decided below once item authority is
      @last_maps = {}   # account_id => the map its last connection ended on (M1a claims)
      @item_ledger = ItemLedger.new(@db, grace: @config.item_grace) if @config.item_authority != :off   # item authority E2
      @item_twins = {}
      if @item_ledger   # E2b: which items this game can produce unseen, under the gates that are on
        @item_tiers = ItemTiers.new(world: @world, battle: @battle, gifts: @config.gift_enforce != :off,
                                    claims: @config.flag_state != :off, shops: @config.shop_enforce != :off,
                                    repeatable: method(:repeatable_gift?), extra: @config.item_local)
        @item_twins = item_twins
        @judged_local = @item_tiers.local.map { |i| @item_twins.fetch(i, i) }.to_set.freeze
        flag_accounts_from_zero
      end
      # E4: enforcement only where every source is a credit the server hands out first.
      @item_enforce = @config.item_authority == :on && enforce_blockers.empty?
      @recent_down = RecentDecreases.new if @item_enforce   # what left the possession lately (a ball thrown)
      # M3: money rises only through the server's own transactions - where every source
      # is one it bounds; 'on' with a blocker left runs as shadow.
      @money_enforce = @config.money_authority == :on && money_blockers.empty?
      # Trainer proof P4: a trainer prize is paid on its battle's replay - where money
      # authority enforces, battle rng is on, and the team lock and EXP tracking run (the
      # team's checks); 'on' otherwise runs as shadow.
      @trainer_enforce = @config.trainer_proof == :on && @money_enforce && !@trainer_proofs.nil? && team_proof_gaps.empty?
      # Badge authority: each new badge judged by the battle that gives it (B1), owned on its
      # proven win (B2). It reads the trainer prize claims and their proofs.
      @badge_audit = BadgeAudit.new(@db, @world) if @config.badge_authority != :off && @money_claims
      weigh_badge_blockers
      @badge_said  = {}   # [account, badge] => the verdict logged last (a frame sent again says nothing new)
      @badge_based = {}   # account => its baseline (badge_baselines)
      @badge_mutex = Mutex.new
      # B2: a proven win's badges are owned inside its proof's settle transaction
      @trainer_proofs.on_proven = ->(claim) { badge_grant_win(claim) } if @badge_audit && @trainer_proofs
      @last_item_sweep = nil
      @item_sweeping   = false
      @audit      = Audit.new(@world, logger: @log)
      @pos_audit  = PositionAudit.new(@world, logger: @log, mode: @config.position_enforcement)   # M4 Layer B
      @mode_keys  = @world.field_keys   # what Surf and Dive need (nil: an export from before)
      @pickups    = Pickups.new(@db)   # M4 Layer C one-shot ledger
      @pool     = WorkerPool.new(size: WORKERS, logger: @log)
      @limiter  = RateLimiter.new(max: LOGIN_MAX, per: LOGIN_WINDOW)
      @zones    = Hash.new { |h, k| h[k] = Set.new }   # map_id => Set(conn); reactor-thread only
      @zone_legacy = {}                                 # map_id => Set(conn) without presence_v2; reactor-thread only
      @presence_swept_at = nil
      @online   = {}                                    # account_id => conn; reactor-thread only
      @pending_trades = {}                              # trade_id => rendezvous; reactor-thread only
      @peer_sessions  = {}                              # account_id => partner id (mutual); reactor-thread only
      @trade_bodies   = {}                              # sender => its last locked escrow; reactor-thread only
      @conn_buckets   = {}                              # conn => [tokens, last_refill]; reactor-thread only
      @reactor  = Reactor.new(
        host: @config.bind, port: @config.port,
        on_frame: method(:on_frame), on_close: method(:on_close),
        on_tick: method(:on_tick), logger: @log
      )
      @mailbox  = PlayerMailbox.new(pool: @pool, post: @reactor.method(:post), logger: @log)
    end

    def port
      @reactor.port
    end

    def start
      @db.test_connection
      @log.call("server: db ok (#{@db.opts[:database]}), workers=#{WORKERS}")
      @log.call("server: economy caps #{@config.economy_caps}, badges<#{@config.badges_max}")
      @log.call("server: inventory caps #{@config.inventory_caps} (detection-only, flag-not-reject)")
      @log.call("server: monster caps #{@config.monster_caps} (uid registry, flag-not-reject)")
      @log.call("server: world data #{@world.summary} (M4 Layer A, audit-only)")
      @log.call("server: battle data #{@battle.summary} (M4 Layer D)")
      @log.call("server: team legality enforcement = #{@config.battle_enforce_teams} (M4 Layer D D1, detection-only)")
      @log.call("server: encounter enforcement = #{@config.battle_enforce_encounters} (M4 Layer D D2)")
      @log.call("server: catch enforcement = #{@config.battle_enforce_catches} (M4 Layer D D3)")
      @log.call("server: reward enforcement = #{@config.battle_enforce_rewards} (M4 Layer D D4, detection-only)")
      @log.call("server: anomaly detection = #{@config.anomaly_detection ? 'on' : 'off'} (M4 Layer D D5, review-queue only)")
      @log.call("server: exp authority = #{@config.battle_enforce_exp} (M4 Layer D D6; on = up-only restore to high-water)")
      @log.call("server: battle rng = #{@config.battle_enforce_rng} (M4 Layer D D7 part 1 — instrumentation, never rejects)")
      @log.call("server: resim enforcement = #{@config.battle_enforce_resim} (M4 Layer D D8 — walk-tier quarantine, strikes=#{@config.resim_min_strikes})")
      if @config.battle_enforce_resim != :off && @config.battle_enforce_rng != :on
        @log.call("server: WARNING resim enforcement is #{@config.battle_enforce_resim} but battle rng is #{@config.battle_enforce_rng} — no seeds/records means nothing can ever be verified or condemned")
      end
      if @config.battle_enforce_rewards != :off && @config.battle_enforce_encounters != :on
        @log.call("server: WARNING reward detection is on but encounter enforcement is #{@config.battle_enforce_encounters} — no foe context, so battle windows can't open")
      end
      if @config.battle_enforce_rng != :off && @config.battle_enforce_encounters != :on
        @log.call("server: WARNING battle rng is #{@config.battle_enforce_rng} but encounter enforcement is #{@config.battle_enforce_encounters} — seeds ride the mint, so no battle can be seeded")
      end
      begin
        pruned = @encounter_rolls.prune
        @log.call("server: pruned #{pruned} stale encounter roll(s) (>#{EncounterRolls::RETENTION_DAYS}d, never fought)") if pruned.positive?
      rescue StandardError => e
        @log.call("server: encounter-roll prune failed #{e.class}: #{e.message}")
      end
      # D7 part 3: corpus retention — matched records are spent; evidence is kept.
      if @battle_records
        begin
          pruned = @battle_records.prune(days: @config.corpus_retention_days)
          @log.call("server: pruned #{pruned} matched battle record(s) (>#{@config.corpus_retention_days}d)") if pruned.positive?
        rescue StandardError => e
          @log.call("server: battle-record prune failed #{e.class}: #{e.message}")
        end
      end
      if @config.battle_enforce_catches == :on && @config.battle_enforce_encounters != :on
        @log.call("server: WARNING catch enforcement is on but encounter enforcement is #{@config.battle_enforce_encounters} — catches need a server encounter mint, so they will all fail-open to local")
      end
      @log.call("server: flag state = #{@config.flag_state} " \
                "(switches/variables#{@config.flag_state == :on ? '; facts materialized at login, grant-only' : ' — detection only'})")
      @log.call("server: flag enforcement = #{@config.flag_enforce} (owned values repaired to the mirror when on)")
      @log.call("server: gift enforcement = #{@config.gift_enforce} (one-shot gifts paid once when on)")
      @log.call("server: peer body check = #{@config.peer_check} (relayed Pokemon may name #{@config.peer_classes.join(', ')})")
      @log.call("server: shop enforcement = #{@config.shop_enforce} (Mart purchases and sales made server-side when on)")
      log_money_authority
      log_trainer_proof
      log_badge_authority
      badge_boot_pass
      badge_mark_enforcing
      @log.call("server: item authority = #{@config.item_authority} (item increases judged against server-known sources; logs only)")
      if @config.item_authority == :on
        if @item_enforce
          @log.call("server: item enforcement ON (E4) - unexplained judged items are taken back " \
                    "(grace #{@config.item_grace}s)")
        else
          @log.call("server: WARNING item authority 'on' needs #{enforce_blockers.join(', ')} - it runs as shadow")
        end
      end
      if @item_ledger && !(@world.loaded? && @battle.loaded?)
        @log.call("server: WARNING item authority is on but the world or battle export is missing - no pickup, gift or shop can explain an item")
      end
      if @item_tiers
        @log.call("server: item tiers: #{@item_tiers.summary}; every other item is judged")
        unless @item_tiers.complete?
          @log.call("server: WARNING the exports predate the item sources - computed and unhooked sources are unknown " \
                    "and their items judged (one debug launch regenerates them)")
        end
        unless @item_tiers.unbounded.empty?
          @log.call("server: WARNING #{@item_tiers.unbounded.size} event(s) add an item the export cannot name, so " \
                    "their items are judged - list the honest ones in PEMK_ITEM_LOCAL: #{@item_tiers.unbounded.join('; ')}")
        end
      end
      @log.call("server: position enforcement = #{@config.position_enforcement} (M4 Layer B)")
      if @config.position_enforcement != :off && @world.loaded? && !@world.water_marks?
        @log.call("server: WARNING the world export predates the water marks - a surfer is not checked against " \
                  "walls and a dive reads as an impossible warp (one debug launch regenerates it)")
      end
      @log.call("server: moderation - #{@bans.in_force_list.size} account(s) banned (bin/pemk_admin.rb)")
      @log.call("server: pickup enforcement = #{@config.pickup_enforce ? 'on' : 'off'} (M4 Layer C server-mint)")
      @log.call("server: WARNING pickup reset ALLOWED (PEMK_ALLOW_PICKUP_RESET=on) — DEV ONLY, disable in production") if @config.pickup_reset_allowed
      log_client_debug
      log_mode_keys
      @log.call("server: presence dedup = #{@config.presence_dedup ? 'on' : 'off'} " \
                "(#{@config.presence_dedup ? "an idle player's repeats reach only older clients; " \
                                             "a member silent #{PRESENCE_SILENCE.to_i}s leaves its map" : 'every frame to everyone'})")
      @pool.start
      @reactor.start
      @thread = Thread.new { @reactor.run_loop }
      @thread.abort_on_exception = true
    end

    def stop
      @reactor.stop
      @thread&.join(5)
      @pool.shutdown
      @db.disconnect   # the workers are done: a stopped server holds no connection
      @log.call("server: stopped")
    end

    def run
      install_signal_handlers
      start
      @thread.join           # block until SIGTERM stops the reactor
      @pool.shutdown
      @db.disconnect
      @log.call("server: stopped")
    end

    private

    def on_frame(conn, payload)
      # An EVICTED socket (a relogin took over this account) must never mutate account
      # state again — it used to be honored for one more frame (audit).
      return if conn.closing

      conn.data[:last_seen] = Process.clock_gettime(Process::CLOCK_MONOTONIC)   # idle sweep
      dec = Wire.decode_envelope(payload, false) # host path rejects legacy whole-Marshal
      unless dec
        @log.call("server: bad/legacy frame from #{conn.addr} -> drop")
        conn.closing = true
        return
      end

      env    = dec[:env]
      type   = env[:type]
      authed = conn.data[:account_id]

      unless authed || AUTH_TYPES.include?(type)
        @log.call("server: pre-auth #{type.inspect} from #{conn.addr} -> drop")
        conn.closing = true
        return
      end

      # Per-connection budget for AUTHENTICATED frames. Nothing rate-limited anything
      # after login before this (audit): one socket could spam DB-touching frames until
      # the mailbox/pool queues ate the host. Honest clients send these at human,
      # debounced cadence, so the budgets are generous.
      if authed && !(frame_budget_ok?(conn, type) && (!PRESENCE_TYPES.include?(type) || frame_budget_ok?(conn, :presence)))
        @log.call("server: account #{authed} over budget on #{type.inspect} -> drop")
        claim_sent(conn, env[:nonce]) if type == :money_claim   # a Pay Day after it waits for it
        return
      end

      dispatch_frame(conn, env, type, authed, dec[:body])
      # its keys may change: read again, queued after the frame's own mailbox work
      mode_keys_stale(conn, authed) if type == :money_claim || (type == :econ && env[:field].to_s == "badges")
    rescue StandardError => e
      # A raise used to unwind to the reactor's blanket rescue, aborting the whole tick
      # (and the rest of this socket's already-parsed frames) with an unattributable log.
      @log.call("server: handler error on #{type.inspect} account #{authed.inspect}: #{e.class}: #{e.message}")
    end

    # Token bucket per connection. Tight for the DB-touching types, generous for
    # presence. Unlisted authed types get the default bucket.
    FRAME_BUDGETS = {
      # save: the Checkpoint fires urgent (<=1s) bursts after high-value events, so the
      # burst must absorb several back-to-back pushes; sustained 1/s is still ~100x an
      # honest client and bounds a flood to the blob cap per second.
      save: [10, 1.0], econ: [10, 4], inv: [10, 4], uid_req: [10, 4], mon_party: [10, 4],
      flags: [10, 1.0], flag_delta: [20, 4], gift_claim: [20, 4], gift_req: [10, 1.0], gift_applied: [10, 1.0],
      encounter_req: [10, 2], catch_req: [20, 6], battle_record: [6, 1], trade_commit: [6, 2], trainer_battle_req: [10, 2],
      team_check: [10, 2], pickup_req: [20, 6], interact_claim: [30, 10], trade_applied: [6, 2], trade_owed: [4, 0.2], shop_req: [10, 2], money_claim: [10, 2],
      pos: [40, 20], dir: [40, 20], step: [40, 20], spawn: [10, 2],
      # all presence types together: a bike is 10 steps/s - alternating types must not
      # triple the fan-out a script can force on its map
      presence: [40, 20]
    }.freeze
    FRAME_BUDGET_DEFAULT = [30, 10].freeze
    PRESENCE_TYPES = %i[pos dir step spawn].freeze

    def frame_budget_ok?(conn, type)
      burst, rate = FRAME_BUDGETS.fetch(type, FRAME_BUDGET_DEFAULT)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      b = (conn.data[:budgets] ||= {})
      tokens, last = b[type] || [burst.to_f, now]
      tokens = [tokens + ((now - last) * rate), burst.to_f].min
      return (b[type] = [tokens, now]) && false if tokens < 1.0

      b[type] = [tokens - 1.0, now]
      true
    end

    def dispatch_frame(conn, env, type, authed, body)
      case type
      when :ping     then reply(conn, type: :pong, t: env[:t])
      when :register then handle_register(conn, env)
      when :login    then handle_login(conn, env)
      when :auth     then handle_auth(conn, env)
      when :save     then handle_save(conn, env, body, authed, conn.data[:last_pos])
      when :econ     then handle_econ(conn, env, authed)
      when :inv      then handle_inv(conn, env, authed)
      when :uid_req  then handle_uid_req(conn, env, authed)
      when :mon_party then handle_mon_party(conn, env, authed)
      when :interact_claim then handle_interact_claim(conn, env, authed)
      when :pickup_req then handle_pickup_req(conn, env, authed)
      when :pickups_reset then handle_pickups_reset(conn, env, authed)
      when :team_check then handle_team_check(conn, env, authed)
      when :encounter_report then handle_encounter_report(conn, env, authed)
      when :encounter_req then handle_encounter_req(conn, env, authed)
      when :catch_req then handle_catch_req(conn, env, authed)
      when :catch_report then handle_catch_report(conn, env, authed)
      when :battle_end_report then handle_battle_end(conn, env, authed)
      when :battle_record then handle_battle_record(conn, env, body, authed)
      when :trainer_battle_req then handle_trainer_battle_req(conn, env, authed)
      when :flags then handle_flags(conn, env, authed)
      when :flag_delta then handle_flag_delta(env, authed)
      when :gift_claim then handle_gift_claim(env, authed)
      when :gift_req then handle_gift_req(conn, env, authed)
      when :gift_applied then handle_gift_applied(env, authed)
      when :trade_commit then handle_trade_commit(conn, env, authed)
      when :trade_applied then handle_trade_applied(env, authed)
      when :trade_owed then handle_trade_owed(conn, authed)
      when :shop_req then handle_shop_req(conn, env, authed)
      when :money_claim then handle_money_claim(conn, env, authed)
      when :pos, :dir, :step, :spawn then handle_presence(conn, env, authed)
      when *ADDRESSED then handle_addressed(conn, env, body, authed)
      else
        # Other authenticated gameplay frames (economy, battle) — per-player mailbox
        # routing + handlers land in later milestones.
        @log.call("server: authed #{type.inspect} from account #{authed}")
      end
    end

    def handle_register(conn, env)
      return reply(conn, type: :register_err, reason: "rate_limited") unless @limiter.allow?(conn.addr)

      email = env[:email].to_s
      pw    = env[:password].to_s
      uname = env[:username]   # optional display handle
      @pool.submit do
        result =
          begin
            id = @accounts.create(email: email, password: pw, username: uname)
            # Born while item authority runs: its items start from nothing the server did not see.
            @db[:accounts].where(id: id).update(items_from_zero: true) if id && @item_ledger
            id ? { type: :register_ok, account_id: id } : { type: :register_err, reason: "taken" }
          rescue ArgumentError => e
            { type: :register_err, reason: e.message }
          end
        @reactor.post { reply(conn, **result) }
      end
    end

    # What a client says it can do (a login or auth frame's :caps). Unknown words are
    # ignored; a client that lists nothing gets the pre-caps behaviour.
    def note_caps(conn, env)
      conn.data[:caps] = Array(env[:caps]).grep(String).first(16).map { |c| c[0, 32] }
    end

    def repairs?(conn)
      Array(conn.data[:caps]).include?("flag_repair")
    end

    # M3: a client that claims no prizes would see every one of them refused - it has to
    # update before it plays here. So does one that cannot wait for a prize's proof (P4),
    # or hold its badge frame for its claim and record and fight a badge's battle alone
    # (badge authority B2: a partner the export cannot see may join it too).
    def money_update_required?(conn)
      caps = Array(conn.data[:caps])
      (@money_enforce && !caps.include?("money_claims")) || (@trainer_enforce && !caps.include?("trainer_proof")) ||
        (badge_enforce? && !(caps.include?("badge_hold") && caps.include?("badge_alone")))
    end

    def handle_login(conn, env)
      return reply(conn, type: :login_err, reason: "rate_limited") unless @limiter.allow?(conn.addr)
      # A socket is one session: the game reconnects on a new one. A second login here
      # would leave the first account's map, relays and claims pointing at this socket.
      return reply(conn, type: :login_err, reason: "already_authed") if conn.data[:account_id]

      note_caps(conn, env)
      return reply(conn, type: :login_err, reason: "update_required") if money_update_required?(conn)

      email = env[:email].to_s
      pw    = env[:password].to_s
      addr  = conn.addr
      @pool.submit do
        acct, err = @accounts.authenticate(email, pw)
        # Banned: told until when and why, once the password is right (a stranger learns
        # nothing), and no session is issued.
        if acct && (ban = @bans.active(acct[:id]))
          @log.call("server: login refused for account #{acct[:id]}: banned")
          @reactor.post { reply(conn, type: :login_err, reason: "banned", **Bans.notice(ban)) }
          next
        end
        if acct
          # A password login takes the account over: the sessions it replaces must not
          # come back with their old tokens (an older client ignores :session_replaced
          # and would reconnect, taking the account back).
          @sessions.revoke_all(acct[:id])
          token = @sessions.issue(acct[:id], remote_addr: addr)
          # The state READ must serialize behind any in-flight :save/:econ/:inv for
          # this account (a login racing a pending save would hand back a stale
          # blob and the client's next push would fossilize the rollback). Mailbox
          # bookkeeping is reactor-thread-only, so route the submit through post.
          @reactor.post do
            @mailbox.submit(acct[:id]) do
              blob = @characters.load_blob(acct[:id])   # opaque; never loaded here
              rec  = reconcile_block(acct[:id], fresh: true)
              pos  = (@characters.load_position(acct[:id]) rescue nil)   # M4-B: seed last_pos (never brick login)
              held = (mode_keys_checked? ? badges_allowed(acct[:id]) : nil) rescue nil   # mode keys: the first swim judged at once
              @reactor.post do
                if @reactor.alive?(conn) && conn.data[:account_id].nil?   # never bind a dead conn, or one bound meanwhile
                  bind(conn, acct[:id])
                  conn.data[:last_pos] = pos if pos
                  seed_mode_keys(conn, held) if held
                  reply_body(conn, { type: :login_ok, account_id: acct[:id], token: token }.merge(rec, presence_v2: conn.data[:presence_v2] ? true : false), blob)
                elsif @reactor.alive?(conn)
                  reply(conn, type: :login_err, reason: "already_authed")   # two logins in one write
                end
              end
            end
          end
        else
          @reactor.post { reply(conn, type: :login_err, reason: err.to_s) }
        end
      end
    end

    def handle_auth(conn, env)
      token = env[:token].to_s
      return reply(conn, type: :auth_err, reason: "already_authed") if conn.data[:account_id]   # one session a socket

      note_caps(conn, env)
      return reply(conn, type: :auth_err, reason: "update_required") if money_update_required?(conn)
      # A reconnect resuming a live session must not be judged like a fresh one: the
      # client keeps its state, it does not load the stored blob.
      fresh = env[:resume] != true
      @pool.submit do
        account_id = @sessions.resolve(token)
        # A ban revokes the sessions; one set in the table by hand still stops a resume.
        if account_id && (ban = @bans.active(account_id))
          @log.call("server: resume refused for account #{account_id}: banned")
          @reactor.post { reply(conn, type: :auth_err, reason: "banned", **Bans.notice(ban)) }
          next
        end
        if account_id
          # Same serialization as handle_login: read behind the account's mailbox.
          @reactor.post do
            @mailbox.submit(account_id) do
              blob = @characters.load_blob(account_id)
              rec  = reconcile_block(account_id, fresh: fresh)
              pos  = (@characters.load_position(account_id) rescue nil)   # M4-B: seed last_pos (never brick login)
              held = (mode_keys_checked? ? badges_allowed(account_id) : nil) rescue nil   # mode keys: the first swim judged at once
              @reactor.post do
                if @reactor.alive?(conn) && conn.data[:account_id].nil?   # never bind a dead conn, or one bound meanwhile
                  bind(conn, account_id)
                  conn.data[:last_pos] = pos if pos
                  seed_mode_keys(conn, held) if held
                  reply_body(conn, { type: :auth_ok, account_id: account_id }.merge(rec, presence_v2: conn.data[:presence_v2] ? true : false), blob)
                elsif @reactor.alive?(conn)
                  reply(conn, type: :auth_err, reason: "already_authed")   # two auths in one write
                end
              end
            end
          end
        else
          @reactor.post { reply(conn, type: :auth_err, reason: "invalid_token") }
        end
      end
    end

    # Persist the opaque save body (never Marshal.load'd server-side). On the
    # per-account MAILBOX (not the raw pool): two rapid pushes for one account
    # must commit in arrival order (raw-pool scheduling could commit the OLDER
    # blob last, silently rolling the account back), and the login/auth state
    # read serializes behind any in-flight save.
    # A real Essentials save measures ~100 KB; full PC boxes leave plenty of room under
    # this. MUST stay below the reactor's OUTBUF_CAP (4 MiB) or a stored blob could
    # never be delivered back at login, permanently bricking that account (audit).
    SAVE_MAX_BYTES = 2 * 1024 * 1024

    def handle_save(conn, env, body, account_id, last_pos)
      unless body.is_a?(String) && !body.empty?
        @log.call("server: empty :save from account #{account_id} -> ignore")
        return
      end

      seq = env[:seq]
      if body.bytesize > SAVE_MAX_BYTES
        # Tell the client rather than dropping silently: a save that never lands is
        # invisible permanent progress loss.
        @log.call("server: account #{account_id} save too large (#{body.bytesize}B > #{SAVE_MAX_BYTES}) -> reject")
        return reply(conn, type: :save_err, reason: "too_large", max: SAVE_MAX_BYTES, seq: seq)
      end

      tid = env[:trainer_id]
      sv  = env[:save_version]
      wv  = env[:wire_version]
      # A client that asks is told whether each save was written, so it sends one again
      # rather than trusting a save that never landed (a database error, a full queue).
      ack = Array(conn.data[:caps]).include?("save_ack")
      answer = ->(**env) { @reactor.post { reply(conn, seq: seq, **env) if ack && @reactor.alive?(conn) } }
      # Persist the SERVER-tracked position (captured on the reactor thread when the
      # frame arrived, not client-claimed) alongside the blob, so the next login seeds
      # the position audit. nil (no presence yet) leaves the stored position untouched.
      fseq = env[:flags_seq]
      queued = @mailbox.submit(account_id) do
        begin
          @characters.store(account_id, blob: body, trainer_id: tid, save_version: sv, wire_version: wv,
                                        position: last_pos, flags_seq: fseq)
        rescue StandardError => e
          # Nothing below may run: it all counts on this save being on the server.
          @log.call("server: save of account #{account_id} FAILED #{e.class}: #{e.message}")
          answer.(type: :save_err, reason: "store_failed")
          next
        end
        answer.(type: :save_ok)
        # The blob is the client's durability boundary: progression facts granted up
        # to the flags seq it carries are now on the player's disk, so promote them
        # out of pending. Anything granted after it waits for the next save, or a
        # crash here would restore a switch onto a save that lacks its payout.
        @flag_state&.commit_facts(account_id, fseq)
        @flag_state&.note_durable(account_id, fseq)
        @trade_deliveries&.seal(account_id)   # traded Pokemon reported before this save are on disk
        # A checkpoint waits for the battle's event to end: the prizes claimed before it
        # are in this save, so a fresh login keeps them.
        @money_claims&.seal(account_id, held: saved_claims(env))   # ... and the held ones this blob lists (P4)
        @log.call("server: saved account #{account_id} (#{body.bytesize}B)")
      end
      answer.(type: :save_err, reason: "busy") unless queued   # the account's queue is full
    end

    # P4: the prize claims a pushed save's blob carries, as the client names them when it
    # writes the blob - nonces only, bounded. An older client names none.
    def saved_claims(env)
      Array(env[:claims]).select { |n| MoneyClaims.nonce(n) }.last(CLAIMS_SENT_MAX)   # the newest: its latest battles
    end

    # Server-authoritative economy. Serialized per account on the mailbox: apply the
    # absolute value through the ledger (cap-checked, gap-safe idempotent), then
    # ACK the canonical balance or REJECT (the client rolls back to it).
    def handle_econ(conn, env, account_id)
      field = env[:field]
      value = env[:value]
      seq   = env[:seq]
      current = @online[account_id].equal?(conn)   # read on the reactor: a replaced session's frames do not count (M1b)
      seeds = Array(conn.data[:caps]).include?("trainer_proof")   # its trainer battles ask their seeds (P4)
      @mailbox.submit(account_id) do
        # D4: attribute a fresh MONEY change to a recent wild battle's budget window
        # (reason "battle:<n>"/"battle_suspect:<n>"), else "unattributed". Only on a
        # genuinely new frame (never a replay), only for :money, only when reward
        # detection is enabled — otherwise the reason stays the M2 default.
        reason = "unattributed"
        if @reward_audit && field.to_s == "money" && value.is_a?(Integer) && !@ledger.recorded?(account_id, field, seq)
          delta = value - @ledger.current(account_id, field)
          reason, suspect = @reward_audit.note_money(account_id, delta)
          if suspect
            @log.call("reward: account #{account_id} SUSPECT money delta #{delta} exceeds battle window (#{reason})")
            flag_anomaly(account_id, :reward_money)
          end
        end
        before = money_row(account_id) if @money_shadow && field.to_s == "money"
        # Badge authority B1: the badges this frame adds, judged by the battles giving them.
        judge_badges(account_id, value, seq, seeds: seeds) if @badge_audit && field.to_s == "badges"
        # M3: money rises only through the server's own transactions (claims, deals).
        enforced = @money_enforce && field.to_s == "money"
        hold = field.to_s == "badges" && badge_enforce?   # B2: only the server's grants move them
        status = @ledger.apply_econ(account_id, field, value, seq, reason: reason, no_increase: enforced, hold: hold)
        if hold   # the answer is what the client shows: owned, and pending
          shown = badge_shown(account_id)
          status = value == shown ? [:ack, shown] : [:rej, shown, :badges]
        end
        if field.to_s == "money" && status.first == :ack
          # M1a: a fresh money frame carries the prizes claimed before it - they reached
          # the ledger, so a fresh login no longer voids them.
          @money_claims&.seal(account_id)
          shadow_frame(account_id, value, before) if current   # M1b: what no source explains
        elsif enforced && status[2] == :unexplained
          @log.call("money: account #{account_id} REFUSED a frame of #{value} over the balance #{status[1]}")
          @money_shadow&.login(account_id, status[1])   # the client adopts the balance
          flag_anomaly(account_id, :money_unexplained)
        end
        @reactor.post do
          case status.first
          when :ack, :dup then reply(conn, type: :econ_ack, field: field, value: status[1], seq: seq)
          when :rej       then reply(conn, type: :econ_rej, field: field, value: status[1], seq: seq, reason: status[2].to_s)
          end
        end
      end
    end

    # Server-side BAG record (DETECTION-ONLY): the client pushes the whole bag as an
    # absolute {item_id => qty} snapshot. Serialized per account on the SAME mailbox
    # as :econ/:save (no read-modify-write race). We record + structurally flag, then
    # ALWAYS ack (never reject/roll back) — the bag stays blob-authoritative in M2.3.
    def handle_inv(conn, env, account_id)
      bag = env[:bag]
      seq = env[:seq]
      # D4: level items this snapshot shows used credit the next level jumps (inline,
      # reactor thread, before the party projection of the same flush arrives).
      stores = env[:stores].is_a?(Hash) ? env[:stores] : nil
      if @reward_audit
        # Every store, not the bag alone: a Rare Candy moved to the PC is not a used one.
        @reward_audit.note_items((conn.data[:item_credit] ||= RewardAudit.new_credit), Inventory.totals(bag, stores))
      end
      gift_conn = gift_conn(conn) if @gift_grants
      @mailbox.submit(account_id) do
        status = nil
        @db.transaction do
          # The row stays locked to the end: a trade swap on the pool that takes a held
          # item out of this record waits for this snapshot, or this one for it.
          prev = (@item_ledger || @gift_grants) && @db[:inventory_snapshots].where(account_id: account_id).for_update.first
          status = @inventory.apply_inv(account_id, bag, seq, stores: stores)
          if status[0] == :ack
            # Step 6: a snapshot the record adopted holds every payout the client applied
            # before it. One transaction, so a crash cannot keep the bag and lose the seal.
            @gift_grants&.seal(account_id, gift_conn) if gift_conn
            # ... and a payout it shows has reached the record, reported applied or not.
            @gift_grants&.seal_arrived(account_id, increases(prev, bag, stores, status[1]))
            judge_items(account_id, prev, bag, stores, status[1]) if @item_ledger
            clamp_bought(account_id) if @judged_local
          end
        end
        # E4: while units are owed, each judged snapshot brings the correction for its seq.
        fix = @item_enforce && status[0] == :ack ? correction_for(account_id) : nil
        @log.call("inv: account #{account_id} applied correction ##{env[:corrected]}") if env[:corrected].is_a?(Integer)
        @reactor.post do
          reply(conn, type: :inv_ack, seq: seq, flagged: status[1].any?)
          send_correction(conn, account_id, seq, fix) if fix
        end
      end
    end

    # Item authority E2: a snapshot that carries every store is judged against the totals
    # of the last one judged (inventory_snapshots.judged), so a stretch of bag-only
    # snapshots (the Bug Contest, a collection too big to send, an older client) neither
    # reads a store move as an increase nor lets an increase slip in; a bag-only snapshot
    # is recorded, never judged. The first full snapshot is the baseline. A savepoint: a
    # failed judgment never costs the snapshot, and is logged loudly.
    #
    # A Pokemon that drops out of the snapshot while the registry still gives it to the
    # account (a save that lost a traded Pokemon, a client hiding one) leaves its item in
    # inventory_snapshots.vanished: its drop settles no debt (E4), and the same Pokemon back
    # with the same item is not an increase.
    def judge_items(account_id, prev, bag, stores, flags)
      return unless stores && !flags.include?("bad_stores")

      @db.transaction(savepoint: true) do
        after  = canonical(Inventory.totals(bag, stores))
        # An account the server saw born starts from nothing: its first snapshot is judged,
        # not trusted - an older one's first snapshot is its baseline.
        base   = prev && prev[:judged] ? prev[:judged].to_h : from_zero(account_id)
        fields = { judged: Sequel.pg_jsonb(after) }
        if base
          was = prev || {}
          vanished = was[:vanished].to_h
          allow, hidden = arrivals(account_id, was[:holders].to_h, stores[:holders], vanished)
          if stores[:pc].is_a?(Hash) && !was[:pc_started] && was[:pc].nil?
            pc_start_items.each { |i, n| allow[i] += n }   # the PC item storage appeared, with its start items
          end
          @item_ledger.judge(account_id, base, after, allow: allow, local: @judged_local)
          owed = @item_ledger.open_debts(account_id)   # before this decrease settles any
          settle_spent(account_id, base, after, hidden) if @item_enforce
          lower_bp(account_id, base, after, hidden, owed)
          fields[:vanished] = Sequel.pg_jsonb(vanished)
        end
        fields[:pc_started] = true if stores[:pc].is_a?(Hash)   # a storage already there got its items long ago
        @db[:inventory_snapshots].where(account_id: account_id).update(fields)
      end
    rescue StandardError => e
      @log.call("inv: WARNING item judgment failed for account #{account_id} #{e.class}: #{e.message}")
    end

    # Money authority: no more units the server sold than the possession may still hold -
    # after every snapshot, a bag-only one too (the stores last known stand in for the
    # rest), so units used there cannot come back conjured and pass for sold ones. A
    # savepoint: the count never costs the snapshot.
    def clamp_bought(account_id)
      @db.transaction(savepoint: true) do
        row = @db[:inventory_snapshots].where(account_id: account_id).first
        next unless row && row[:bought]

        @inventory.clamp_bought(account_id, possession(row))   # the BP count: only by judged totals
      end
    rescue StandardError => e
      @log.call("inv: WARNING bought count failed for account #{account_id} #{e.class}: #{e.message}")
    end

    # What a record row says the account may hold, by canonical id: the bag and the stores
    # last known.
    def possession(row)
      stores = { pc: row[:pc].to_h, mail: row[:mailbox].to_h, held: row[:held].to_h }
      canonical(Inventory.totals(row[:bag].to_h, stores))
    end

    # Item authority, at every boot it runs: an account that never played - no save, and no
    # record that holds anything or was judged - has no history to trust, whenever it was
    # registered (item authority may have been off then): it starts from nothing, as one
    # registered now does. Idempotent - a fact at the moment judging starts. What stays
    # trusted is an account that really held items before: the cutover.
    def flag_accounts_from_zero
      saved = @db[:characters].where(account_id: Sequel[:accounts][:id])
      held  = @db[:inventory_snapshots].where(account_id: Sequel[:accounts][:id]).where(
        Sequel.lit("judged IS NOT NULL OR bag <> '{}'::jsonb OR COALESCE(pc, '{}'::jsonb) <> '{}'::jsonb " \
                   "OR COALESCE(mailbox, '{}'::jsonb) <> '{}'::jsonb OR COALESCE(held, '{}'::jsonb) <> '{}'::jsonb")
      )
      n = @db[:accounts].where(items_from_zero: false).exclude(saved.exists).exclude(held.exists).update(items_from_zero: true)
      @log.call("server: item authority: #{n} account(s) that never played start from nothing") if n.positive?
    rescue StandardError => e
      @log.call("server: WARNING item authority could not mark the accounts that never played #{e.class}: #{e.message}")
    end

    # {} for an account the server saw start from nothing - registered while item authority
    # ran, or one that had never played when the flag came (migration 040) - else nil. A
    # fact about the past only: a check of anything the client can still send (a save
    # first, say) would be one it could satisfy.
    def from_zero(account_id)
      @db[:accounts].where(id: account_id).get(:items_from_zero) ? {} : nil
    end

    # Money authority: the units battle points bought leave their count only as the
    # possession really loses units - used, tossed, given away - never as a Pokemon holding
    # one drops out of a snapshot for a while: it may come back, or arrive elsewhere
    # carrying the mark. And the units the server never recognized (+owed+, the item's open
    # debts) leave first: dropping conjured units frees no BP unit.
    def lower_bp(account_id, base, after, hidden, owed)
      row = @db[:inventory_snapshots].where(account_id: account_id).first
      bp = (row && row[:bp_bought]).to_h
      return if bp.empty?

      left = bp.to_h do |item, n|
        lost = base[item].to_i - after[item].to_i - hidden[item].to_i - owed[item].to_i
        [item, n.to_i - [lost, 0].max]
      end
      left = left.select { |_, n| n.positive? }
      @db[:inventory_snapshots].where(account_id: account_id).update(bp_bought: Sequel.pg_jsonb(left)) unless left == bp
    end

    # E4: what left the possession settles its open debts - except what a vanished Pokemon
    # took along. A pending debt settled so was spent before its verdict: unexplained all
    # the same.
    def settle_spent(account_id, base, after, hidden)
      down = base.each_with_object({}) do |(item, n), out|
        d = n.to_i - after[item].to_i - hidden[item]
        out[item] = d if d.positive?
      end
      spent, settled = @item_ledger.settle_decreases(account_id, down)
      @recent_down.note(account_id, down, settled)
      spent.each { |item, n| @log.call("inv: account #{account_id} UNEXPLAINED +#{n} #{item} (spent before its verdict)") }
      flag_anomaly(account_id, :item_unexplained) unless spent.empty?
    end

    # How much each item grew in this snapshot: over every store when it and the record
    # both carry them, else over the bag. -> { "ITEM" => n }
    def increases(prev, bag, stores, flags)
      return {} unless prev

      both = stores && !flags.include?("bad_stores") && prev[:stores_seq] == prev[:last_seq]
      was = Inventory.totals(prev[:bag].to_h, both ? { pc: prev[:pc]&.to_h, mail: prev[:mailbox].to_h, held: prev[:held].to_h } : nil)
      now = Inventory.totals(bag, both ? stores : nil)
      now.each_with_object({}) do |(k, n), out|
        up = n - was[k.to_s] - was[k.to_s.to_sym]
        out[k.to_s] = up if up.positive?
      end
    end

    # Item totals as the ledger judges them: real item ids only, and an item the engine
    # swaps for its twin (the DNA Splicers and their used form) counted as one.
    def canonical(totals)
      totals.each_with_object(Hash.new(0)) do |(k, n), out|
        id = k.to_s
        next unless id.match?(Inventory::ITEM_ID) && n.is_a?(Integer) && n.positive?

        out[@item_twins.fetch(id, id)] += n
      end
    end

    # Items the engine turns into one another with $bag.replace_item: X and XUSED (the
    # fusion items), and the Exp. All switched off. -> { twin => canonical }
    def item_twins
      ids = @battle.item_ids
      twins = ids.select { |i| i.end_with?("USED") && @battle.item_known?(i.chomp("USED")) }
                 .to_h { |i| [i, i.chomp("USED")] }
      twins["EXPALLOFF"] = "EXPALL" if @battle.item_known?("EXPALLOFF") && @battle.item_known?("EXPALL")
      twins.freeze
    end

    # The Pokemon that joined the possession holding an item, and those that left it while
    # the registry still gives them to the account (+vanished+, updated in place). One
    # back with the item it left with is not an increase; one the server delivered in a
    # trade explains its own item, once per delivery.
    # -> [allow { "ITEM" => n }, hidden { "ITEM" => n } (what vanished Pokemon took along)]
    def arrivals(account_id, before, holders, vanished)
      allow  = Hash.new(0)
      hidden = Hash.new(0)
      return [allow, hidden] unless holders.is_a?(Hash)

      holders.each do |uid, item|
        back = vanished.delete(uid.to_s)
        next if item.nil? || before.key?(uid.to_s)

        if back == item.to_s
          allow[canon(item)] += 1
        elsif @trade_deliveries&.explain(account_id, uid, item)
          allow[canon(item)] += 1
        end
      end
      gone = before.select { |uid, item| item && !holders.key?(uid.to_i) }
      unless gone.empty?
        @db[:monsters].where(id: gone.keys.map(&:to_i), owner_account_id: account_id).select_map(:id).each do |uid|
          vanished[uid.to_s] = gone[uid.to_s]
          hidden[canon(gone[uid.to_s])] += 1
        end
      end
      [allow, hidden]
    end

    def canon(item)
      @item_twins.fetch(item.to_s, item.to_s)
    end

    def key_item?(item)
      @battle.item(item.to_s)&.fetch("important", false) ? true : false
    end

    # E4's preconditions: what keeps item authority 'on' from enforcing. -> [what is missing]
    def enforce_blockers
      out = []
      out << "PEMK_PICKUP_ENFORCE=on" unless @config.pickup_enforce
      out << "PEMK_GIFT_ENFORCE=on" unless @config.gift_enforce == :on
      out << "PEMK_SHOP_ENFORCE=on" unless @config.shop_enforce == :on
      out << "trade redelivery" unless @config.trade_redelivery
      out << "PEMK_ITEM_RECORD=full" unless @config.item_record == :full
      out << "complete exports (one debug launch regenerates them)" unless @item_tiers&.complete?
      out
    end

    # E4: the owed units a correction takes back - never a local item or a key item, whose
    # owed debts (a tier changed since) are dropped. -> { Symbol => n } | nil
    def correction_for(account_id)
      owed = @item_ledger.owed(account_id)
      stale = owed.keys.select { |i| @judged_local.include?(i) || key_item?(i) }
      @item_ledger.drop_owed(account_id, stale)
      owed = owed.reject { |i, _| stale.include?(i) }
      owed.empty? ? nil : owed.to_h { |i, n| [i.to_sym, n] }
    end

    # Reactor thread: +items+ back from +conn+, bound to the snapshot seq the server judged.
    # The owed debts it covers remember that it went out, so a client that never applies
    # it is reported (settle_items).
    def send_correction(conn, account_id, seq, items)
      return unless conn && items && @reactor.alive?(conn) && Array(conn.data[:caps]).include?("inv_correct")

      id = (conn.data[:correction_id] = conn.data[:correction_id].to_i + 1)
      reply(conn, type: :inv_correct, id: id, seq: seq, items: items)
      @pool.submit do
        @item_ledger.mark_sent(account_id, items)
      rescue StandardError => e
        @log.call("inv: correction mark failed #{e.class}: #{e.message}")
      end
    end

    def pc_start_items
      Array(@battle.item_rules["start_item_storage"]).each_with_object(Hash.new(0)) { |i, h| h[i.to_s] += 1 }
    end

    # A credit from a source the server decided or checked. Its own savepoint: a failed
    # credit costs a later UNEXPLAINED line, never the source's own work.
    def credit_item(account_id, item, qty, source, ref)
      return unless @item_ledger && item

      id = @item_twins.fetch(item.to_s, item.to_s)
      @db.transaction(savepoint: true) { @item_ledger.credit(account_id, id, qty, source: source, ref: ref) }
    rescue StandardError => e
      @log.call("inv: credit failed #{e.class}: #{e.message}")
    end

    # The quantity an item ball gives, as the world export read it from its event.
    def pickup_qty(obj)
      q = obj && obj["quantity"]
      q.is_a?(Integer) && q.positive? ? q : 1
    end

    # The Premier Balls a Mart adds to a purchase of +qty+ +item+ (the engine's rule, as
    # the battle export states it; the larger reading when the export predates it).
    def premier_bonus(item, qty)
      return 0 unless qty >= 10 && @battle.item_known?("PREMIERBALL")

      if @battle.item_rules.fetch("more_bonus_premier_balls", true)
        @battle.item(item)&.fetch("is_ball", false) ? qty / 10 : 0
      else
        item == "POKEBALL" ? 1 : 0
      end
    end

    # Server-issued monster UIDs (M3.1): mint one uid per swept instance, matched by
    # the client's persisted nonce. Idempotent by the monsters_mint_dedup unique
    # index — a replayed request re-receives the SAME uids. On the mailbox like all
    # per-account mutations.
    def handle_uid_req(conn, env, account_id)
      mons = env[:mons]
      seq  = env[:seq]
      @mailbox.submit(account_id) do
        status = @monsters.mint_batch(account_id, mons)
        if status.first == :ack
          @reactor.post { reply(conn, type: :uid_grant, grants: status[1], seq: seq) }
        else
          @log.call("server: bad :uid_req from account #{account_id} -> ignored")
        end
      end
    end

    # Party projection (detection-only shadow): record + cross-check against the
    # registry, FLAG never reject, always ack.
    def handle_mon_party(conn, env, account_id)
      mons = env[:mons]
      seq  = env[:seq]
      # D4: diff per-uid levels vs the last projection on this connection; a level JUMP
      # needing more exp than a recent battle window holds is logged (detection-only —
      # Rare Candies level mons outside battle, so it never rejects). Inline pre-check.
      reward_check_levels(conn, account_id, mons) if @reward_audit
      @mailbox.submit(account_id) do
        status = @monsters.apply_party(account_id, mons, seq)
        corr = observe_exp(account_id, mons)   # D6: EXP high-water + rollback; :on -> up-only restore plan
        ack = { type: :mon_ack, seq: seq, flagged: status[1].any? }
        # D6 part 2: the plan rides the existing ack (absent in off/shadow). :level is
        # server-internal — strip it from the wire.
        ack[:exp_correct] = corr.map { |c| { uid: c[:uid], exp: c[:exp] } } if corr
        @reactor.post do
          if corr
            # Exempt the restore's own level jump from the D4 reward audit (the next
            # projection reports the restored level with NO battle window open — without
            # this the server would SUSPECT-flag its own correction). Reactor-thread
            # write, consumed one-shot by reward_check_levels (also reactor-thread).
            allowed = (conn.data[:exp_restored] ||= {})
            corr.each { |c| allowed[c[:uid]] = c[:level] if c[:level].is_a?(Integer) }
          end
          reply(conn, **ack)   # reply takes keywords (Ruby 3: no implicit hash splat)
        end
      end
    end

    # D6 (in the mailbox): track each owned mon's EXP high-water and flag a rollback
    # (reported EXP below it = old save / edit); feeds the D5 review queue.
    # -> part 2: in :on, returns the UP-ONLY restore plan [{uid:, exp: high_water}] for the
    # ack (nil when clean); re-emitted every below-frame (client's up-only guard makes a
    # re-send a no-op; the applied restore re-projects AT the high-water and the plan goes
    # empty). In :shadow the plan is LOGGED once per rollback episode (gated on the same
    # observe() latch — corrections() alone has no latch and would spam every frame).
    def observe_exp(account_id, mons)
      return nil unless @monster_stats && mons.is_a?(Array)

      entries = mons.map { |m| { uid: m[:uid], exp: m[:exp], level: m[:level], species: m[:species] } if m.is_a?(Hash) }.compact
      rollbacks = @monster_stats.observe(account_id, entries)
      unless rollbacks.empty?
        brief = rollbacks.map { |r| "uid#{r[:uid]} #{r[:from]}->#{r[:to]}" }.join(", ")
        @log.call("exp: account #{account_id} SUSPECT rollback #{brief} (reported EXP below high-water)")
        flag_anomaly(account_id, :exp_rollback)
      end
      case @config.battle_enforce_exp
      when :on
        corr = @monster_stats.corrections(account_id, entries)
        corr.empty? ? nil : corr
      when :shadow
        unless rollbacks.empty?
          plan = @monster_stats.corrections(account_id, entries)
          unless plan.empty?
            brief = plan.map { |c| "uid#{c[:uid]}->#{c[:exp]}" }.join(", ")
            @log.call("exp: account #{account_id} would restore #{brief} (shadow)")
          end
        end
        nil
      end
    rescue StandardError => e
      @log.call("exp: observe failed #{e.class}: #{e.message}")
      nil
    end

    # M4 Layer D D4: the client reports a wild battle's end (outcome + the foes it
    # fought); the server opens/extends a per-account reward budget window, but ONLY for
    # foes it can prove it minted (matched by pid in this connection's encounter stash) —
    # a fabricated :battle_end with no real foe grants no budget. Inline, no reply.
    def handle_battle_end(conn, env, account_id)
      return unless @reward_audit

      outcome = env[:outcome]
      return unless outcome.is_a?(Integer)

      foes = wild_foes(conn, env[:foes]) + trainer_foes(conn, env[:trainers])
      return if foes.empty?

      w = @reward_audit.record_battle(account_id, foes, outcome)
      @log.call("reward: account #{account_id} battle##{w[:id]} outcome=#{outcome} " \
                "foes=#{foes.map { |f| "#{f[:species]}@#{f[:level]}" }.join(',')} " \
                "budget exp=#{w[:exp]} gain=#{w[:gain]} loss=#{w[:loss]}")
    end

    # Wild foes count only as identities THIS connection was minted (matched by pid).
    def wild_foes(conn, claimed)
      return [] unless claimed.is_a?(Array)

      stash = conn.data[:enc_mints] || []
      claimed.first(2).filter_map do |f|
        next unless f.is_a?(Hash)

        m = stash.find { |x| x["pid"] == f[:pid] }
        { species: m["species"], level: m["level"] } if m
      end
    end

    # A trainer the client names counts with the party the battle data export gives
    # it, and only if one of its battles starts on the map the server last saw the
    # player on. An export that predates trainer placement accepts any known trainer.
    def trainer_foes(conn, claimed)
      return [] unless claimed.is_a?(Array) && @battle

      map = (conn.data[:last_pos] || [])[0]
      claimed.first(2).flat_map do |t|
        next [] unless t.is_a?(Array) && t.length == 3 && t[2].is_a?(Integer)

        type = t[0].to_s[0, 32]
        name = t[1].to_s[0, 32]
        party = @battle.trainer_party(type, name, t[2])
        next [] unless party
        next [] if @world.trainers_known? && !@world.trainer_on_map?(map, type, name, t[2])

        party.map { |species, level| { species: species, level: level } }
      end
    end

    # Level-jump exp bound (D4). Diffs the new projection vs the last one stashed on the
    # connection; feeds real jumps to the reward window. Runs on the reactor thread.
    def reward_check_levels(conn, account_id, mons)
      return unless mons.is_a?(Array)

      prev = conn.data[:party_levels] || {}
      restored = conn.data[:exp_restored]   # D6 part 2: uids whose next jump is the server's own restore
      cur  = {}
      changes = []
      mons.each do |m|
        next unless m.is_a?(Hash)

        uid = m[:uid]; sp = m[:species]; lvl = m[:level]
        next unless lvl.is_a?(Integer)

        cur[uid] = [sp, lvl] if uid
        old = uid && prev[uid]
        next unless old && old[0] == sp && lvl > old[1]

        # One-shot exemption: the D6 restore raises this uid's level with no battle
        # window — that jump is server-authored, not a reward claim. Exempt it only up
        # to the level the high-water recorded; anything beyond is judged normally.
        if restored && restored.key?(uid)
          allowed = restored.delete(uid)
          next if lvl <= allowed
        end
        changes << [sp, old[1], lvl]
      end
      conn.data[:party_levels] = cur

      return if changes.empty?

      suspect, detail = @reward_audit.check_levels(account_id, changes, credit: conn.data[:item_credit])
      if suspect
        @log.call("reward: account #{account_id} SUSPECT level jump — #{detail}")
        flag_anomaly(account_id, :reward_level)
      end
    end

    # Detection-only interaction audit (M4 Layer A). Runs INLINE on the reactor
    # thread like handle_presence — no mailbox, no DB, and crucially NO reply: it is
    # pure telemetry. Compares the client's interaction claim against the read-only
    # world model and logs a mismatch; it enforces nothing (enforcement is a later
    # layer). Identity is the server-trusted account_id, never a client :id.
    def handle_interact_claim(conn, env, account_id)
      # Layer C: judge the pickup against the player's SERVER-tracked tile (Layer B),
      # not the client-claimed px/py — so a remote pickup is caught. Inline + cheap.
      verdict = @audit.check_interaction(account_id, env, conn.data[:last_pos])

      # Layer C one-shot: a VALID item-ball pickup is recorded per account; a repeat
      # claim for the same tile is a dupe. The DB write goes on the per-account mailbox
      # so it never blocks the reactor. (Gifts have no fixed tile — skip them.)
      return unless verdict == :match && env[:kind] == :item

      map = env[:map]; x = env[:x]; y = env[:y]
      return unless map.is_a?(Integer) && x.is_a?(Integer) && y.is_a?(Integer)

      item = env[:item]
      obj  = @world.object_at(map, x, y)
      @mailbox.submit(account_id) do
        if @pickups.record(account_id, map, x, y) == :dup
          @log.call("audit: account #{account_id} already_taken item=#{item.to_s[0, 32]} at (#{map},#{x},#{y})")
        else
          # E2: the ball's first taking explains its item (reported after the fact, so
          # its bag snapshot may have come first: the ledger's grace covers that).
          credit_item(account_id, (obj && obj["item"]) || item, pickup_qty(obj), "pickup", "#{map}:#{x}:#{y}")
        end
      end
    end

    # Server-minted pickup (M4 Layer C): the client asks permission BEFORE adding an
    # item ball; we validate and reply :pickup_grant / :pickup_deny. Existence + item
    # + distance are judged INLINE against the world model and the player's SERVER-
    # tracked tile (never client px/py); the one-shot is then done ATOMICALLY on the
    # per-account mailbox (record -> :new grants, :dup denies), so two rapid requests
    # for one tile can never both grant. Fail-OPEN when no world is exported (an
    # operator misconfig must not brick every pickup); fail-CLOSED on any real reject.
    def handle_pickup_req(conn, env, account_id)
      seq = env[:seq]
      map = env[:map]; x = env[:x]; y = env[:y]

      verdict = @audit.check_interaction(account_id, env, conn.data[:last_pos])

      if verdict == :unchecked
        @log.call("pickup: account #{account_id} GRANT (world unexported — fail-open) seq=#{seq.inspect}")
        return reply(conn, type: :pickup_grant, seq: seq, item: env[:item], map: map, x: x, y: y)
      end
      unless verdict == :match
        return reply(conn, type: :pickup_deny, seq: seq, reason: verdict.to_s)
      end

      obj  = @world.object_at(map, x, y)
      item = (obj && obj["item"]) || env[:item]   # server-authoritative item id
      @mailbox.submit(account_id) do
        status = @pickups.record(account_id, map, x, y)
        credit_item(account_id, item, pickup_qty(obj), "pickup", "#{map}:#{x}:#{y}") if status == :new   # E2
        @reactor.post do
          next unless @reactor.alive?(conn)

          if status == :new
            reply(conn, type: :pickup_grant, seq: seq, item: item, map: map, x: x, y: y)
          else
            reply(conn, type: :pickup_deny, seq: seq, reason: "already_taken")
          end
        end
      end
    end

    # DEV/QA-ONLY pickup reset (M4 Layer C polish). Forgets this account's taken tiles
    # so its item balls can be re-tested. Fail-CLOSED: honored ONLY when the server was
    # booted with PEMK_ALLOW_PICKUP_RESET=on. In production that flag is off, so this
    # always denies — a client could otherwise wipe its pickups and re-farm every item
    # ball infinitely. The client's F9 tool only offers the reset when reconcile_block
    # advertised it, but we re-check the server flag here (never trust the client).
    def handle_pickups_reset(conn, env, account_id)
      seq = env[:seq]
      unless @config.pickup_reset_allowed
        @log.call("pickup-reset: account #{account_id} DENIED (PEMK_ALLOW_PICKUP_RESET off)")
        return reply(conn, type: :pickups_reset_deny, seq: seq, reason: "not_allowed")
      end

      @mailbox.submit(account_id) do
        n = @pickups.clear(account_id)
        @reactor.post do
          next unless @reactor.alive?(conn)

          @log.call("pickup-reset: account #{account_id} cleared #{n} tile(s) (DEV)")
          reply(conn, type: :pickups_reset_ok, seq: seq, cleared: n)
        end
      end
    end

    # M4 Layer D D1: team/set legality audit. The client reports its FULL-STAT team as
    # primitives in the envelope (never a Marshal blob); the audit validates every mon
    # against the exported battle data and logs illegal teams (detection-only — there is
    # no battle-entry gate to block yet). Always acks so the client can correlate; the
    # legality result rides the ack for future client-side UX.
    def handle_team_check(conn, env, account_id)
      verdict = @team_audit.check(account_id, env[:team])
      observe_blocks(account_id, env[:team])
      note_team_moves(conn, env[:team])
      reply(conn, type: :team_ack, seq: env[:seq], legal: (verdict[:legal] != false))
    end

    # Money authority M1a: the moves the party knows, from its last team report, and
    # whether one has Imposter - what can bring Happy Hour into a battle.
    def note_team_moves(conn, team)
      return unless team.is_a?(Array)

      mons = team.select { |m| m.is_a?(Hash) }.first(6)
      conn.data[:team_moves] = mons.flat_map { |m| Array(m["moves"] || m[:moves]) }.map(&:to_s).uniq.first(64)
      conn.data[:team_imposter] = mons.any? { |m| (m["ability"] || m[:ability]).to_s == "IMPOSTER" }
      # M1c: each Pokemon's level and moves, which bound Pay Day.
      conn.data[:team] = mons.map { |m| [(m["level"] || m[:level]).to_i, Array(m["moves"] || m[:moves]).map(&:to_s).first(4)] }
    end

    # Audit item 5: lock each owned mon's identity traits on first sight and flag a
    # later report that violates them (a counterfeit carrying a valid uid). On the
    # account mailbox — DB work, and it must serialize with the mint that creates the
    # registry row it keys on.
    def observe_blocks(account_id, team)
      return unless @monster_blocks && team.is_a?(Array)

      entries = team.map do |m|
        next unless m.is_a?(Hash)

        { uid: m["uid"] || m[:uid], species: m["species"] || m[:species],
          level: m["level"] || m[:level], ivs: m["ivs"] || m[:ivs], evs: m["evs"] || m[:evs],
          moves: m["moves"] || m[:moves], ability: m["ability"] || m[:ability],
          nature: m["nature"] || m[:nature], item: m["item"] || m[:item],
          shiny: m["shiny"].nil? ? m[:shiny] : m["shiny"],
          gender: m["gender"] || m[:gender] }
      end.compact
      return if entries.empty?

      @mailbox.submit(account_id) do
        diverged = @monster_blocks.observe(account_id, entries)
        flag_anomaly(account_id, :mon_counterfeit) unless diverged.empty?
      end
    end

    # M4 Layer D D2 (shadow): the client reports the wild encounter it rolled LOCALLY;
    # the server audits it against the Layer A encounter tables (a species absent from the
    # table = a fabricated encounter) and logs what it WOULD mint, so the roller can be
    # validated against real play before the mint is enforced (on). Fire-and-forget — no
    # reply, no gameplay effect. Cross-checks the reported map against the player's
    # server-tracked position (Layer B).
    def handle_encounter_report(conn, env, account_id)
      map     = env[:map]
      enctype = env[:enctype].to_s[0, 24]
      species = env[:species].to_s[0, 32]
      level   = env[:level]
      return unless map.is_a?(Integer) && !enctype.empty? && !species.empty?

      legal     = @encounter_mint.legal?(map, enctype, species)   # nil (no table) | true | false
      pos       = conn.data[:last_pos]
      wrong_map = pos.is_a?(Array) && pos[0] != map
      would     = @encounter_mint.roll(map, enctype)

      tag = if legal == false then "SUSPECT species-not-in-table"
            elsif wrong_map    then "SUSPECT wrong-map(on #{pos[0]})"
            else "ok"
            end
      wm = would ? "#{would['species']}@#{would['level']}#{would['shiny'] ? '/shiny' : ''}" : "-"
      @log.call("encounter: account #{account_id} #{tag} map #{map} #{enctype} " \
                "client=#{species}@#{level} server_would=#{wm}")
      flag_anomaly(account_id, :encounter_species)   if legal == false
      flag_anomaly(account_id, :encounter_wrong_map) if legal != false && wrong_map
    end

    # M4 Layer D D2 (on): server-authoritative wild-encounter MINT. The client requests an
    # encounter for (map, enctype); the server rolls the slot (species+level) from the Layer
    # A tables and mints the identity {personalID, iv[6], shiny} with SecureRandom, and the
    # client builds the wild Pokémon from it — so the server owns what appears, its level,
    # shininess and IVs (client = observer). Pure CPU (no DB), so it replies inline.
    # Fail-OPEN: a wrong-map claim or a map with no table denies, and the client falls back
    # to a local roll — wild encounters must never just stop happening.
    def handle_encounter_req(conn, env, account_id)
      seq = env[:seq]
      # Only an `on` server mints (an honest client only asks when `on` was advertised;
      # a modified one asking anyway must not get real mints recorded as provenance).
      unless @config.battle_enforce_encounters == :on
        return reply(conn, type: :encounter_deny, seq: seq, reason: "not_enforcing")
      end

      map     = env[:map]
      enctype = env[:enctype].to_s
      return reply(conn, type: :encounter_deny, seq: seq, reason: "bad_req") unless map.is_a?(Integer) && !enctype.empty?

      pos = conn.data[:last_pos]
      # No server-trusted position yet (a fresh char before its first :pos) -> can't vouch for
      # the claimed map, so deny and let the client roll LOCALLY against its real map. Otherwise
      # a client could mint from any map's table before ever sending a position.
      return reply(conn, type: :encounter_deny, seq: seq, reason: "no_pos") unless pos.is_a?(Array)

      if pos[0] != map
        @log.call("encounter: account #{account_id} req wrong-map claim #{map} (on #{pos[0]}) -> deny")
        flag_anomaly(account_id, :encounter_wrong_map)
        return reply(conn, type: :encounter_deny, seq: seq, reason: "wrong_map")
      end

      mint = @encounter_mint.roll(map, enctype)
      return reply(conn, type: :encounter_deny, seq: seq, reason: "no_table") unless mint   # unexported -> local

      # Stash the mint on the connection (last 2 — a double wild battle mints two) so a
      # following :catch_req can be adjudicated against WHAT THE SERVER MINTED — its
      # species/level/IVs — not client claims. Same per-conn pattern as :last_pos.
      stash = (conn.data[:enc_mints] ||= [])
      stash << mint
      stash.shift while stash.length > 2

      # D7 part 1: a 63-bit PCG32 battle seed is born WITH the mint when the rng seam is
      # active (63-bit: Postgres bigint is signed). In `on` the client draws the battle's
      # RNG from it; in `shadow` it is only the record<->roll correlation token. Old
      # clients ignore the extra grant key.
      seed = (SecureRandom.random_number(1 << 63) if @config.battle_enforce_rng != :off)

      # D3.2: persist the mint (durable claim-check for the caught mon's UID provenance).
      # Background on the per-account mailbox — the grant reply stays inline, and mailbox
      # FIFO guarantees this insert lands before any later catch/uid frame's DB work.
      @mailbox.submit(account_id) do
        begin
          @encounter_rolls.record(account_id, mint, map, enctype, seed: seed)
        rescue StandardError => e
          @log.call("encounter: roll persist failed #{e.class}: #{e.message}")
        end
      end

      @log.call("encounter: account #{account_id} MINT map #{map} #{enctype} -> " \
                "#{mint['species']}@#{mint['level']}#{mint['shiny'] ? ' /SHINY' : ''}")
      grant = { type: :encounter_grant, seq: seq,
                species: mint["species"], level: mint["level"],
                pid: mint["pid"], iv: mint["iv"], shiny: mint["shiny"] }
      grant[:battle_seed] = seed if seed
      reply(conn, **grant)
    end

    # Audit item 4: the switches/variables/self-switches DETECTION shadow. An absolute
    # snapshot on the account mailbox (the :inv pattern). Detection-only: a self-switch
    # REWIND (one-shot events re-armed = the NPC-gift/TM/key-item re-farm) is logged and
    # feeds the D5 review queue; nothing is ever rejected or corrected.
    def handle_flags(conn, env, account_id)
      return unless @flag_state

      seq = env[:seq]
      payload = { switches: env[:switches], variables: env[:variables],
                  self_switches: env[:self_switches], event_times: env[:event_times] }
      # A dropped job (queue full) must NOT leave the client believing its snapshot
      # landed — it would advance its seq and the server would then reject every
      # later one as stale. Nack so the client can resend.
      repair = repairs?(conn)
      queued = @mailbox.submit(account_id) do
        status, flags, plan = @flag_state.apply_flags(account_id, payload, seq, repair: repair)
        flag_anomaly(account_id, :flag_rewind) if flags&.include?("rewind")
        @reactor.post do
          reply(conn, type: :flags_ack, seq: seq, flagged: status == :ack && flags.any?)
          # Step 5: the owned values the snapshot got wrong, as the server holds them.
          if plan
            reply(conn, type: :flag_repair, seq: seq, switches: plan[:switches],
                        variables: plan[:variables], self_switches: plan[:self_switches])
          end
        end
      end
      reply(conn, type: :flags_ack, seq: seq, busy: true) unless queued
    end

    # Step 3: an intercepted-write DELTA. Fire-and-forget; the server folds it into
    # the mirror it compares against the next absolute snapshot (the trust gate).
    def handle_flag_delta(env, account_id)
      return unless @flag_state

      payload = { switches: env[:switches], variables: env[:variables],
                  self_switches: env[:self_switches], overflow: env[:overflow] }
      @mailbox.submit(account_id) { @flag_state.apply_delta(account_id, payload) }
    end

    # Audit item 4 (second half): an NPC gift / event-granted item. Fire-and-forget
    # DETECTION — the ledger records which one-shot event granted what, so a re-farm
    # (self-switch rewind -> the same event pays out again) leaves a trace naming it.
    def handle_gift_claim(env, account_id, credit: true)
      return unless @gift_claims

      map = env[:map]; event = env[:event]; item = env[:item].to_s; qty = env[:quantity]
      repeatable = repeatable_gift?(map, event)
      # E2: an event the export reads literally explains its item the first time, and
      # again while the claims ledger sees no re-farm, for one not known to pay once.
      obj  = credit && @item_ledger && literal_gift(map, event, item, qty)
      once = obj && obj["once"] == true && !repeatable
      @mailbox.submit(account_id) do
        verdict = @gift_claims.claim(account_id, map, event, item, qty, repeatable: repeatable)
        flag_anomaly(account_id, :gift_refarm) if verdict == :suspect
        credit_item(account_id, item, qty, "gift", "#{map}:#{event}") if obj && (verdict == :first || (verdict == :repeat && !once))
      end
    end

    # -> the export's entry for the event at +map+/+event+ when it gives +item+ x +qty+
    # from a literal call (never a computed one, whose item the client chose), else nil.
    def literal_gift(map, event, item, qty)
      return nil unless map.is_a?(Integer) && event.is_a?(Integer) && qty.is_a?(Integer) && qty.positive?

      obj = @world.gift_object(map, event)
      obj && obj["dynamic"] == false && gift_item_ok?(obj, item.to_s, qty) ? obj : nil
    end

    # An event the world export says pays out again by design: one with a manifest
    # cooldown (a daily NPC), or a prize table (the Game Corner lottery).
    def repeatable_gift?(map, event)
      manifest_repeatable.include?("#{map}:#{event}") || @world.prize_event?(map, event)
    end

    GIFT_ITEM = /\A[A-Z0-9_]{1,64}\z/

    # Step 6: the payout gate. The client asks before an event gives an item. A one-shot
    # gift the world export knows is granted once per account (GiftGrants); an item the
    # event never gives is refused; anything else is granted and goes to the detection
    # ledger, like a :gift_claim report. Always answered, so an honest client never sits
    # out its wait on a verdict the server reached.
    def handle_gift_req(conn, env, account_id)
      seq = env[:seq]; map = env[:map]; event = env[:event]
      item = env[:item]; qty = env[:quantity]; nonce = env[:nonce]
      unless map.is_a?(Integer) && event.is_a?(Integer) && item.is_a?(String) && item.match?(GIFT_ITEM) &&
             qty.is_a?(Integer) && qty.between?(1, 999) && nonce.is_a?(Integer) && nonce.between?(1, 2**62)
        return reply(conn, type: :gift_deny, seq: seq, reason: "bad")
      end
      # The gate is off (a restart turned it off under a live client): nothing to judge.
      return reply(conn, type: :gift_grant, seq: seq) unless @gift_grants

      obj = @world.gift_object(map, event)
      if obj && obj["dynamic"] == false && !gift_item_ok?(obj, item, qty)
        @log.call("gift: account #{account_id} #{gift_verdict_word} — map #{map} event #{event} " \
                  "never gives #{item} x#{qty} (#{Array(obj['items']).join(',')})")
        flag_anomaly(account_id, :gift_refarm)
        return reply(conn, type: :gift_deny, seq: seq, reason: "not_this_gift") if @config.gift_enforce == :on

        return reply(conn, type: :gift_grant, seq: seq)
      end

      # A gift is asked from the map its event is on. Judged for a client that sends its
      # position first (older ones could still be a map behind after a transfer).
      where = gift_away(conn, map)

      unless obj && obj["once"] == true && !repeatable_gift?(map, event)
        if where
          note_gift_away(account_id, map, event, item, where)
          return reply(conn, type: :gift_deny, seq: seq, reason: "not_here") if @config.gift_enforce == :on
        end
        # Not a one-shot: granted, and judged after the fact - which also decides whether
        # it explains its item (E2), ahead of the bag snapshot the grant leads to.
        handle_gift_claim(env, account_id, credit: where.nil?)
        return reply(conn, type: :gift_grant, seq: seq)
      end

      token = gift_conn(conn)
      literal = obj["dynamic"] == false   # the item was checked against the event's own list above
      @mailbox.submit(account_id) do
        # Only a new payout is judged by place: one asked again (its reply lost with a
        # socket, re-sent after a reconnect) was judged when it was first asked.
        remote = where && @gift_grants.first_time?(account_id, map, event)
        note_gift_away(account_id, map, event, item, where) if remote
        verdict, reason, denied = if remote && @config.gift_enforce == :on
                                    [:deny, "not_here", 0]
                                  else
                                    @gift_grants.request(account_id, map, event, item, qty, nonce, conn: token)
                                  end
        if verdict == :deny && reason != "not_here"
          @log.call("gift: account #{account_id} #{gift_verdict_word} — map #{map} event #{event} " \
                    "#{item} already paid (#{denied} refusal#{denied == 1 ? '' : 's'})")
          flag_anomaly(account_id, :gift_refarm) if denied == GiftGrants::DENY_FLAG
        elsif verdict == :grant && literal && reason.nil? && !remote
          # E2: paid once, explained once (a request sent again is the same payout).
          credit_item(account_id, item, qty, "gift", "#{map}:#{event}")
        end
        out = verdict == :deny && @config.gift_enforce == :on ? { type: :gift_deny, reason: reason } : { type: :gift_grant }
        @reactor.post { reply(conn, seq: seq, **out) if @reactor.alive?(conn) }
      rescue StandardError => e
        # No verdict: the client waits out its bound and keeps the gift pending.
        @log.call("gift: request failed #{e.class}: #{e.message}")
      end
    end

    # Item authority E3: a Mart purchase or sale, asked before it is applied. The clerk's
    # stock and the price come from the exports, the money from the ledger and, for a
    # sale, the item from the bag record. With the gate on, the server moves the money
    # itself and answers with the balance the client adopts; in shadow it only judges.
    def handle_shop_req(conn, env, account_id)
      seq = env[:seq]; op = env[:op]; item = env[:item]; qty = env[:quantity]; unit = env[:unit_price]
      nonce = @shop_deals && ShopDeals.nonce(env[:nonce])   # a deal the server records (gate on)
      return recheck_deal(conn, account_id, seq, nonce) if env[:recheck] == true

      bp = env[:bp] == true   # the Battle Point exchange: bought with BP, never sold to
      unless %i[buy sell].include?(op) && item.is_a?(String) && item.match?(GIFT_ITEM) &&
             qty.is_a?(Integer) && qty.between?(1, 999) && unit.is_a?(Integer) && unit >= 0 && !(bp && op == :sell)
        return reply(conn, type: :shop_deny, seq: seq, reason: "bad")
      end
      return reply(conn, type: :shop_grant, seq: seq) if @config.shop_enforce == :off

      why   = shop_refusal(op, env[:map], env[:event], item, unit, bp: bp)
      on    = @config.shop_enforce == :on
      field = bp ? :battle_points : :money
      shop  = bp ? "bpshop" : "shop"
      @mailbox.submit(account_id) do
        # A deal already made (its answer lost or late) is answered as it ended, never
        # run twice; a nonce asked about before it arrived is void.
        if nonce && (done = @shop_deals.find(account_id, nonce))
          out = deal_reply(done)
          @reactor.post { reply(conn, seq: seq, nonce: nonce, **out) if @reactor.alive?(conn) }
          next
        end
        balance = nil
        delta   = nil
        bonus   = 0
        why ||= "not_held" if op == :sell && !on && !@inventory.holds?(account_id, item, qty)
        @db.transaction do
          # Money authority: the units battle points bought never sell for money (Sam,
          # 2026-09-29) - the sale takes the others first. Counted before any unit leaves.
          bp_units = op == :sell && on && why.nil? && @money_claims ? bp_units_in_sale(account_id, item, qty) : 0
          # A sale the server makes takes the items out of its record with the money in,
          # so a client that keeps them cannot sell the same record again.
          if op == :sell && on && why.nil?
            owed = @item_enforce ? @item_ledger.open_debts(account_id)[canon(item)].to_i : nil
            why = "not_held" unless @inventory.take_sold(account_id, item, qty, owed: owed)
          end
          if why.nil? && on
            delta = op == :buy ? -(unit * qty) : unit * qty
            # M1d: an item the server never judged (a local tier: Pickup, mining...) sells
            # for money no source it owns explains - labelled, and left out of the shadow
            # balance.
            local = op == :sell && @judged_local&.include?(canon(item))
            # ... except the units the server itself sold the account (a resold Mart Potion).
            resold = local ? @inventory.take_bought(account_id, canon(item), qty - bp_units) : 0
            local_units = local ? qty - bp_units - resold : 0
            why = money_sale_refusal(account_id, item, qty, unit, bp_units, local_units) if op == :sell && @money_claims
            raise Sequel::Rollback if why   # nothing moves: not the items either
            label = local && local_units.positive? ? "#{shop}:sell:local:#{item}x#{qty}" : "#{shop}:#{op}:#{item}x#{qty}"
            st, value, = @ledger.adjust(account_id, field, delta, reason: label)
            if st == :ack
              balance = value
              owned = if op == :buy then delta
                      elsif !@judged_local then 0                  # no item authority: nothing is judged
                      else unit * (qty - bp_units - local_units)
                      end
              shadow_deal(account_id, delta, value - delta, item, owned: owned) if field == :money
              # A deal moves the money the prizes before it brought: those claims stay paid.
              @money_claims&.seal(account_id) if field == :money
              if op == :sell && @money_claims
                @inventory.take_bought(account_id, canon(item), bp_units, column: :bp_bought) if bp_units.positive?
                @money_daily&.add_local(account_id, unit * local_units)
              end
            else
              why = bp ? "bp" : "money"
              raise Sequel::Rollback   # nothing moves: not the items either
            end
          end
          # What the clerk sold - and the Premier Balls a Mart adds - joins the server's
          # record, as a sale's items leave it: the next snapshot shows no increase. A
          # credit would be left over there, to explain items conjured later. Without a
          # record to join (shadow, or none yet), a credit explains them instead (E2).
          if why.nil? && op == :buy
            bonus  = bp ? 0 : premier_bonus(item, qty)
            bought = { item => qty }
            bought["PREMIERBALL"] = bonus if bonus.positive?
            unless on && @inventory.add_bought(account_id, bought, canon: method(:canon), paid: !bp)
              ref = "#{env[:map]}:#{env[:event]}"
              bought.each { |i, n| credit_item(account_id, i, n, shop, ref) }
            end
          end
          if nonce && why.nil?
            @shop_deals.record(account_id, nonce, "grant", op: op, item: item, quantity: qty, field: field,
                                                           delta: delta, bonus: bonus)
          end
        end
        if why
          @log.call("#{shop}: account #{account_id} #{on ? 'DENY' : 'WOULD-DENY'} #{op} #{item} x#{qty} at #{unit} (#{why})")
        end
        out = if why && on
                { type: :shop_deny, reason: why }
              else
                { type: :shop_grant, balance: balance, delta: delta, bonus: bonus }
              end
        out[:nonce] = nonce if nonce
        @reactor.post { reply(conn, seq: seq, **out) if @reactor.alive?(conn) }
      rescue StandardError => e
        @log.call("shop: request failed #{e.class}: #{e.message}")
      end
    end

    # Money authority: of a sale of +qty+ +item+, the units battle points bought - those
    # the possession cannot leave out, since the others go first. The possession is what
    # the server judged, less what it is owed (units it never recognized): a snapshot
    # padded with conjured units frees none. Read before any unit leaves.
    def bp_units_in_sale(account_id, item, qty)
      row = @db[:inventory_snapshots].where(account_id: account_id).first
      bp = (row && row[:bp_bought]).to_h[canon(item)].to_i
      return 0 unless bp.positive?

      held = if row[:judged]
               owed = @item_enforce ? @item_ledger.open_debts(account_id)[canon(item)].to_i : 0
               row[:judged].to_h[canon(item)].to_i - owed
             else
               possession(row)[canon(item)].to_i
             end
      [qty - (held - bp), 0].max
    end

    # Money authority: a traded Pokemon's held item that battle points bought is one on the
    # receiver's side too - otherwise a second account would sell it for money (BP laundered
    # through an alt). The giver's BP units go first, as they go last in a sale.
    def carry_bp_tags(from, to, uids)
      row = @db[:inventory_snapshots].where(account_id: from).first
      return unless row && row[:bp_bought]

      holders = row[:holders].to_h
      uids.each do |u|
        item = holders[u.to_s]
        next unless item

        moved = @inventory.take_bought(from, canon(item), 1, column: :bp_bought)
        @inventory.add_bp_tag(to, canon(item), moved) if moved.positive?
      end
    end

    # Money authority (Sam, 2026-09-29): a sale may not reach into the units battle points
    # bought, nor sell more local units the server never sold than the day allows
    # (PEMK_MONEY_LOCAL_DAILY). -> the refusal when enforced, else nil: logged as what
    # enforcement would refuse.
    def money_sale_refusal(account_id, item, qty, unit, bp_units, local_units)
      why = nil
      if bp_units.positive?
        why = "bp_bought"
        detail = "#{bp_units} bought with battle points"
      elsif local_units.positive? && (cap = @config.money_local_daily)
        sold = @money_daily.local_sold(account_id)
        if sold + (unit * local_units) > cap
          why = "local_daily"
          detail = "$#{unit * local_units} of local units, $#{sold} sold today of $#{cap}"
        end
      end
      return nil unless why

      @log.call("money: account #{account_id} #{@money_enforce ? 'REFUSE' : 'WOULD-REFUSE'} sale of #{item} " \
                "x#{qty} (#{why}: #{detail})")
      @money_enforce ? why : nil
    end

    # A client that gave up waiting for a deal asks how it ended, by its nonce: the
    # recorded outcome, or - the request never having arrived - void, so a copy of it
    # still on its way is refused. A recheck never runs a deal.
    def recheck_deal(conn, account_id, seq, nonce)
      return reply(conn, type: :shop_deny, seq: seq, reason: "bad") unless nonce

      @mailbox.submit(account_id) do
        done = @shop_deals.find(account_id, nonce) || @shop_deals.void(account_id, nonce)
        out = deal_reply(done)
        @reactor.post { reply(conn, seq: seq, nonce: nonce, **out) if @reactor.alive?(conn) }
      rescue StandardError => e
        @log.call("shop: recheck failed #{e.class}: #{e.message}")
      end
    end

    # The answer a recorded deal gives when asked again: what it moved (the balance may
    # have moved since), or void - nothing moved.
    def deal_reply(done)
      return { type: :shop_grant, delta: done[:delta], bonus: done[:bonus].to_i } if done[:outcome] == "grant"

      { type: :shop_deny, reason: "void" }
    end

    # === money authority M1a: trainer prize claims ================================

    CLAIM_TRAINERS_MAX = 3   # the engine fields three trainers at most
    # Moves that set Happy Hour on the player's side, and those that can copy one (or
    # Metronome) from a battler that knows it.
    HAPPY_HOUR_MOVES = %w[HAPPYHOUR METRONOME].freeze
    COPYING_MOVES    = %w[MIMIC COPYCAT MIRRORMOVE SKETCH TRANSFORM].freeze
    PRIZE_ITEMS      = %w[AMULETCOIN LUCKINCENSE].freeze

    # A trainer battle's prize, claimed where the engine pays it (Battle#pbGainMoney).
    # Judged against the exports and recorded with its verdict; a nonce asked again gets
    # its first verdict. In shadow nothing moves: the verdicts are what M2 would pay.
    def handle_money_claim(conn, env, account_id)
      return unless @money_claims

      nonce = MoneyClaims.nonce(env[:nonce])
      amount = env[:amount]
      payday = env[:kind].to_s == "payday"   # M1c: a battle's Pay Day, apart from its prize
      trainers = payday ? nil : claim_trainers(env[:trainers])
      foes = payday ? claim_foes(env[:foes]) : nil
      proof = payday ? (foes || MoneyClaims.nonce(env[:trainer_claim])) : trainers
      unless nonce && proof && amount.is_a?(Integer) && amount.between?(0, money_cap) && env[:map].is_a?(Integer)
        (conn.data[:claims_sent] || {}).delete(nonce)   # judged, and never recorded
        return reply(conn, type: :money_claim_ack, nonce: nonce, verdict: "bad")
      end

      # A trainer battle's Pay Day whose prize claim this connection sent first.
      prize_sent = payday && (conn.data[:claims_sent] || {}).key?(MoneyClaims.nonce(env[:trainer_claim]))
      claim_sent(conn, nonce)
      @mailbox.submit(account_id) do
        done = @money_claims.find(account_id, nonce)
        # first: judged by this request - money a login's balance could not hold yet (M3).
        first = false
        # P4: the claim was held - the client took its money out of the game meanwhile.
        was_held = !done.nil? && done[:verdict] == "held" && done[:voided_at].nil?
        verdict, accepted =
          if done && done[:voided_at] then ["void", 0]   # a fresh login undid it: never paid again by its nonce
          elsif was_held                                  # P4: paid once its battle's proof is in
            settled = settle_held(account_id, done)
            first = settled[0] != "held"
            settled
          elsif done then [done[:verdict], @money_enforce ? done[:credited] : done[:accepted]]
          elsif claim_waits?(conn, account_id, env, payday, prize_sent) then ["wait", 0]
          elsif payday && foes.nil? && prize_held?(account_id, env) then ["held", 0]   # P4: as its prize is
          else
            first = true
            payday ? judge_payday(conn, account_id, nonce, env, foes) : judge_claim(conn, account_id, nonce, env, trainers)
          end
        # Trainer proof P3: the battle the claim names, for its replay's verdict (shadow -
        # under enforcement a held claim is linked as it is judged).
        if first && trainers && @trainer_proofs && !@trainer_enforce
          @trainer_proofs.link_claim(account_id, nonce, env[:seed], trainers)
        end
        ack = { type: :money_claim_ack, nonce: nonce, verdict: verdict, accepted: accepted, first: first }
        ack[:held] = true if was_held   # its money comes back with what is paid, in any mode
        if verdict == "held" && (wait = held_wait(account_id, nonce))
          ack[:wait] = wait             # when to ask again: the allowance has room tomorrow
        end
        @reactor.post do
          reply(conn, **ack) if @reactor.alive?(conn)
        end
      rescue StandardError => e
        @log.call("money: claim failed #{e.class}: #{e.message}")
      end
    end

    CLAIMS_SENT_MAX = 64

    # The claims this connection sent, in order - its reactor's alone, over-budget ones
    # included (they go out again): the prize claim a Pay Day follows is known coming.
    def claim_sent(conn, value)
      nonce = MoneyClaims.nonce(value)
      return unless nonce

      sent = (conn.data[:claims_sent] ||= {})
      sent[nonce] = true
      sent.shift if sent.size > CLAIMS_SENT_MAX
    end

    # A claim is judged with what this connection reported: none before its position
    # (where the trainer stood), nor - Pay Day, or a claim stating Happy Hour - before its
    # team (what bounds the one and brings the other); and a trainer battle's Pay Day not
    # before the prize claim sent ahead of it has a verdict. "wait" is not recorded: the
    # client asks again.
    def claim_waits?(conn, account_id, env, payday, prize_sent)
      return true if !payday && claim_away(conn, account_id, env[:map]) == :unknown
      return true if (payday || env[:happy_hour] == true) && conn.data[:team].nil?

      prize_sent && @money_claims.find(account_id, MoneyClaims.nonce(env[:trainer_claim])).nil?
    end

    # -> a wild battle's foes' pids (one or two, distinct) | nil
    def claim_foes(list)
      return nil unless list.is_a?(Array) && list.length.between?(1, 2) && list.uniq.length == list.length
      return nil unless list.all? { |p| p.is_a?(Integer) && p.between?(0, 0xFFFF_FFFF) }

      list
    end

    # === money authority M1c: Pay Day ==============================================

    PAYDAY_USES_PER_FOE = 10    # the turns one foe Pokemon can last, generously
    PP_UP_FACTOR        = 1.6   # three PP Ups

    # A battle's Pay Day, claimed where the engine pays it. A wild battle's foes must be the
    # server's own mints for this account, fresh and never claimed for Pay Day - without
    # D2's mints nothing proves the battle, and the claim is only bounded ("unminted"). A
    # trainer battle's prize claim must have been judged payable. The bound: 5 x the level
    # of the strongest party Pokemon that could use it x the uses its PP and the foes
    # allow, doubled per multiplier fact.
    def judge_payday(conn, account_id, nonce, env, foes)
      amount = env[:amount]
      verdict = nil
      label = nil
      rolls = nil
      trainers = []
      prize = nil
      turns = nil
      if foes
        if @config.battle_enforce_encounters == :on
          rolls = @money_claims.payday_rolls(account_id, foes)
          verdict = "unproven" unless rolls
        else
          label = "unminted"
        end
        foe_count = foes.length
        foe_moves = Array(rolls).flat_map { |r| wild_moves(r[:species], r[:level]) }
        # A mint is handed out on request: at most one use per second of the battle it
        # was minted for, since the claim leaves when that battle pays.
        turns = (Time.now - rolls.map { |r| r[:created_at] }.min).floor if rolls
      else
        prize = @money_claims.find(account_id, MoneyClaims.nonce(env[:trainer_claim]))
        ok = prize && MoneyClaims::PAID.include?(prize[:verdict]) && prize[:voided_at].nil?
        verdict = "unproven" unless ok
        verdict ||= "spent" if prize && prize[:payday_at]   # a battle scatters its coins once
        trainers = ok ? prize[:trainers].to_a : []
        parties = trainers.map { |t| @battle.trainer_party(t[0], t[1], t[2]) || [] }
        foe_count = [parties.sum(&:length), 1].max
        foe_moves = parties.flatten(1).flat_map { |p| Array(p[3]) }
      end
      bound = payday_bound(conn, foe_count, foe_moves, turns: turns)
      bound *= 2 if env[:amulet] == true && prize_item_held?(account_id, env[:partner])
      bound *= 2 if env[:happy_hour] == true && happy_hour_possible?(conn, trainers)
      accepted = verdict ? 0 : [amount, bound].min
      verdict ||= amount > bound ? "suspect" : "paid"
      left = payday_left(account_id)
      if accepted > left
        accepted = left
        verdict = "capped"   # the day's Pay Day allowance, until battle records prove the uses
      end
      credited = 0
      @db.transaction do
        before = money_row(account_id)
        credited = pay_claim(account_id, nonce, "payday", accepted)
        @money_claims.record(account_id, nonce, verdict: verdict, mode: money_mode, amount: amount, accepted: accepted,
                                                map: env[:map], trainers: trainers, kind: "payday", credited: credited)
        if MoneyClaims::PAYDAY_SPENDS.include?(verdict)
          @money_claims.stamp_payday(rolls) if rolls
          @money_claims.stamp_prize_payday(account_id, prize[:nonce]) if prize
        end
        @money_shadow&.claim(account_id, accepted, before: before) if accepted.positive?
      end
      # P4: the Pay Day of a battle no replay proves (its prize from the allowance, or waiting
      # for room in it) is not paid - nor a sign of a cheat
      unproven_prize = prize && (prize[:verdict] == "allowance" || prize[:proof] == "unprovable")
      note_payday(account_id, verdict, amount, accepted, bound, label, flag: !unproven_prize)
      [verdict, @money_enforce ? credited : accepted]   # M3: what the client keeps is what was paid
    end

    # -> what the account may still be credited for Pay Day today.
    def payday_left(account_id)
      cap = @config.money_payday_daily
      return Float::INFINITY unless cap

      [cap - @money_claims.payday_today(account_id), 0].max
    end

    # 5 x level per use, as the engine scatters it (AddMoneyGainedFromBattle): the party
    # Pokemon that know Pay Day or Metronome - or a copying move, when a foe knows Pay Day
    # - bound the level and the uses their PP allows; the foes bound the turns.
    def payday_bound(conn, foes, foe_moves, turns: nil)
      copying = foe_moves.map(&:to_s).include?("PAYDAY")
      best = 0
      pp = 0
      Array(conn.data[:team]).each do |level, moves|
        usable = moves & %w[PAYDAY METRONOME]
        usable |= (moves & COPYING_MOVES) if copying
        next if usable.empty?

        best = [best, level.to_i].max
        pp += usable.sum { |mv| ((@battle.move(mv) || {})["pp"].to_i * PP_UP_FACTOR).floor }
      end
      return 0 if best.zero?

      uses = [pp, PAYDAY_USES_PER_FOE * foes].min
      uses = [uses, turns].min if turns
      5 * best * uses
    end

    # A wild foe's moves: the last four it learned by its level (Pokemon#reset_moves).
    def wild_moves(species, level)
      learned = Array((@battle.species(species.to_s) || {})["level_up_moves"])
                .select { |lvl, _| lvl.to_i <= level.to_i }.map { |_, mv| mv.to_s }
      learned.reverse.uniq.reverse.last(4)
    end

    def note_payday(account_id, verdict, amount, accepted, bound, label, flag: true)
      tag = label ? " (#{label})" : ""
      case verdict
      when "paid"
        @log.call("money: account #{account_id} pay day #{amount} (bound #{bound})#{tag}")
      when "suspect"
        @log.call("money: account #{account_id} SUSPECT pay day #{amount} over its bound #{bound}#{tag}")
        flag_anomaly(account_id, :money_suspect)
      when "capped"
        @log.call("money: account #{account_id} pay day #{amount} capped at #{accepted} (the day's allowance)#{tag}")
      else
        @log.call("money: account #{account_id} WOULD-REFUSE pay day #{amount} (#{verdict})")
        flag_anomaly(account_id, :money_claim) if flag
      end
    end

    # -> [[type, name, version, map, event], ...] (distinct, at most three) | nil
    def claim_trainers(list)
      return nil unless list.is_a?(Array) && list.length.between?(1, CLAIM_TRAINERS_MAX)

      out = list.map do |t|
        return nil unless t.is_a?(Array) && t.length == 5 && t[2].is_a?(Integer) && t[3].is_a?(Integer) && t[4].is_a?(Integer)

        [t[0].to_s[0, 32], t[1].to_s[0, 32], t[2], t[3], t[4]]
      end
      # One battle names each trainer once - the same one placed on two events (a double
      # battle's pair) is not two prizes. (Two versions of one trainer: one_battle?.)
      out.map { |t| t[0, 3] }.uniq.length == out.length ? out : nil
    end

    def money_cap
      @config.economy_caps.fetch(:money, 999_999)
    end

    # -> [verdict, accepted], judged once this connection has a position (claim_waits?).
    def judge_claim(conn, account_id, nonce, env, trainers)
      map = env[:map]
      where = claim_away(conn, account_id, map)
      verdict = where ? "away" : nil
      verdict ||= "unknown" unless one_battle?(trainers)
      bound = 0
      keys = []
      rematch = false
      again = false   # a battle the game lets be fought again (not by the phone)
      trainers.each do |type, name, version, tmap, event|
        prize = @battle.trainer_prize(type, name, version)
        place = tmap == map ? @world.trainer_place(tmap, event, type, name, version) : nil
        unless prize && place
          verdict ||= "unknown"
          next
        end
        bound += prize
        verdict ||= "no_money" if place["no_money"]   # the engine pays nothing: no client claims it
        verdict ||= claim_repeat(account_id, type, name, version, tmap, event, place)
        rematch ||= place["rematch"]
        again ||= place["repeatable"]
        keys << MoneyClaims.trainer_key(type, name, version) unless place["repeatable"]   # its event is its clock
        keys << MoneyClaims.event_key(tmap, event, place["page"]) unless place["rematch"]
      end
      # P4: a battle recorded on its seed had no partner at the player's side (the recorder
      # arms none) - its prize is no partner's Amulet Coin's.
      partner = @trainer_enforce && env.key?(:seed) ? nil : env[:partner]
      bound *= 2 if env[:amulet] == true && prize_item_held?(account_id, partner)
      bound *= 2 if env[:happy_hour] == true && happy_hour_possible?(conn, trainers)
      amount = env[:amount]
      accepted = verdict ? 0 : [amount, bound].min
      verdict ||= amount > bound ? "suspect" : "paid"
      # A battle the game lets be fought again - by design, or by the phone: a claim
      # proves no fight, so the day's allowance bounds what it pays until battle records do.
      again_any = again || rematch
      if again_any && (cap = @config.money_repeat_daily)
        left = [cap - @money_claims.repeat_today(account_id), 0].max
        if accepted > left
          @log.call("money: account #{account_id} prize #{accepted} held to #{left} (the day's allowance for battles fought again)")
          accepted = left
        end
      end
      # P4: under enforcement a payable prize waits for its battle's proof - or, when no
      # replay can prove it, for room in the day's small allowance.
      gate = @trainer_enforce && MoneyClaims::PAID.include?(verdict) ? proof_gate(account_id, env, trainers) : nil
      credited = 0
      why = nil
      proof = nil
      @db.transaction do
        before = money_row(account_id)
        case gate&.first
        when :hold then verdict = "held"   # its would-be pay kept in accepted, nothing credited yet
        when :refuse then verdict, accepted, proof, why = "refuted", 0, gate[1], gate[2]
        when :allowance
          why = gate[1]
          if (pay = allowance_pay(account_id, accepted))
            verdict, accepted = "allowance", pay
            @money_daily.add_unproven(account_id, pay)
          else
            verdict, proof = "held", "unprovable"   # paid once the allowance has room
          end
        end
        credited = pay_claim(account_id, nonce, "prize", accepted) unless verdict == "held"
        @money_claims.record(account_id, nonce, verdict: verdict, mode: money_mode, amount: amount, accepted: accepted,
                                                map: map, trainers: trainers, credited: credited,
                                                kind: again_any ? "repeatable" : "trainer",
                                                trainer_battle_id: gate&.first == :hold ? gate[1][:id] : nil,
                                                proof: proof)
        # held: its battle's keys reserved - no second claim for it while the proof comes
        @money_claims.pay(account_id, keys.uniq, nonce, rematch: rematch || again) if MoneyClaims::KEYED.include?(verdict)
        @money_shadow&.claim(account_id, accepted, before: before) if accepted.positive? && verdict != "held"
        # A battle paid before, fought again: its prize in the next frame is a repeat.
        # (what the battle pays by the server's own count, not what the client states) So
        # is a battle the game lets be fought again, fought before its cadence.
        if verdict == "repeat" || (verdict == "cadence" && again)
          @money_shadow&.repeat(account_id, [amount, bound].min, before: before)
        end
      end
      note_claim(account_id, verdict, amount, accepted, bound, trainers, where, again: again, why: why)
      # a claim over its bound stays a sign, whatever the proof gate made of it
      flag_anomaly(account_id, :money_suspect) if gate && amount > bound
      [verdict, @money_enforce ? credited : accepted]   # M3: what the client keeps is what was paid
    end

    # === trainer proof P4: a prize paid on its battle's replay =======================

    # P4: what a payable prize needs before it is paid (under enforcement). A battle the
    # recorder arms - one trainer, alone in its battle, no partner at the player's side -
    # names its seed and is held until its replay's verdict. A claim that names no seed
    # is paid from the day's allowance: no replay can prove it (a double battle, a battle
    # fought offline or before its seed came - or a client that never asked: the allowance
    # bounds that too). -> [:hold, the seed's row] | [:allowance, why] | [:refuse, proof, why]
    def proof_gate(account_id, env, trainers)
      type, name, version, map, event = trainers.length == 1 ? trainers[0] : nil
      return [:allowance, "a battle against several trainers"] unless type
      unless @world.trainer_alone?(map, event, type, name, version)
        return [:allowance, "a battle the exports do not tell apart from a double battle"]
      end
      return [:allowance, "a battle not recorded on its seed"] unless env.key?(:seed)

      row = @trainer_proofs.seed_row(account_id, env[:seed], trainers)
      return [:refuse, "wrong_seed", "it names a seed that is not its battle's"] unless row
      return [:refuse, "wrong_seed", "another claim holds its battle"] if @money_claims.seed_claimed?(row[:id])

      [:hold, row]
    end

    # P4: what the day's allowance for the prizes no replay proves pays of +accepted+ now:
    # all of it, or - a prize over the whole allowance, on a day nothing was paid from it -
    # the allowance; nil while there is no room (the claim waits for the next UTC day).
    # An allowance of 0 pays nothing, and nothing waits.
    def allowance_pay(account_id, accepted)
      cap = @config.money_unproven_daily
      return 0 unless cap.positive?

      paid = @money_daily.unproven_paid(account_id)
      return accepted if accepted <= cap - paid
      return cap if accepted > cap && paid.zero?

      nil
    end

    # P4: when a held claim is best asked again - one waiting for room in the allowance, at
    # the next UTC day (at most an hour on); one waiting for its replay, when told (nil).
    def held_wait(account_id, nonce)
      claim = @money_claims.find(account_id, nonce)
      return nil unless claim && claim[:verdict] == "held" && claim[:proof] == "unprovable"

      now = Time.now.utc
      (Time.utc(now.year, now.month, now.day) + 86_400 - now).ceil.clamp(60, 3600)
    end

    # P4: a trainer battle's Pay Day waits while its prize waits for its replay - or, proven,
    # for the ask that pays it.
    def prize_held?(account_id, env)
      return false unless @trainer_enforce

      prize = @money_claims.find(account_id, MoneyClaims.nonce(env[:trainer_claim]))
      !prize.nil? && prize[:verdict] == "held" && [nil, "proven"].include?(prize[:proof]) && prize[:voided_at].nil?
    end

    # P4: a held claim asked again - paid once its battle's proof is in, in this answer's
    # own transaction (the sweep only decides). Proven: what was held. Unprovable: from the
    # day's allowance, once it has room. Refuted, unrecorded: nothing, and its battle stays
    # paid for - a refusal stands in every mode; with enforcement turned off since, any
    # other is paid as M3 pays it. -> [verdict, what the client keeps]
    def settle_held(account_id, claim)
      proof = claim[:proof]
      proof = "proven" if !@trainer_enforce && (proof.nil? || proof == "unprovable")
      return ["held", 0] if proof.nil?

      nonce = claim[:nonce]
      verdict = accepted = nil
      credited = 0
      @db.transaction do
        before = money_row(account_id)
        case proof
        when "proven" then verdict, accepted = "paid", claim[:accepted]
        when "unprovable"
          pay = allowance_pay(account_id, claim[:accepted])
          raise Sequel::Rollback unless pay   # no room today: it waits
          verdict, accepted = "allowance", pay
          @money_daily.add_unproven(account_id, pay)
        else verdict, accepted = "refuted", 0
        end
        credited = pay_claim(account_id, nonce, "prize", accepted)
        @money_claims.settle(account_id, nonce, verdict: verdict, accepted: accepted, credited: credited)
        @money_shadow&.claim(account_id, accepted, before: before) if accepted.positive?
      end
      return ["held", 0] unless verdict

      note_settled(account_id, claim, proof, verdict, accepted)
      [verdict, @money_enforce ? credited : accepted]
    end

    def note_settled(account_id, claim, proof, verdict, accepted)
      what = "money: account #{account_id} prize claim #{claim[:nonce]} (#{claim[:amount]})"
      case verdict
      when "paid" then @log.call("#{what} proven: paid #{accepted}")
      when "allowance" then @log.call("#{what} unprovable: paid #{accepted} from the day's allowance")
      else @log.call("#{what} REFUSED: #{proof}")   # flagged as the sweep refused it
      end
    end

    # The trainers one event battles in separate calls (a rival's branches) are not one
    # battle's foes: those a claim names from the same event must share a battle call -
    # two grunts of one name in one call are one battle. Where the export names no calls (a
    # phone contact's rematches, an older export), one version of each trainer at most.
    def one_battle?(trainers)
      trainers.group_by { |t| [t[3], t[4]] }.all? do |(tmap, event), group|
        next true if group.length < 2

        calls = group.map { |type, name, version, _, _| (@world.trainer_place(tmap, event, type, name, version) || {})["calls"] }
        next !calls.reduce(:&).empty? unless calls.include?(nil)

        group.map { |t| t[0, 2] }.uniq.length == group.length
      end
    end

    # -> nil when +map+ is where the server last saw the player (or the map just left, or
    # where the account's previous connection ended), :unknown when this connection has
    # sent no position yet, else the map the player is on.
    def claim_away(conn, account_id, map)
      cur = conn.data[:map_id]   # this connection's own report: a resume seeds last_pos from the save
      return :unknown unless cur.is_a?(Integer)
      return nil if cur == map

      left = conn.data[:left_map]
      return nil if left && left[0] == map && Process.clock_gettime(Process::CLOCK_MONOTONIC) - left[1] <= GIFT_LEFT_MAP_SEC
      return nil if @last_maps[account_id] == map
      # ... or where its last save stood, kept across a restart: a battle that ended while
      # the server was down is claimed from wherever the player walked since.
      return nil if (@characters.load_position(account_id) rescue nil)&.first == map

      cur
    end

    # -> nil when this trainer may be paid now, else why not: a battle paid already
    # ("repeat"), a rematch before its cadence ("cadence") or before the version below it
    # ("order"). A battle the game lets be fought again pays at most once per REMATCH_SEC,
    # its event the clock (Sam, 2026-09-29).
    def claim_repeat(account_id, type, name, version, map, event, place)
      if place["repeatable"]
        last = @money_claims.payout(account_id, MoneyClaims.event_key(map, event, place["page"]))
        return last && Time.now - last[:paid_at] < MoneyClaims::REMATCH_SEC ? "cadence" : nil
      end
      paid = @money_claims.payout(account_id, MoneyClaims.trainer_key(type, name, version))
      unless place["rematch"]
        return "repeat" if paid || @money_claims.payout(account_id, MoneyClaims.event_key(map, event, place["page"]))

        return nil
      end
      versions = place["versions"]
      if version > versions.min && !@money_claims.payout(account_id, MoneyClaims.trainer_key(type, name, version - 1))
        return "order"
      end
      last = @money_claims.rematch_clock(account_id, type, name)
      return "cadence" if paid && last && Time.now - last < MoneyClaims::REMATCH_SEC

      nil
    end

    # An Amulet Coin or a Luck Incense the item record holds on a party Pokemon (and
    # recognizes, with item authority on), or one the partner trainer's export gives.
    def prize_item_held?(account_id, partner)
      party = @db[:party_snapshots].where(account_id: account_id).get(:party).to_a
      uids = party.filter_map { |m| (m["uid"] || m[:uid]).to_s if m.is_a?(Hash) && (m["uid"] || m[:uid]) }
      row = @db[:inventory_snapshots].where(account_id: account_id).first
      holders = (row && row[:holders]).to_h
      held = uids.filter_map { |u| holders[u] }.map(&:to_s) & PRIZE_ITEMS
      if held.any?
        return true unless @item_ledger && row[:judged]

        judged = row[:judged].to_h
        debts = @item_ledger.open_debts(account_id)
        return true if held.any? { |i| judged[i].to_i - debts[i].to_i >= 1 }
      end
      partner_holds?(partner)
    end

    # Only the versions the game registers as a partner, when the export says (any other
    # version of that trainer is not the one fighting alongside).
    def partner_holds?(partner)
      return false unless partner.is_a?(Array) && partner.length >= 2

      (@world.partner_versions(partner[0], partner[1]) || (0..9)).any? do |v|
        party = @battle.trainer_party(partner[0].to_s, partner[1].to_s, v)
        party && party.any? { |p| PRIZE_ITEMS.include?(p[2].to_s) }
      end
    end

    # Happy Hour doubles the prize only when the player's side uses it (the engine sets
    # the effect for that side alone): a party Pokemon knows it or Metronome, or copies
    # either from a foe that knows it. The party's moves are those of the last team report.
    def happy_hour_possible?(conn, trainers)
      moves = Array(conn.data[:team_moves]).map(&:to_s)
      return true if (moves & HAPPY_HOUR_MOVES).any?
      return false if (moves & COPYING_MOVES).empty? && !conn.data[:team_imposter]

      trainers.any? { |type, name, version, _, _| @battle.trainer_knows_any?(type, name, version, HAPPY_HOUR_MOVES) }
    end

    def note_claim(account_id, verdict, amount, accepted, bound, trainers, where, again: false, why: nil)
      names = trainers.map { |t| "#{t[0]} #{t[1]} v#{t[2]}" }.join(", ")
      case verdict
      when "paid"
        @log.call("money: account #{account_id} prize #{amount} for #{names} (bound #{bound})")
      when "suspect"
        @log.call("money: account #{account_id} SUSPECT prize #{amount} over its bound #{bound} for #{names}")
        flag_anomaly(account_id, :money_suspect)
      when "held"
        until_when = why ? "the day's allowance for prizes no replay proves has room (#{why})" : "its battle's replay proves it"
        @log.call("money: account #{account_id} prize #{amount} for #{names} held until #{until_when}")
      when "allowance"
        @log.call("money: account #{account_id} prize #{amount} for #{names} paid #{accepted} from the day's allowance " \
                  "for prizes no replay proves (#{why})")
      when "refuted"
        @log.call("money: account #{account_id} REFUSED prize #{amount} for #{names}: #{why}")
        flag_anomaly(account_id, :money_claim)
      else
        @log.call("money: account #{account_id} WOULD-REFUSE prize #{amount} for #{names} (#{verdict}" \
                  "#{where ? ", on map #{where}" : ''}" \
                  "#{again && verdict == 'cadence' ? ', a battle the game lets be fought again: once per 20 minutes' : ''})")
        flag_anomaly(account_id, :money_claim) unless verdict == "repeat" || (again && verdict == "cadence")
      end
    end

    # At boot: the mode, and what the claims cannot be judged by in this configuration.
    def log_money_authority
      what = if @money_enforce then "the server pays prizes and refuses money it cannot explain"
             else "trainer prizes claimed and judged; logs only"
             end
      @log.call("server: money authority = #{@config.money_authority} (#{what})")
      return if @config.money_authority == :off

      if @config.money_authority == :on && !@money_enforce
        @log.call("server: WARNING money authority 'on' runs as shadow until: #{money_blockers.join('; ')}")
      end
      gaps = []
      gaps << "the exports place no trainer battle" unless @world.trainers_known?
      gaps << "the battle data has no base money" unless @battle.trainer_base_money(@battle.trainer_types_list.first.to_s)
      gaps << "positions are the client's word (PEMK_POS_ENFORCE is not on)" unless @config.position_enforcement == :on
      gaps << "no wild mints (D2 not on), so a wild battle's Pay Day is only bounded" unless @config.battle_enforce_encounters == :on
      again = @world.repeatable_trainers
      gaps << "the exports do not say which trainer battles can be fought again" if again.nil?
      gaps << "the exports do not say which trainers share a battle" unless @world.battle_calls_known?
      @log.call("server: money claims cannot rely on: #{gaps.join('; ')}") unless gaps.empty?
      return if again.nil? || again.empty?

      names = again.map { |m, e, type, name, v| "#{type} #{name} v#{v} (map #{m} event #{e})" }
      @log.call("server: money: battles the game lets be fought again, each paid at most once per 20 minutes: #{names.join(', ')}")
    end

    # At boot: the trainer proof's mode, what keeps 'on' from enforcing, and the battles no
    # replay can prove - under enforcement their prizes come from the day's allowance.
    def log_trainer_proof
      mode = @config.trainer_proof
      what = if @trainer_enforce
               "a trainer prize is held until its battle's replay proves it; those no replay can prove are paid " \
               "from #{@config.money_unproven_daily} a day"
             elsif @trainer_proofs then "each prize claim naming its battle gets its replay's verdict; logs only"
             else "nothing is proven"
             end
      @log.call("server: trainer proof = #{mode} (#{what})")
      return if mode == :off

      missing = []
      missing << "battle rng is not on (PEMK_BATTLE_ENFORCE_RNG): trainer battles are not seeded" unless @config.battle_enforce_rng == :on
      missing << "money authority is off (PEMK_MONEY_AUTHORITY)" if @config.money_authority == :off
      missing << "money authority does not enforce (PEMK_MONEY_AUTHORITY=on and its preconditions)" unless @money_enforce
      missing.concat(team_proof_gaps)
      if @trainer_proofs.nil?
        @log.call("server: WARNING trainer proof '#{mode}' does nothing until: #{missing.join('; ')}")
        return
      end
      @log.call("server: WARNING trainer proof 'on' runs as shadow until: #{missing.join('; ')}") if mode == :on && !@trainer_enforce
      @log.call("server: trainer proof: a prize waits for its battle's replay - run bin/pemk_replay.rb with PEMK_REPLAY_LOOP")
      shared = @world.trainers_not_alone
      return if shared.empty?

      names = shared.map { |m, e, type, name, v| "#{type} #{name} v#{v} (map #{m} event #{e})" }
      @log.call("server: trainer proof: battles with more than one trainer, never proven: #{names.join(', ')}")
    end

    # === badge authority (docs/BADGE-AUTHORITY-DESIGN.md) ============================

    BADGE_VERDICTS = { explained: "EXPLAINED", pending: "PENDING", unprovable: "UNPROVABLE", waiting: "WAITING",
                       revoked: "REVOKED", refused: "WOULD-REFUSE" }.freeze
    BADGE_ENFORCED = { explained: "OWNED", pending: "PENDING", unprovable: "UNPROVABLE", waiting: "WAITING",
                       revoked: "REVOKED", refused: "REFUSED" }.freeze
    BADGE_SAID_MAX = 100_000
    BADGE_BOOT_LINES = 200   # accounts the boot pass names one by one

    # B2: the server owns the badges - `on`, trainer proof and money enforcing, and nothing
    # keeping it from owning them.
    def badge_enforce?
      @config.badge_authority == :on && !@badge_audit.nil? && @trainer_enforce && @money_enforce && @badge_sure ? true : false
    end

    # At boot. A refusal is a sign only when nothing keeps the server from owning the
    # badges: a badge set the export cannot read, or given with no battle, may be the game's
    # own. Owning them, every client fights a badge's battle alone (badge_alone): a partner
    # who may join it keeps nothing from it. Until then a client from before may fight with
    # the partner: there it keeps the flags off.
    def weigh_badge_blockers
      @badge_alone = @config.badge_authority == :on && @trainer_enforce && @money_enforce ? true : false
      @badge_sure  = @badge_audit && badge_blockers(alone: @badge_alone).empty? ? true : false
    end

    # The battles whose win gives a badge, for the login: the clients fight them alone and
    # wait longer for their seeds wherever the server judges the badges and proves trainer
    # battles - from shadow on, so a win then is proven by the time the server owns them.
    def badge_battles_alone
      @badge_audit && @trainer_proofs ? @world.badge_battles : nil
    end

    # What keeps the server from owning the badges; +alone+: its clients fight a badge's
    # battle with no partner. The badge writes the operator ignores keep nothing.
    def badge_blockers(alone:)
      @world.badge_blockers(badges_max: @config.badges_max, alone: alone, ignore: @config.badge_ignore)
    end

    # What the client shows: pending (read first), then owned - a proof settled between the
    # two reads is in one or the other.
    def badge_shown(account_id)
      pending = @badge_audit.pending_bits(account_id)
      pending | @ledger.current(account_id, :badges).to_i
    end

    # B2, inside a proven claim's settle transaction: its win's badges become the account's.
    def badge_grant_win(claim)
      return unless badge_enforce? && BadgeAudit::KINDS.include?(claim[:kind]) && MoneyClaims::KEYED.include?(claim[:verdict])

      wins = @badge_audit.wins_in(claim)
      return if wins.empty?

      grants = wins.map do |b|
        { badge: b, evidence: "proof", source: "claim #{claim[:nonce]}", claim_nonce: claim[:nonce], since: Time.now }
      end
      @ledger.grant_bits(claim[:account_id], wins.sum { |b| 1 << b }, reason: "badge:proof:#{claim[:nonce]}", grants: grants)
    end

    # B2's boot pass, before the first frame: each account's ledger holds what the server
    # owns - its grants, at the first cutover its badges from before the authority, its
    # proven wins; pending stripped (still shown), the rest removed. `on` held back by a
    # blocker logs it as a dry run. An account it fails on keeps what it holds (no frame
    # raises it) and the pass is done again at the next boot. -> the totals
    def badge_boot_pass
      return unless @badge_audit

      apply = badge_enforce?
      return unless apply || @config.badge_authority == :on

      mark = @db[:badge_cutover].where(id: 1).first
      cutover = mark.nil?
      now = Time.now
      totals = Hash.new(0)
      named = 0
      failed = 0
      badge_boot_accounts(cutover, mark&.dig(:pass_at)).each do |id|
        held = @ledger.current(id, :badges).to_i
        plan = @badge_audit.plan(id, held, cutover: cutover)
        next if plan[:owned] == held && plan[:proof].empty? && plan[:legacy].zero?

        totals[:accounts] += 1
        %i[legacy pending].each { |k| totals[k] += @badge_audit.bits_of(plan[k]).size }
        %i[proof refused unprovable waiting revoked].each { |k| totals[k] += plan[k].size }
        if apply
          proven_at = @db[:money_claims].where(account_id: id, nonce: plan[:proof].values).select_hash(:nonce, :proof_at)
          grants = @badge_audit.bits_of(plan[:legacy]).map { |b| { badge: b, evidence: "legacy", source: "cutover" } } +
                   plan[:proof].map { |b, n| { badge: b, evidence: "proof", source: "claim #{n}", claim_nonce: n, since: proven_at[n] } }
          @ledger.rebase_badge_bits(id, add: plan[:owned] & ~held, remove: held & ~plan[:owned], reason: "badge:boot",
                                        grants: grants)
          # a sign at the cutover only: later, a period with the authority off trusted the clients
          @anomaly&.record_flag(id, :badge_unexplained) if cutover && !plan[:refused].empty?
        end
        next if (named += 1) > BADGE_BOOT_LINES

        @log.call("badge: #{apply ? '' : '(dry run) '}boot account #{id}: #{badge_plan_words(plan)}")
      rescue StandardError => e
        failed += 1
        @log.call("badge: WARNING the boot pass skipped account #{id}: #{e.class}: #{e.message}")
      end
      if apply && failed.zero?
        cutover ? @db[:badge_cutover].insert(id: 1, at: now, pass_at: now) : @db[:badge_cutover].where(id: 1).update(pass_at: now)
      elsif apply
        @log.call("badge: WARNING the boot pass skipped #{failed} account(s): it is done again at the next boot")
      end
      @log.call("badge: #{apply ? '' : '(dry run) '}boot pass#{cutover ? ' (the cutover)' : ''}: " \
                "#{totals[:accounts]} account(s) - legacy #{totals[:legacy]}, proof #{totals[:proof]}, " \
                "pending #{totals[:pending]} stripped, refused #{totals[:refused]}, unprovable " \
                "#{totals[:unprovable]}, waiting #{totals[:waiting]} and revoked #{totals[:revoked]} removed" \
                "#{named > BADGE_BOOT_LINES ? " (#{named - BADGE_BOOT_LINES} not named)" : ''}")
      totals
    rescue StandardError => e
      @log.call("badge: WARNING the boot pass failed #{e.class}: #{e.message}")
      nil
    end

    # Row 2 of badge_cutover says the server enforces - written at an enforcing boot, gone at
    # any other, whether or not a boot pass ended whole. The replay daemon told nothing
    # follows it at each pass.
    def badge_mark_enforcing
      if badge_enforce?
        now = Time.now
        @db[:badge_cutover].insert_conflict(target: :id, update: { at: now }).insert(id: 2, at: now)
      else
        @db[:badge_cutover].where(id: 2).delete
      end
    rescue StandardError => e
      @log.call("badge: WARNING marking the badge authority failed #{e.class}: #{e.message}")
    end

    # The accounts the boot pass looks at: at the cutover, every one holding, granted or
    # with a baseline of a badge (a stale frame may have zeroed its ledger); after it, those
    # whose ledger is not their grants (a period with the authority off) and those with a
    # win proven since the last whole pass (a proof settled while it did not enforce) -
    # each with any proven win at the cutover.
    def badge_boot_accounts(cutover, since)
      held = @db[:economy_balances].where(field: "badges").select_hash(:account_id, :balance)
      granted = Hash.new(0)
      @db[:badge_grants].exclude(evidence: "revoked").select(:account_id, :badge)
                        .each { |g| granted[g[:account_id]] |= 1 << g[:badge] }
      proven = @db[:money_claims].where(kind: BadgeAudit::KINDS, verdict: MoneyClaims::KEYED, proof: "proven",
                                        map: @world.badge_maps)
      proven = proven.where { proof_at > since } if since && !cutover
      ids = proven.distinct.select_map(:account_id)
      ids += if cutover
               held.select { |_, b| b.to_i != 0 }.keys + granted.keys +
                 @db[:badge_baselines].exclude(mask: 0).select_map(:account_id)
             else
               (held.keys | granted.keys).select { |id| held[id].to_i != granted[id] }
             end
      ids.uniq.sort - Forget.new(@db).forgotten_among(ids.uniq)   # a forgotten account plays no more
    end

    def badge_plan_words(plan)
      list = ->(mask) { @badge_audit.bits_of(mask).join(", ") }
      out = ["owns #{list.(plan[:owned]).then { |s| s.empty? ? 'none' : s }}"]
      out << "legacy #{list.(plan[:legacy])}" unless plan[:legacy].zero?
      out << "proven #{plan[:proof].map { |b, n| "#{b} (claim #{n})" }.join(', ')}" unless plan[:proof].empty?
      out << "pending #{list.(plan[:pending])} (shown, not owned)" unless plan[:pending].zero?
      out << "removed #{plan[:refused].map { |b, why| "#{b} (#{why})" }.join(', ')}" unless plan[:refused].empty?
      unless plan[:unprovable].empty?
        out << "removed unprovable #{plan[:unprovable].map { |b, why| "#{b} (#{why})" }.join(', ')} " \
               "- bin/pemk_badges.rb grant if it was earned"
      end
      out << "waiting #{plan[:waiting].map { |b, why| "#{b} (#{why})" }.join(', ')}" unless plan[:waiting].empty?
      out << "revoked #{plan[:revoked].map(&:first).join(', ')}" unless plan[:revoked].empty?
      out.join("; ")
    end

    # B1: on the account's mailbox, before the frame is applied - the bits it adds to the
    # ledger's and to its baseline, each judged; shadow logs and flags what enforcement
    # would refuse. +seeds+: the client asks a trainer battle's seed (trainer proof).
    def judge_badges(account_id, value, seq, seeds: false)
      # what the ledger refuses (over the cap, a bad seq) or has applied already is not judged
      return unless value.is_a?(Integer) && value.between?(0, @config.economy_caps[:badges]) && Ledger.seq_ok?(seq)
      return if @ledger.recorded?(account_id, :badges, seq)

      held = @ledger.current(account_id, :badges).to_i
      # the baseline was earned before the authority (legacy at B2's cutover): a frame that
      # dropped one of its bits and gives it back is not judged
      verdicts = @badge_audit.judge(account_id, value & ~(held | badge_base(account_id, held)))
      # what was said already for these badges is not said again (a mask sent back and forth)
      fresh = @badge_mutex.synchronize do
        @badge_said.clear if @badge_said.size > BADGE_SAID_MAX
        verdicts.reject { |badge, verdict, why| @badge_said.fetch([account_id, badge], nil) == [verdict, why] }
                .each { |badge, verdict, why| @badge_said[[account_id, badge]] = [verdict, why] }
      end
      # one line per verdict and reason: a frame of many badges is a few lines, not one each
      fresh.group_by { |_, verdict, why| [verdict, why] }.each do |(verdict, why), list|
        badges = list.map(&:first)
        what = badges.one? ? "badge #{badges[0]}" : "badges #{badges.join(', ')}"
        @log.call("badge: account #{account_id} #{what} #{(badge_enforce? ? BADGE_ENFORCED : BADGE_VERDICTS).fetch(verdict)}: #{why}")
      end
      badge_flags(account_id, fresh, seeds: seeds)
    rescue StandardError => e
      @log.call("badge: judging account #{account_id} failed #{e.class}: #{e.message}")
    end

    # The account's baseline: the one kept, or +held+ now kept as it (its first judged
    # frame). Remembered, bounded.
    def badge_base(account_id, held)
      base = @badge_mutex.synchronize { @badge_based[account_id] }
      return base if base

      base = @badge_audit.baseline(account_id, held)
      @badge_mutex.synchronize do
        @badge_based.clear if @badge_based.size > BADGE_SAID_MAX
        @badge_based[account_id] = base
      end
    end

    # A refusal flags the account once per frame, when nothing keeps the server from owning
    # the badges (else the game itself may give one); a win no replay can prove, too, from
    # a client that asks for its battles' seeds - an honest one waits for them while
    # online, so a link lost as a gym battle begins is its one honest case (two flags open
    # a review, and the operator grants it).
    def badge_flags(account_id, verdicts, seeds: true)
      return unless @badge_sure

      flag_anomaly(account_id, :badge_unexplained) if verdicts.any? { |_, verdict, _| verdict == :refused }
      flag_anomaly(account_id, :badge_unprovable) if seeds && verdicts.any? { |_, verdict, _| verdict == :unprovable }
    end

    # B1, at the proof sweep, on the account's mailbox (after the frames before it): a
    # proven win would grant its badges; any other verdict drops those it showed.
    def badge_proof_logs(account_id, nonce, proof)
      wins = @badge_audit.wins_of(account_id, nonce)
      return if wins.empty?

      if proof == :proven
        wins.each { |b| @log.call("badge: account #{account_id} #{badge_enforce? ? 'GRANTED' : 'WOULD-GRANT'} badge #{b} (claim #{nonce}'s win is proven)") }
      else
        badge_drops(account_id, wins, "claim #{nonce}'s win is #{proof}")
      end
    rescue StandardError => e   # the sweep's other verdicts go on
      @log.call("badge: account #{account_id} claim #{nonce}'s badges failed #{e.class}: #{e.message}")
    end

    # B1: of the badges +wins+ gave, those the ledger holds over its baseline and nothing
    # explains now (a refused or voided claim showed them): B2 drops them from what the
    # client shows. An account never judged holds nothing gained since.
    # +flag+: false for a void - an honest client killed before its save is one too.
    # Enforced (B2), what the claim showed is its wins the ledger does not own.
    def badge_drops(account_id, wins, cause, flag: true)
      mask = wins.sum { |b| 1 << b }
      if badge_enforce?
        mask &= ~@ledger.current(account_id, :badges).to_i
      else
        base = badge_based(account_id)
        return unless base

        mask &= @ledger.current(account_id, :badges).to_i & ~base
      end
      drops = @badge_audit.judge(account_id, mask).reject { |_, verdict, _| %i[explained pending].include?(verdict) }
      drops.each { |badge, _, why| @log.call("badge: account #{account_id} #{badge_enforce? ? 'DROPPED' : 'WOULD-DROP'} badge #{badge} (#{cause}: #{why})") }
      # a refused win is a sign; one no replay could prove is the server's side (its badge's
      # next frame says UNPROVABLE once - the flag that counts)
      badge_flags(account_id, drops.select { |_, verdict, _| verdict == :refused }) if flag
    rescue StandardError => e
      @log.call("badge: account #{account_id}'s badges (#{cause}) failed #{e.class}: #{e.message}")
    end

    def badge_based(account_id)
      @badge_mutex.synchronize { @badge_based[account_id] } || @badge_audit.baseline_of(account_id)
    end

    # At boot: the mode, what it relies on, and what keeps the server from owning a badge.
    def log_badge_authority
      mode = @config.badge_authority
      what = if @badge_audit
               "each new badge judged by the battle that gives it#{badge_enforce? ? '' : '; logs only'}"
             else
               "nothing is judged"
             end
      @log.call("server: badge authority = #{mode} (#{what})")
      return if mode == :off

      if badge_enforce?
        @log.call("server: badge authority ENFORCED - a frame never moves the badges, a proven win grants them " \
                  "(clients need badge_hold and badge_alone)")
      elsif mode == :on
        why = []
        why << "trainer proof does not enforce" unless @trainer_enforce
        why << "money authority does not enforce" unless @money_enforce
        why << "what keeps it from owning the badges (below)" if @badge_audit && !badge_blockers(alone: true).empty?
        @log.call("server: WARNING badge authority 'on' runs as shadow: #{why.join(', ')}") unless why.empty?
      end
      unless @badge_audit
        @log.call("server: WARNING badge authority does nothing: it judges by the trainer prize claims " \
                  "(PEMK_MONEY_AUTHORITY is off)")
        return
      end
      unless @trainer_proofs
        @log.call("server: WARNING badge authority: no trainer proof (PEMK_TRAINER_PROOF, PEMK_BATTLE_ENFORCE_RNG=on) - " \
                  "no badge is ever explained")
      end
      alone = badge_battles_alone
      unless alone.nil? || alone.empty?
        @log.call("server: badge authority: #{alone.size} battle(s) whose win gives a badge are fought alone, " \
                  "their seeds waited for longer")
      end
      unless @config.badge_ignore.empty?
        hit, miss = @config.badge_ignore.partition { |k| @world.badge_ignorable.include?(k) }
        @log.call("server: badge authority: no badge from #{hit.join(', ')} (PEMK_BADGE_IGNORE: refused, " \
                  "as any no win explains)") unless hit.empty?
        @log.call("server: WARNING PEMK_BADGE_IGNORE names #{miss.join(', ')}: no badge write it ignores there " \
                  "(one the export cannot read, or that gives a badge with no battle)") unless miss.empty?
      end
      # what would keep it from owning them - its clients then fight a badge's battle alone
      blockers = badge_blockers(alone: true)
      @log.call("server: badge authority cannot own: #{blockers.join('; ')}") unless blockers.empty?
      return if badge_enforce? || !blockers.empty? || @badge_sure

      @log.call("server: badge authority: a partner may join a badge's battle - until the server owns the badges " \
                "(every client then fights it alone), a refusal flags no one")
    end

    # What keeps a replay from checking the player's team against the server's own: the
    # first-sight lock (IVs, shiny, gender) comes with D1, the EXP seen with D6.
    def team_proof_gaps
      out = []
      out << "the team lock is off (PEMK_BATTLE_ENFORCE_TEAMS): a record's IVs are its word" if @config.battle_enforce_teams == :off
      out << "EXP tracking is off (PEMK_BATTLE_ENFORCE_EXP): a record's levels are its word" if @config.battle_enforce_exp == :off
      out
    end

    # M3: an account with no money yet starts from the exported start money - the client
    # would otherwise seed the ledger with its save's value, which enforcement refuses and
    # could not trust. It adopts the seeded balance with the login.
    def seed_start_money(account_id)
      return unless @money_enforce && money_row(account_id).nil? && @battle.start_money.to_i.positive?

      @ledger.adjust(account_id, :money, @battle.start_money, reason: "start")
    end

    # M3's preconditions: what keeps money authority 'on' from enforcing - every way money
    # can rise must be a transaction the server makes or bounds. -> [what is missing]
    def money_blockers
      out = []
      out << "D2 is not on (PEMK_BATTLE_ENFORCE_ENCOUNTERS): a wild Pay Day has no proof" unless @config.battle_enforce_encounters == :on
      out << "Pay Day has no daily allowance (PEMK_MONEY_PAYDAY_DAILY=none)" unless @config.money_payday_daily
      out << "the shop gate is not on (PEMK_SHOP_ENFORCE)" unless @config.shop_enforce == :on
      out << "item authority does not enforce (PEMK_ITEM_AUTHORITY=on and its preconditions)" unless @item_enforce
      out << "local sales have no daily allowance (PEMK_MONEY_LOCAL_DAILY=none)" unless @config.money_local_daily
      if @config.money_repeat_daily.nil? && (Array(@world.repeatable_trainers).any? || @world.rematches_placed?)
        out << "battles fought again have no daily allowance (PEMK_MONEY_REPEAT_DAILY=none)"
      end
      out << "the exports place no trainer battle" unless @world.trainers_known?
      out << "the exports do not say which trainer battles can be fought again" if @world.repeatable_trainers.nil?
      out << "the exports do not say which trainers share a battle" unless @world.battle_calls_known?
      out << "the battle data has no base money" unless @battle.trainer_base_money(@battle.trainer_types_list.first.to_s)
      out << "the battle data has no start money" unless @battle.start_money.is_a?(Integer)
      sources = unbounded_money_sources
      if sources.nil?
        out << "the exports predate the money sources"
      elsif sources.any?
        out << "events raise money by themselves (until the event money gate): #{sources.join(', ')}"
      end
      out
    end

    # The events that raise money by themselves - money an honest player gets that no
    # claim names: every exported source of money but the Triple Triad sales the client
    # closes while enforcement runs (Sam, 2026-09-29). -> ["map 5 event 3 (change_gold)",
    # ...], or nil for an export from before the sources.
    def unbounded_money_sources
      doc = @world.money_sources
      return nil unless doc

      Array(doc["events"]).filter_map do |e|
        next unless e.is_a?(Hash) && Array(e["fields"]).include?("money")

        calls = Array(e["calls"]) - ["pbSellTriads"]
        next if calls.empty?

        where = e["common_event"] ? "common event #{e['common_event']}" : "map #{e['map']} event #{e['event']}"
        "#{where} (#{calls.join(', ')})"
      end
    end

    # A fresh login: a claim that neither a money frame nor a save sealed may be missing
    # from the save it loads, so its battle may be fought and claimed again.
    def void_claims(account_id)
      return unless @money_claims

      kept = 0
      voided = @db.transaction do   # every void with its take-back, or none
        @money_claims.void_unsealed(account_id) do |c|
          undone = take_back(account_id, c)
          if undone
            # (a held claim never reached the shadow balance: nothing to take out of it)
            @money_shadow&.void(account_id, c[:accepted], before: money_row(account_id)) if c[:accepted].positive? && c[:verdict] != "held"
          else
            kept += 1
          end
          undone
        end
      end
      @log.call("money: account #{account_id} voided #{voided.size} unsealed prize claim(s) at login") unless voided.empty?
      # badge authority B1: a badge a voided claim's win showed goes with it (B2)
      if @badge_audit
        voided.select { |c| BadgeAudit::KINDS.include?(c[:kind]) }.each do |c|
          badge_drops(account_id, @badge_audit.wins_in(c), "claim #{c[:nonce]} is void", flag: false)
        end
      end
      return if kept.zero?

      @log.call("money: account #{account_id} kept #{kept} unsealed prize claim(s): their money was spent")
    rescue StandardError => e
      # Never a login's end: the claims stay as they were, for the next one.
      @log.call("money: WARNING voiding the claims of account #{account_id} failed #{e.class}: #{e.message}")
    end

    # M3: a voided claim's payment leaves the ledger - all of it, or the claim is kept (its
    # battle stays paid): taking back only part would let it be claimed again for the rest.
    # -> undone?
    def take_back(account_id, claim)
      amount = claim[:credited].to_i
      return true unless amount.positive?
      return false if money_row(account_id).to_i < amount

      st, = @ledger.adjust(account_id, :money, -amount, reason: "void:#{claim[:nonce]}")
      st == :ack
    end

    # M3: what the server itself pays for an accepted claim, in its verdict's transaction -
    # up to the balance cap, as the engine adds it. -> what it paid (nothing in shadow).
    def pay_claim(account_id, nonce, kind, accepted)
      return 0 unless @money_enforce && accepted.positive?

      pay = [accepted, money_cap - money_row(account_id).to_i].min
      return 0 unless pay.positive?

      st, = @ledger.adjust(account_id, :money, pay, reason: "#{kind}:#{nonce}")
      st == :ack ? pay : 0
    end

    # The mode claims are judged in: "on" only while enforcement runs ('on' with a
    # blocker left runs as shadow).
    def money_mode
      return "off" unless @money_claims

      @money_enforce ? "on" : "shadow"
    end

    # --- money authority M1b: the shadow balance -----------------------------------

    # -> the ledger's money balance, or nil when the account has no money row yet.
    def money_row(account_id)
      @db[:economy_balances].where(account_id: account_id, field: "money").get(:balance)
    end

    # A deal the server made moved the money: the shadow balance moves with it. A
    # purchase it cannot cover spent money no source explains.
    # M1d: +owned+ - the part of a deal the server owns. A sale of items it never judged (nor
    # sold itself) moves the client's balance, not the shadow balance, and is named.
    def shadow_deal(account_id, delta, before, item, owned: delta)
      return unless @money_shadow

      short = @money_shadow.deal(account_id, delta, before: before, credit: owned)
      unowned = delta - owned
      @log.call("money: account #{account_id} UNOWNED-SOURCE +#{unowned} (sold #{item}, never judged)") if unowned.positive?
      return unless short.positive?

      @log.call("money: account #{account_id} BOUGHT-UNEXPLAINED #{item} with #{short} no source explains")
      flag_anomaly(account_id, :money_unexplained)
    end

    # A fresh, acked money frame from the account's current connection: what it shows
    # that no source explains. Frames of a session another login replaced do not count.
    def shadow_frame(account_id, value, before)
      return unless @money_shadow

      d, repeated = @money_shadow.frame(account_id, value, before: before)
      @log.call("money: account #{account_id} REPEAT +#{repeated} (a prize paid before)") if repeated.positive?
      return unless d.positive?

      @log.call("money: account #{account_id} UNEXPLAINED +#{d}")
      flag_anomaly(account_id, :money_unexplained)
    end

    # -> nil when the export allows it, else why not. A purchase needs a clerk the world
    # export knows (a Mart, or the Battle Point exchange for +bp+), an item in its stock
    # (any item for a computed stock, never a free one) and a price one of its event's
    # Mart calls can charge, in money or BP; a sale needs a sellable item at a price the
    # clerk can pay back, from a clerk that buys anything back.
    def shop_refusal(op, map, event, item, unit, bp: false)
      data = @battle.item(item)
      return "not_sold" unless data
      return nil unless data.key?("price")   # an export from before item authority: nothing to check

      shop = map.is_a?(Integer) && event.is_a?(Integer) ? @world.shop_object(map, event) : nil
      if op == :buy
        return "not_a_shop" unless shop && shop["kind"] == (bp ? "bp_shop" : "mart")

        prices = clerk_prices(shop, "price_options", item, data[bp ? "bp_price" : "price"])
        prices = prices.select { |p| p > 0 } if shop["dynamic"]   # never free from a computed stock
        return "not_sold" if shop["dynamic"] ? prices.empty? : !Array(shop["items"]).include?(item)
        return "price" unless prices.include?(unit)
      else
        # Any Mart buys back at the catalogue's price; a clerk whose event sets prices may
        # pay its own. One that never offers to buy anything back pays nothing - and where
        # there is no Mart, nothing is bought back at all.
        return "not_a_shop" unless shop && shop["kind"] == "mart"
        return "not_sellable" if shop["sells"] == false

        prices = clerk_prices(shop, "sell_options", item, data["sell_price"]).select { |p| p > 0 }
        return "not_sellable" if data["important"] || prices.empty?
        return "price" unless prices.include?(unit)
      end
      nil
    end

    # -> every price +shop+ may charge ("price_options") or pay back ("sell_options") for
    # +item+: the world export follows each of its event's Mart calls, and names the
    # catalogue's +base+ as nil. An export from before those options knew one price an
    # event set, and no sell price.
    def clerk_prices(shop, key, item, base)
      base = base.to_i
      if shop && shop[key].is_a?(Hash)
        options = shop[key][item]
        return [base] unless options.is_a?(Array)

        return options.map { |p| p.is_a?(Integer) ? p : base }.uniq
      end
      legacy = key == "price_options" && shop ? (shop["prices"] || {})[item] : nil
      [legacy.is_a?(Integer) ? legacy : base]
    end

    GIFT_LEFT_MAP_SEC = 120   # an event may move the player, then pay: the map just left still counts

    # -> the map the server last saw the player on, when that is not +map+ (nor the one
    # just left), for a client that sends its position before it asks; else nil.
    def gift_away(conn, map)
      return nil unless Array(conn.data[:caps]).include?("gift_pos")

      cur = conn.data[:map_id] || (conn.data[:last_pos] || [])[0]
      return nil if !cur.is_a?(Integer) || cur == map

      left = conn.data[:left_map]
      return nil if left && left[0] == map && Process.clock_gettime(Process::CLOCK_MONOTONIC) - left[1] <= GIFT_LEFT_MAP_SEC

      cur
    end

    def note_gift_away(account_id, map, event, item, where)
      @log.call("gift: account #{account_id} #{gift_verdict_word} — map #{map} event #{event} #{item} asked from map #{where}")
      flag_anomaly(account_id, :gift_remote)
    end

    # :gift_applied - the item of request +nonce+ is in the client's bag.
    def handle_gift_applied(env, account_id)
      return unless @gift_grants

      map = env[:map]; event = env[:event]; nonce = env[:nonce]
      return unless map.is_a?(Integer) && event.is_a?(Integer) && nonce.is_a?(Integer)

      @mailbox.submit(account_id) { @gift_grants.applied(account_id, map, event, nonce) }
    end

    # Is +item+ x +qty+ something this event gives? Only asked of an export entry with
    # no computed call (dynamic == false), whose literal list is then complete.
    def gift_item_ok?(obj, item, qty)
      return false unless Array(obj["items"]).include?(item)

      max = obj["quantities"].is_a?(Hash) ? obj["quantities"][item] : nil
      !max.is_a?(Integer) || qty <= max
    end

    def gift_verdict_word
      @config.gift_enforce == :on ? "DENY" : "WOULD-DENY"
    end

    # A random id per connection: a grant remembers the one it went out on, so the
    # first bag snapshot of a later connection knows which grants it settles.
    def gift_conn(conn)
      conn.data[:gift_conn] ||= SecureRandom.random_number(2**62 - 1) + 1
    end

    # M4 Layer D D7 part 1: a finished wild battle's capture record (fire-and-forget,
    # no reply — instrumentation, never adjudicates). The opaque body is stored
    # verbatim for part 2's headless replay; ingest runs on the account mailbox so the
    # seed's roll row (recorded there) is guaranteed visible.
    # Trainer proof P2 (docs/TRAINER-PROOF-DESIGN.md): the seed of a trainer battle about
    # to start. The placement must be one the export knows, on the map the player stands
    # on; the answer is that placement's open seed - the same however often it is asked.
    # Anything else is denied, and the battle runs unseeded (recorded in shadow).
    def handle_trainer_battle_req(conn, env, account_id)
      nonce = env[:nonce]
      deny = ->(why) { reply(conn, type: :trainer_battle_deny, nonce: nonce, reason: why) }
      return deny.("off") unless @trainer_battles

      t = Array(env[:trainers])
      type, name, version, map, event = t[0].is_a?(Array) ? t[0] : []
      unless t.length == 1 && type.is_a?(String) && name.is_a?(String) &&
             [version, map, event].all? { |v| v.is_a?(Integer) }
        return deny.("bad")
      end
      return deny.("unknown") unless @world.trainer_place(map, event, type, name, version)
      # P4: a battle this trainer may share with another is never recorded - no seed for it
      # (its prize comes from the day's allowance).
      return deny.("unprovable") if @trainer_proofs && !@world.trainer_alone?(map, event, type, name, version)

      here = conn.data[:last_pos]
      return deny.("not_here") unless here.is_a?(Array) && here[0] == map

      @mailbox.submit(account_id) do
        seed = @trainer_battles.seed_for(account_id, map, event, type, name, version)
        @reactor.post { reply(conn, type: :trainer_battle_seed, nonce: nonce, seed: seed) if @reactor.alive?(conn) }
      rescue StandardError => e
        @log.call("trainerseed: account #{account_id} #{e.class}: #{e.message}")
        @reactor.post { deny.("error") if @reactor.alive?(conn) }
      end
    end

    # Trainer proof P4: a record naming a client nonce (a trainer battle's) is acknowledged
    # once stored - or known, or never storable - so the client stops sending it again;
    # one over the hourly cap, or not stored for an error, is not (it comes again later).
    def handle_battle_record(conn, env, body, account_id)
      return unless @battle_records

      rec_nonce = MoneyClaims.nonce(env[:rec_nonce])
      @mailbox.submit(account_id) do
        begin
          result = @battle_records.ingest(account_id, env, body)
          # the seed walk refuted the claimed draws -> D5 review-queue counter
          flag_anomaly(account_id, :rng_desync) if result == :desync
          # Trainer proof P3: a replay daemon listening replays it now, not at its next poll.
          (@db.notify(TrainerProofs::REPLAY_CHANNEL) rescue nil) if @trainer_proofs && %i[ok desync].include?(result)
          if rec_nonce && !%i[later error].include?(result)
            @reactor.post { reply(conn, type: :battle_record_ack, rec_nonce: rec_nonce) if @reactor.alive?(conn) }
          end
        rescue StandardError => e
          @log.call("battlerec: ingest job failed #{e.class}: #{e.message}")
        end
      end
    end

    # M4 Layer D D3 (on): server-adjudicated Poké Ball capture. The client asks for a
    # verdict on a ball throw; the server finds the STASHED D2 encounter mint (so species/
    # level/IVs are what IT minted, never client claims), computes the engine capture
    # formula with clamped client inputs (HP bounded by the server-computed max, ball rate
    # capped at the ball's legitimate best, status whitelisted) and rolls the shakes with
    # SecureRandom — a cheat can no longer force an unrolled catch. A successful catch
    # CONSUMES the stashed mint (one catch per encounter). Fail-OPEN: no mint / not
    # enforcing / unknown species -> deny -> the client rolls locally.
    #
    # E4: a ball the server judges and did not recognize when it was thrown (ball_ok?)
    # breaks at once - 0 shakes, never a local roll - so an item taken from nowhere cannot
    # catch. Checked on the account's mailbox (the ledger), then back here.
    def handle_catch_req(conn, env, account_id)
      seq = env[:seq]
      unless @config.battle_enforce_catches == :on
        return reply(conn, type: :catch_deny, seq: seq, reason: "not_enforcing")
      end

      ball = canon(env[:ball].to_s[0, 64])
      if @item_enforce && ball.match?(Inventory::ITEM_ID) && !@judged_local.include?(ball)
        @mailbox.submit(account_id) do
          ok = ball_ok?(account_id, ball)
          @reactor.post do
            next unless @reactor.alive?(conn)
            next adjudicate_catch(conn, env, account_id) if ok

            @log.call("catch: account #{account_id} threw a #{ball} the server does not recognize -> 0 shakes")
            reply(conn, type: :catch_verdict, seq: seq, shakes: 0, critical: false)
          end
        rescue StandardError => e
          @log.call("catch: ball check failed #{e.class}: #{e.message}")
          @reactor.post { adjudicate_catch(conn, env, account_id) if @reactor.alive?(conn) }
        end
        return
      end
      adjudicate_catch(conn, env, account_id)
    end

    # E4: was the +ball+ thrown one the server recognized? Its bag snapshot may land before
    # the throw is judged, so the possession is taken as it was before the minute's
    # decreases. Debts go first, so a throw while any of that ball was unexplained spent an
    # unexplained one; and a ball the possession never showed was never recognized.
    def ball_ok?(account_id, ball)
      units, settled = @recent_down.recent(account_id, ball)
      judged = @db[:inventory_snapshots].where(account_id: account_id).get(:judged).to_h[ball].to_i
      debts  = @item_ledger.open_debts(account_id)[ball].to_i
      (debts + settled).zero? && judged + units >= 1
    end

    def adjudicate_catch(conn, env, account_id)
      seq = env[:seq]
      species = env[:species].to_s[0, 32]
      level   = env[:level]
      mints   = conn.data[:enc_mints]
      mint    = mints.is_a?(Array) &&
                mints.find { |m| !m["caught"] && m["species"] == species && m["level"] == level }
      unless mint
        @log.call("catch: account #{account_id} req #{species}@#{level.inspect} has NO stashed mint -> local")
        return reply(conn, type: :catch_deny, seq: seq, reason: "no_encounter")
      end

      # A miss doesn't consume the mint (vanilla re-throws are legit), so count the
      # attempts: a client hammering :catch_req to brute-force the roll shows up here.
      mint["attempts"] = (mint["attempts"] || 0) + 1
      if mint["attempts"] == 21
        @log.call("catch: account #{account_id} SUSPECT catch-spam #{species}@#{level} (21+ attempts on one mint)")
        flag_anomaly(account_id, :catch_spam)
      end

      hp_iv   = mint["iv"].is_a?(Array) ? mint["iv"][0] : nil
      verdict = @catch_calc.adjudicate(species, mint["level"], hp_iv,
                                       env[:ball].to_s, env[:hp_current], env[:status].to_s,
                                       claimed_rate: env[:claimed_rate],
                                       dex_owned: env[:dex_owned], charm: env[:charm] == true)
      return reply(conn, type: :catch_deny, seq: seq, reason: "unknown_species") unless verdict

      if verdict[:caught]
        # One successful catch per mint. The mint stays stashed, marked, because the
        # battle's end report still has to prove this foe: it opens the reward window
        # the catch's EXP is judged against (dropping it made every level-up from a
        # catch a SUSPECT level jump).
        mint["caught"] = true
        # D3.2: stamp the persisted roll as caught (mailbox FIFO -> after its record).
        pid = mint["pid"]
        lvl = mint["level"]
        @mailbox.submit(account_id) do
          begin
            unless @encounter_rolls.mark_caught(account_id, species, lvl, pid)
              # Always anomalous in the caught branch: the roll's record must have failed.
              @log.call("catch: account #{account_id} caught-stamp found NO roll for #{species}@#{lvl} (record failed earlier?)")
            end
          rescue StandardError => e
            @log.call("catch: roll caught-stamp failed #{e.class}: #{e.message}")
          end
        end
      end
      @log.call("catch: account #{account_id} VERDICT #{species}@#{mint['level']} " \
                "ball=#{env[:ball].to_s[0, 24]} shakes=#{verdict[:shakes]}#{verdict[:critical] ? ' CRIT' : ''} " \
                "#{verdict[:caught] ? 'CAUGHT' : 'broke free'} " \
                "(hp=#{env[:hp_current].inspect}/#{verdict[:total_hp]} status=#{env[:status].to_s[0, 16]})")
      reply(conn, type: :catch_verdict, seq: seq,
            shakes: verdict[:shakes], critical: verdict[:critical])
    end

    # M4 Layer D D3 (shadow): the client reports the shakes its LOCAL calc produced; the
    # server rolls its own verdict from the same (clamped) inputs and logs both, so the
    # ported formula can be validated against real play before `on`. Fire-and-forget.
    def handle_catch_report(conn, env, account_id)
      species = env[:species].to_s[0, 32]
      return if species.empty?

      mints = conn.data[:enc_mints]
      mint  = mints.is_a?(Array) && mints.find { |m| m["species"] == species }
      hp_iv = mint && mint["iv"].is_a?(Array) ? mint["iv"][0] : nil
      would = @catch_calc.adjudicate(species, env[:level], hp_iv,
                                     env[:ball].to_s, env[:hp_current], env[:status].to_s,
                                     claimed_rate: env[:claimed_rate],
                                     dex_owned: env[:dex_owned], charm: env[:charm] == true)
      wm = would ? "#{would[:shakes]}#{would[:critical] ? ' CRIT' : ''}#{would[:caught] ? ' CAUGHT' : ''}" : "-"
      @log.call("catch: account #{account_id} report #{species}@#{env[:level].inspect} " \
                "ball=#{env[:ball].to_s[0, 24]} client_shakes=#{env[:shakes].inspect} server_would=#{wm}")
    end

    # Server-authoritative trade COMMIT (M3.2). The only authoritative trade frame
    # (invite/accept/offer/lock/cancel are pure peer relay via ADDRESSED). Each side
    # commits ONLY after it holds the partner's uid-validated object; the server
    # rendezvous fires the atomic swap when BOTH matching commits arrive.
    def handle_trade_commit(conn, env, account_id)
      trade_id = env[:trade_id]
      partner  = env[:partner]
      give     = env[:give]
      recv     = env[:recv]
      max      = @config.monster_caps[:trade_max]
      unless trade_id.is_a?(String) && partner.is_a?(Integer) && partner != account_id &&
             uid_list?(give, max) && uid_list?(recv, max)
        @log.call("server: bad :trade_commit from account #{account_id} -> drop")
        return
      end
      give = give.sort
      recv = recv.sort

      pending = @pending_trades[trade_id]
      if pending.nil?
        @pending_trades[trade_id] = { account: account_id, partner: partner,
                                      give: give, recv: recv, conn: conn, at: Time.now }
        return
      end

      @pending_trades.delete(trade_id)
      # Cross-check the two commits name each other and mirror give/recv exactly. A
      # third party guessing a trade_id fails here (its partner id won't match).
      unless pending[:account] == partner && pending[:partner] == account_id &&
             pending[:give] == recv && pending[:recv] == give
        reply(conn, type: :trade_result, trade_id: trade_id, ok: false, reason: "terms")
        reply(pending[:conn], type: :trade_result, trade_id: trade_id, ok: false, reason: "terms")
        return
      end

      a = pending[:account]; a_conn = pending[:conn]; a_gives = pending[:give]
      b = account_id;        b_conn = conn;           b_gives = give
      deliveries = escrow_deliveries(trade_id, a, a_conn, b_gives, b) +
                   escrow_deliveries(trade_id, b, b_conn, a_gives, a)
      # What each escrow said its Pokemon holds, checked against the sender's record.
      said = { a => @trade_bodies[a], b => @trade_bodies[b] }.transform_values do |h|
        h && h[:trade_id] == trade_id && h[:item_said] ? h[:item] : :unsaid
      end
      @trade_bodies.delete(a)
      @trade_bodies.delete(b)
      @pool.submit do
        # A raise here used to leave BOTH traders in :committing forever (no client
        # timeout, and Trade.busy? then suppresses everything else) — audit. The
        # transaction has already rolled back, so replying failure is always safe.
        st = begin
          if (bad = held_item_mismatch(said, a => a_gives, b => b_gives))
            @log.call("server: trade #{trade_id} refused - account #{bad} locked a Pokemon holding what its record does not")
            [:abort, :item]
          else
            @trades.execute_trade(trade_id, a: a, b: b, a_gives: a_gives, b_gives: b_gives) do
              # Both item records first, in account order, before any ledger row - the order
              # a snapshot takes too (its record, then the ledger), so the two never deadlock.
              [a, b].sort.each { |acc| @db[:inventory_snapshots].where(account_id: acc).for_update.first }
              # E4: a held item leaves only as the sender's record names it and recognizes it.
              if @item_enforce && (bad = unrecognized_giver(a => a_gives, b => b_gives))
                raise TradeItemRefused, "account #{bad} gives a held item the server does not recognize"
              end
              # E2: a traded Pokemon's held item is explained on the other side as the
              # sender's record knew it - by its delivery when there is one (bound to that
              # Pokemon), else by a credit. Read before the senders' records lose it.
              deliveries.each { |d| d[:item] = confirmed_item(d[:account_id] == a ? b : a, d[:uid], d[:item]) }
              @trade_deliveries.store(deliveries) unless deliveries.empty?
              credit_traded(b, a, a_gives, trade_id) if deliveries.none? { |d| d[:account_id] == b }
              credit_traded(a, b, b_gives, trade_id) if deliveries.none? { |d| d[:account_id] == a }
              # A held item battle points bought stays one on the other side.
              carry_bp_tags(a, b, a_gives)
              carry_bp_tags(b, a, b_gives)
              # The given Pokemon take their held items out of the senders' records.
              a_gives.each { |u| @inventory.drop_holder(a, u) }
              b_gives.each { |u| @inventory.drop_holder(b, u) }
            end
          end
        rescue TradeItemRefused => e
          @log.call("server: trade #{trade_id} refused - #{e.message}")
          [:abort, :item]
        rescue StandardError => e
          @log.call("server: trade #{trade_id} #{a}<->#{b} raised #{e.class}: #{e.message}")
          [:err, "error"]
        end
        @reactor.post do
          if st.first == :ok || st.first == :ok_replay
            reply(a_conn, type: :trade_result, trade_id: trade_id, ok: true, recv: b_gives, gave: a_gives) if @reactor.alive?(a_conn)
            reply(b_conn, type: :trade_result, trade_id: trade_id, ok: true, recv: a_gives, gave: b_gives) if @reactor.alive?(b_conn)
            @log.call("server: trade #{trade_id} #{a}<->#{b} swapped #{a_gives}/#{b_gives}")
          else
            reason = st[1].to_s
            reply(a_conn, type: :trade_result, trade_id: trade_id, ok: false, reason: reason) if @reactor.alive?(a_conn)
            reply(b_conn, type: :trade_result, trade_id: trade_id, ok: false, reason: reason) if @reactor.alive?(b_conn)
          end
        end
      end
    end

    # The escrow a :trade_lock carried, kept until its trade commits: the receiver loads
    # it, and it is the only copy of the Pokemon until the receiver's next save lands.
    # One per sender (a new lock replaces it), one Pokemon's worth, a few minutes.
    ESCROW_TTL = 300
    ESCROW_MAX = 32 * 1024

    def hold_escrow(env, body, from_account)
      return unless @trade_deliveries && body && body.bytesize <= ESCROW_MAX && env[:uid].is_a?(Integer)

      item = env[:item].is_a?(Symbol) && env[:item].length <= 64 ? env[:item] : nil
      @trade_bodies[from_account] = { trade_id: env[:trade_id], uid: env[:uid], body: body, item: item,
                                      item_said: env.key?(:item), at: Time.now }
    end

    # -> the delivery row for +receiver+, if its client can take one again and the uid
    # that moved is the one it was shown.
    def escrow_deliveries(trade_id, receiver, receiver_conn, uids, sender)
      return [] unless @trade_deliveries && Array(receiver_conn.data[:caps]).include?("trade_redeliver")

      held = @trade_bodies[sender]
      return [] unless held && held[:trade_id] == trade_id && uids == [held[:uid]]

      [{ account_id: receiver, uid: held[:uid], trade_id: trade_id.to_s, body: held[:body], item: held[:item]&.to_s }]
    end

    # :trade_applied - the traded Pokemon is in the client's party or a box; the next
    # save that lands holds it.
    def handle_trade_applied(env, account_id)
      trade_id = env[:trade_id]
      return unless @trade_deliveries && trade_id.is_a?(String) && trade_id.bytesize <= 64

      @mailbox.submit(account_id) { @trade_deliveries.ack(account_id, trade_id) }
    end

    # :trade_owed - a client that finished loading asks for the traded Pokemon its save
    # may lack. Each comes as its own :trade_redeliver with the locked body.
    def handle_trade_owed(conn, account_id)
      return unless @trade_deliveries

      @mailbox.submit(account_id) do
        owed = @trade_deliveries.pending(account_id)
        @reactor.post do
          next unless @reactor.alive?(conn)

          owed.each do |d|
            reply_body(conn, { type: :trade_redeliver, trade_id: d[:trade_id], uid: d[:uid] }, d[:body])
          end
          @log.call("trade: account #{account_id} owed #{owed.size} traded Pokemon again") unless owed.empty?
        end
      end
    end

    # The item the lock said +uid+ holds, when the sender's record agrees; else nil.
    def confirmed_item(sender, uid, said)
      known = @inventory.holder_item(sender, uid)
      said && known != :unknown && known.to_s == said ? said : nil
    end

    # E2: the items the Pokemon +uids+ bring +receiver+, as the sender's record knows them
    # (an escrow that said otherwise aborted the trade). One the record does not know
    # explains nothing: a sender's word alone never credits another account.
    def credit_traded(receiver, sender, uids, trade_id)
      return unless @item_ledger

      uids.each do |u|
        item = @inventory.holder_item(sender, u)
        credit_item(receiver, item, 1, "trade", trade_id) if item && item != :unknown
      end
    end

    # E4 (inside the swap, both records locked): -> the account giving a Pokemon whose held
    # item its record does not name, or names without recognizing enough of it (judged
    # total minus open debts), or nil.
    def unrecognized_giver(gives)
      gives.each do |account, uids|
        items = uids.map { |u| @inventory.holder_item(account, u) }
        return account if items.include?(:unknown)

        judged = @db[:inventory_snapshots].where(account_id: account).get(:judged).to_h
        debts  = @item_ledger.open_debts(account)
        items.compact.map { |i| canon(i) }.tally.each do |item, n|
          next if @judged_local.include?(item)
          return account if judged[item].to_i - debts[item].to_i < n
        end
      end
      nil
    end

    # -> the account whose escrow said its Pokemon held something else than its record
    # says, or nil. Only judged when the escrow said it and the record knows the Pokemon.
    def held_item_mismatch(said, gives)
      gives.each do |account, uids|
        item = said[account]
        next if item == :unsaid || uids.size != 1

        record = @inventory.holder_item(account, uids.first)
        return account unless record == :unknown || record == item
      end
      nil
    end

    def uid_list?(a, max)
      a.is_a?(Array) && a.size.between?(1, max) && a.all? { |u| u.is_a?(Integer) && u.positive? }
    end

    # Reactor-thread periodic: time out a lone (half-committed) rendezvous whose
    # partner never committed and never disconnected. A lone commit never mutated
    # the registry, so this only frees the entry + tells the waiter.
    # Reactor-thread periodic hook (fires up to ~2x/s). Keep it O(1): the trade sweep is
    # in-memory; the anomaly sweep is DB-heavy so it's dispatched to a worker, gated to run
    # at most every ANOMALY_SWEEP_SEC and never overlapping itself.
    ANOMALY_SWEEP_SEC = 60
    RESIM_SWEEP_SEC   = 60

    PRESENCE_SILENCE   = 15.0   # a map member silent this long has left it (presence v2)
    PRESENCE_SWEEP_SEC = 1.0
    SYNC_EVERY         = 5.0    # a client asks who is on its map at most this often

    def on_tick
      sweep_trades
      maybe_presence_sweep
      maybe_ban_sweep
      maybe_proof_sweep
      maybe_anomaly_sweep
      maybe_resim_sweep
      maybe_item_sweep
      maybe_prune_deals
    end

    PROOF_SWEEP_SEC = 5

    PROOF_STALE_LOG_SEC = 300

    # Trainer proof P3: the replay's verdicts into the prize claims, on a worker. Shadow:
    # what enforcement would hold is logged (WOULD-HOLD), nothing is held. P4: a verdict
    # tells the online client to ask for its claim again - that ask pays it.
    def maybe_proof_sweep
      return unless @trainer_proofs
      return if @proof_sweeping

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @last_proof_sweep && (now - @last_proof_sweep) < PROOF_SWEEP_SEC

      @last_proof_sweep = now
      @proof_sweeping   = true
      @pool.submit do
        @trainer_proofs.sweep.each do |account_id, nonce, proof, reason|
          if @trainer_enforce
            @log.call("trainerproof: account #{account_id} claim #{nonce} #{proof.to_s.upcase}#{reason ? ": #{reason}" : ''}")
            @reactor.post do
              conn = @online[account_id]
              reply(conn, type: :money_claim_ready, nonce: nonce) if conn && @reactor.alive?(conn)
            end
          elsif proof == :proven
            @log.call("trainerproof: account #{account_id} claim #{nonce} PROVEN")
          else
            @log.call("trainerproof: account #{account_id} claim #{nonce} WOULD-HOLD (#{proof}): #{reason}")
          end
          # a refused battle is a sign as it is judged - not only once its client asks again
          flag_anomaly(account_id, :money_claim) if MoneyClaims::REFUSED_PROOFS.include?(proof.to_s)
          # badge authority B1: a proven win is what grants its badges (B2) - judged on the
          # account's mailbox, after the frames before it
          if @badge_audit
            @reactor.post { @mailbox.submit(account_id) { badge_proof_logs(account_id, nonce, proof) } }
          end
        end
        note_stale_replays(@trainer_proofs.stale, now)
      rescue StandardError => e
        @log.call("trainerproof: sweep failed #{e.class}: #{e.message}")
      ensure
        @reactor.post { @proof_sweeping = false }
      end
    end

    # The replay daemon's silence is an alarm, not a verdict: the claims whose record waits
    # for its replay stay held (at most one warning every PROOF_STALE_LOG_SEC).
    def note_stale_replays(count, now)
      return unless count.positive?
      return if @last_stale_log && now - @last_stale_log < PROOF_STALE_LOG_SEC

      @last_stale_log = now
      @log.call("trainerproof: WARNING #{count} prize claim(s) wait for their battle's replay for more than " \
                "#{TrainerProofs::RECORD_WAIT / 60} minutes - is bin/pemk_replay.rb running (PEMK_REPLAY_LOOP)?")
    end

    BAN_SWEEP_SEC = 10

    # Moderation: an account banned while it plays is told until when and why, and let
    # go, within BAN_SWEEP_SEC. The bans are read on a worker; the connections are
    # closed here, on the reactor.
    def maybe_ban_sweep
      return if @ban_sweeping || @online.empty?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @last_ban_sweep && (now - @last_ban_sweep) < BAN_SWEEP_SEC

      @last_ban_sweep = now
      @ban_sweeping   = true
      ids = @online.keys
      @pool.submit do
        banned = begin
          @bans.banned_among(ids).to_h { |id| [id, @bans.active(id)] }
        rescue StandardError => e
          @log.call("server: ban sweep failed #{e.class}: #{e.message}")
          {}
        end
        @reactor.post do
          @ban_sweeping = false
          banned.each { |id, ban| let_go_banned(id, ban) }   # a forgotten one is purged again as its socket closes
        end
      end
    end

    # On the reactor, as a connection closes: a forgotten account's own rows go again once
    # its queued work is done (a save pushed before it was let go, or before it quit,
    # would bring its character back). One read per close, after that work.
    def purge_if_forgotten(account_id)
      queued = @mailbox.submit(account_id) do
        purge_forgotten(account_id) if Forget.new(@db).forgotten?(account_id)
      rescue StandardError => e
        @log.call("server: account #{account_id} - is it forgotten? #{e.class}: #{e.message}")
      end
      @log.call("server: account #{account_id} mailbox full - a forgotten account's purge waits for its next close") unless queued
    end

    def purge_forgotten(account_id)
      gone = Forget.new(@db).purge(account_id).select { |_, n| n.positive? }
      @log.call("server: account #{account_id} forgotten - #{gone.map { |t, n| "#{n} #{t}" }.join(', ')} purged after its last work") unless gone.empty?
    rescue StandardError => e
      @log.call("server: account #{account_id} forgotten - purge failed #{e.class}: #{e.message}")
    end

    def let_go_banned(account_id, ban)
      conn = @online[account_id]
      return unless conn && ban

      @log.call("server: account #{account_id} is banned - connection closed")
      reply(conn, type: :banned, **Bans.notice(ban))
      @reactor.finish(conn)
    end

    DEAL_PRUNE_SEC = 3600

    # E3: recorded deals older than a week go, once an hour, on a worker.
    def maybe_prune_deals
      return unless @shop_deals

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @last_deal_prune && (now - @last_deal_prune) < DEAL_PRUNE_SEC

      @last_deal_prune = now
      @pool.submit do
        @shop_deals.prune
      rescue StandardError => e
        @log.call("shop: prune failed #{e.class}: #{e.message}")
      end
    end

    # E2: an increase still owing a source after its grace is unexplained. Same
    # non-overlapping worker dispatch as the anomaly sweep.
    ITEM_SWEEP_SEC = 10

    def maybe_item_sweep
      return unless @item_ledger

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @item_sweeping
      return if @last_item_sweep && (now - @last_item_sweep) < ITEM_SWEEP_SEC

      @last_item_sweep = now
      @item_sweeping   = true
      @pool.submit do
        begin
          settle_items
        ensure
          @reactor.post { @item_sweeping = false }
        end
      end
    end

    # One line per account and item, and one review count per account, each sweep: a
    # source the server does not model yet (a berry tree picked twenty times) is one
    # finding, not twenty.
    # E4: a verdict keeps the debt owed (never a local or a key item: those go to review
    # only) and sends the account's live connection its correction.
    def settle_items
      keep = @item_enforce ? ->(_acc, item) { !@judged_local.include?(item) && !key_item?(item) } : nil
      found = @item_ledger.settle(keep: keep).group_by { |u| u[:account_id] }
      found.each do |account_id, list|
        list.group_by { |u| u[:item] }.each do |item, us|
          since = us.map { |u| u[:since] }.min
          @log.call("inv: account #{account_id} UNEXPLAINED +#{us.sum { |u| u[:qty] }} #{item} " \
                    "(seen from #{since.strftime('%H:%M:%S')}, no source within #{@item_ledger.grace}s" \
                    "#{us.any? { |u| u[:owed] } ? '; taken back' : ''})")
        end
        flag_anomaly(account_id, :item_unexplained)
        next unless list.any? { |u| u[:owed] }

        seq = @db[:inventory_snapshots].where(account_id: account_id).get(:last_seq)
        fix = correction_for(account_id)
        @reactor.post { send_correction(@online[account_id], account_id, seq, fix) } if fix && seq
      end
      report_ignored_corrections if @item_enforce
    rescue StandardError => e
      @log.call("inv: item sweep failed #{e.class}: #{e.message}")
    end

    CORRECTION_IGNORED_AFTER = 30 * 60   # a client that applies them does so on its next free frame

    # E4: a correction a client was sent and has not applied for half an hour: a client
    # that refuses them. Reported once per owed debt.
    def report_ignored_corrections
      @item_ledger.ignored_since(Time.now - CORRECTION_IGNORED_AFTER).each do |account_id, items|
        @log.call("inv: account #{account_id} has not applied the correction for #{items.join(', ')} " \
                  "in #{CORRECTION_IGNORED_AFTER / 60} min")
        flag_anomaly(account_id, :item_correction_ignored)
      end
    end

    # D8: same non-overlapping worker-dispatch shape as the anomaly sweep. Consumes
    # harness-stamped verdicts into monster state. Logs a loud WARNING if replayable
    # records pile up while verdict_at never advances (the harness isn't running).
    def maybe_resim_sweep
      return unless @resim

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @resim_sweeping
      return if @last_resim_sweep && (now - @last_resim_sweep) < RESIM_SWEEP_SEC

      @last_resim_sweep = now
      @resim_sweeping   = true
      @pool.submit do
        begin
          @resim.sweep
          warn_if_harness_stalled
        ensure
          @reactor.post { @resim_sweeping = false }
        end
      end
    end

    def warn_if_harness_stalled
      stale = @db[:battle_records].where(replay_status: %w[pending walk_ok walk_skipped])
                                  .where { created_at < Time.now - 86_400 }.count
      @log.call("resim: WARNING #{stale} replayable record(s) >24h old with no verdict — is bin/pemk_replay.rb running?") if stale.positive?
    rescue StandardError => e
      @log.call("resim: harness-liveness check failed #{e.class}: #{e.message}")
    end

    def maybe_anomaly_sweep
      return unless @anomaly

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @anomaly_sweeping
      return if @last_anomaly_sweep && (now - @last_anomaly_sweep) < ANOMALY_SWEEP_SEC

      @last_anomaly_sweep = now
      @anomaly_sweeping   = true
      @pool.submit do
        begin
          @anomaly.sweep
        ensure
          @reactor.post { @anomaly_sweeping = false }   # clear on the reactor thread
        end
      end
    end

    # Fire-and-forget: bump an account's SUSPECT counter off the reactor thread (atomic
    # upsert). No-op unless anomaly detection is enabled.
    def flag_anomaly(account_id, kind)
      @pool.submit { @anomaly.record_flag(account_id, kind) } if @anomaly
    end

    def sweep_trades
      now = Time.now
      @trade_bodies.reject! { |_, v| now - v[:at] > ESCROW_TTL } unless @trade_bodies.empty?
      return if @pending_trades.empty?

      @pending_trades.reject! do |tid, p|
        next false if (now - p[:at]) < TRADE_TTL

        reply(p[:conn], type: :trade_result, trade_id: tid, ok: false, reason: "timeout") if @reactor.alive?(p[:conn])
        true
      end
    end

    # Canonical primitives the client reconciles onto its save at load (login_ok /
    # auth_ok), plus the per-channel seq the client adopts as its next-seq authority.
    # inv carries the whole bag (server-persistent, like economy): nil when unseeded
    # so the client keeps its blob bag and seeds the record on the first flush.
    # mon_seq is the :mon_party high-water; mon_evict is the M3.2 positive list of
    # uids this account traded away and no longer owns (the client evicts them).
    def reconcile_block(account_id, fresh: true)
      # Step 5: a session that loads the stored blob is judged against the durable
      # mirror (or trusted for its first snapshot); a resumed one keeps its mirror.
      @flag_state&.rebase_for_login(account_id, @characters.flags_seq(account_id)) if fresh
      # Step 6: the bag a fresh login loads holds no payout that was never sealed.
      @gift_grants&.void_unsealed(account_id) if fresh
      @trade_deliveries&.unack(account_id) if fresh   # the save it loads cannot hold them
      @item_ledger&.drop_credits(account_id) if fresh # E2: nor any item a waiting credit was for
      void_claims(account_id) if fresh                 # M1a: nor a prize whose battle it may lack
      seed_start_money(account_id)                     # M3: the start money is the server's, not the save's
      @money_shadow&.login(account_id, money_row(account_id).to_i) if fresh   # M1b: the client adopts the ledger's
      snap = @ledger.snapshot(account_id)
      snap[:balances][:badges] = badge_shown(account_id) if badge_enforce?   # B2: always named, 0 too
      inv  = @inventory.snapshot(account_id)
      stores = @config.item_record == :full ? inv[:stores] : nil
      { econ: snap[:balances], econ_seq: snap[:last_seq],
        inv: inv[:bag], inv_seq: inv[:last_seq], inv_stores: stores,
        mon_seq: @monsters.mon_seq(account_id),
        mon_evict: @monsters.evictions(account_id),
        pickup_enforce: @config.pickup_enforce,     # M4 Layer C: client gates pickups only when on
        pickup_reset_allowed: @config.pickup_reset_allowed,    # dev-only F9 reset offered only when on
        client_debug: @config.client_debug.to_s,               # debug mode stays off (deny/autopilot) or not
        battle_enforce_teams: @config.battle_enforce_teams.to_s,   # M4 Layer D D1 team-legality mode
        battle_enforce_encounters: @config.battle_enforce_encounters.to_s,   # M4 Layer D D2 encounter mode
        battle_enforce_catches: @config.battle_enforce_catches.to_s,         # M4 Layer D D3 catch mode
        battle_enforce_rewards: @config.battle_enforce_rewards.to_s,         # M4 Layer D D4 reward mode
        battle_enforce_exp: @config.battle_enforce_exp.to_s,                 # M4 Layer D D6 EXP mode
        battle_enforce_rng: @config.battle_enforce_rng.to_s,                 # M4 Layer D D7 rng/capture mode
        battle_enforce_resim: @config.battle_enforce_resim.to_s,             # M4 Layer D D8 enforcement mode
        flag_state: @config.flag_state.to_s,                                 # audit item 4: flags shadow
        flag_enforce: @config.flag_enforce.to_s,                             # step 5: owned values repaired
        gift_gate: @config.gift_enforce != :off,                             # step 6: ask before a gift
        peer_check: @config.peer_check.to_s,                                 # a peer's Pokemon checked before loading
        trade_redelivery: !@trade_deliveries.nil?,                           # ask for traded Pokemon a save lacks
        shop_gate: @config.shop_enforce != :off,                             # E3: Mart purchases asked first
        bp_shop_gate: @config.shop_enforce != :off,                          # ... and Battle Point exchanges
        shop_recheck: !@shop_deals.nil?,                                     # ... a deal given up on is asked again
        money_claims: money_mode,                                             # money authority: how prizes are claimed
        save_ack: true,                                                      # each save is answered written or not
        trainer_seed: !@trainer_battles.nil?,                                # a trainer battle asks for its seed first
        trainer_proof: @trainer_enforce ? "on" : "off",                      # P4: a prize waits for its battle's proof
        record_ack: !@trainer_proofs.nil?,                                   # P4: a trainer battle's record is acknowledged
        badge_hold: badge_enforce?,                                          # B2: a badge frame waits for its win's claim
        badge_battles: badge_battles_alone,                                  # B2: fought alone, their seeds waited for longer
        flags_seq: (@flag_state ? (@flag_state.snapshot(account_id)&.fetch(:last_seq, 0) || 0) : 0),
        flag_policy: flag_policy,
        flag_facts: (@config.flag_state == :on && @flag_state ? @flag_state.materialize_facts(account_id) : nil) }
    end

    # The owned-id sets FlagState judges over, from the same manifest the client is
    # handed — so the trust gate measures exactly the ids we claim, and nothing else.
    def manifest_policy
      m = @world.flag_manifest
      return nil unless m.is_a?(Hash)

      out = {}
      %w[switches variables].each do |kind|
        sec = m[kind]
        next unless sec.is_a?(Hash)

        out[kind.to_sym] = sec.select { |_, e| e.is_a?(Hash) && e["tier"] && e["tier"] != "local" }.keys
      end
      out
    end

    # id -> stable name key for FACT-tier switches, so the ledger survives a renumber.
    def manifest_fact_keys
      m = @world.flag_manifest
      return {} unless m.is_a?(Hash) && m["switches"].is_a?(Hash)

      out = {}
      m["switches"].each do |id, e|
        out[id.to_i] = e["key"] if e.is_a?(Hash) && e["tier"] == "fact" && e["key"]
      end
      out
    end

    # "map:event" of the events the manifest found to be on a cooldown. Their
    # self-switch is cleared on purpose when the timer elapses, so it must never be
    # banked as a monotonic fact.
    def manifest_repeatable
      m = @world.flag_manifest
      sec = m.is_a?(Hash) ? m["self_switches"] : nil
      sec.is_a?(Hash) ? Array(sec["repeatable"]) : []
    end

    # "map:event:letter" the project writes both ON and OFF - a latch rather than a
    # one-shot marker, so never the server's to bank. Absent from an older export just
    # means the list is empty (the pre-fix behaviour), never a boot error.
    def manifest_latched
      m = @world.flag_manifest
      sec = m.is_a?(Hash) ? m["self_switches"] : nil
      sec.is_a?(Hash) ? Array(sec["latched"]) : []
    end

    # The build-time tier table, pushed so BOTH sides provably agree on the policy.
    # Only NON-LOCAL ids travel — absent means local, which is the pre-sovereignty
    # behaviour, so the payload stays tiny (32 entries on the reference project).
    def flag_policy
      return nil unless @flag_state && @world.flag_manifest

      out = {}
      %w[switches variables].each do |kind|
        sec = @world.flag_manifest[kind]
        next unless sec.is_a?(Hash)

        picked = {}
        sec.each { |id, e| picked[id] = e["tier"] if e.is_a?(Hash) && e["tier"] && e["tier"] != "local" }
        out[kind] = picked unless picked.empty?
      end
      out.empty? ? nil : out
    end

    # Zone-scoped presence: track each player's current map and fan a position
    # update out ONLY to same-map connections (the 500-CCU lever). Runs inline on
    # the reactor thread — cheap, in-memory, no DB. Identity is the server-trusted
    # account_id, not the client-provided :id (anti-spoof).
    #
    # Presence v2 (PEMK_PRESENCE_DEDUP): an idle repeat - the same allowlisted frame
    # again - reaches only the zone's older clients (their 3 s timeout needs it). A
    # client that keeps its peers until a leave (presence_v2) gets each change once,
    # every peer's last frame as it enters a map (or asks: :sync), and a leave when a
    # peer goes - or falls silent for PRESENCE_SILENCE.
    def handle_presence(conn, env, account_id)
      map = env[:map]
      # (closing: a backstop - the reactor drops the rest of a read once a frame closed its
      # socket, and a replaced session is closed as it is replaced)
      return unless map.is_a?(Integer) && !conn.closing

      # A swim with no key (mode keys) is refused before the audit: last_pos stays on land.
      return if mode_refused?(conn, env, account_id)

      # M4 Layer B: audit FIRST. In :on mode an enforceable violation stashes the
      # last-good tile in conn.data[:correct_to] — send a :pos_correct and REJECT the
      # frame: no zone change and no fan-out of the rejected position, so peers keep
      # seeing the offender at its last accepted tile and it never joins the illegal
      # map's zone. In :off/:shadow correct_to is never set, so the frame flows on.
      @pos_audit.check(account_id, env, conn.data)
      if (tgt = conn.data.delete(:correct_to))
        conn.data.delete(:sync_at) if tgt[0] != map   # a snap-back to another map clears the client's remotes: its next ask is honoured
        reply(conn, type: :pos_correct, map: tgt[0], x: tgt[1], y: tgt[2])
        return
      end

      # :map_id is the last map this connection reported (money claims, gifts and the
      # reconnect fallback read it); :zone the map whose presence zone it is in - none
      # while a replaced or silent session is out of it.
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      conn.data[:presence_seen] = now
      old = conn.data[:map_id]
      conn.data[:left_map] = [old, now] if old && old != map   # gift_place
      conn.data[:map_id] = map
      zone = conn.data[:zone]
      zone_leave(conn, zone, account_id) if zone && zone != map
      joined = conn.data[:zone] != map
      zone_join(conn, map) if joined

      # ALLOWLIST the fan-out frame instead of echoing the client's envelope: env.merge
      # would relay every extra key the client attached (up to the 64 KiB envelope cap)
      # to every peer on the map — a broadcast amplifier, and an injection surface.
      frame   = presence_frame(env, account_id, map)
      content = frame.reject { |k, _| k == :type }
      body    = Wire.encode_split(frame)
      dedup   = @config.presence_dedup
      if dedup && !joined && conn.data[:presence_content] == content
        broadcast_legacy(map, conn, body)   # an idle repeat
      else
        conn.data[:presence_content] = content
        conn.data[:presence_body]    = body
        broadcast_zone(map, conn, body)
      end
      # last: a snapshot that overflows the joiner's output closes it, and the leave that
      # close sends must follow its frame, not precede it (a ghost on every peer)
      return unless dedup && (joined || sync_due?(conn, env, now))

      send_snapshot(conn, map)
      conn.data[:sync_at] = now
    end

    # A client asks who is on its map (:sync) after it cleared its remotes - and again on
    # the next frames, in case one was dropped. A snapshot goes at most every SYNC_EVERY
    # (one at the map's entry counts): each is a frame per peer.
    def sync_due?(conn, env, now)
      return false unless env[:sync] == true

      (at = conn.data[:sync_at]).nil? || now - at >= SYNC_EVERY
    end

    # Mode keys: a surfer or a diver needs the badge the game requires (the export's
    # field_keys). On the first frame in such a mode the keys are read once, off the
    # reactor - the badges the client may use: owned or pending under B2, the ledger's
    # otherwise - and the verdict cached MODE_TTL on the connection (the account's own
    # badge frames and claims clear it). With no key: logged and flagged once per
    # MODE_TTL; under PEMK_POS_ENFORCE=on the frame is refused and the player sent back
    # to the land tile it left - every later frame in that mode the same, until it moves
    # another way. Never a DB read on the reactor thread, one read in flight at most.
    KEYED_MODES = %i[surf dive].freeze
    MODE_TTL    = 30.0

    # A debug client is waived the keys by the game itself (pbCheckHiddenMoveBadge).
    def mode_keys_checked?
      !@mode_keys.nil? && @config.client_debug != :allow
    end

    # -> true when the frame is refused. A verdict known - the login's, a read's - stays in
    # force until a fresh one replaces it: a frame that cleared it would be a free swim.
    def mode_refused?(conn, env, account_id)
      mode = env[:mode]
      conn.data[:mode_cur] = mode
      unless mode_keys_checked? && KEYED_MODES.include?(mode)
        conn.data.delete(:mode_from)      # the land it leaves next is captured anew
        conn.data.delete(:mode_flagged)   # an episode of keyless swimming ended
        return false
      end
      conn.data[:mode_from] ||= land_tile(conn.data[:last_pos])   # the land it left: before the audit moves on
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cached = conn.data.dig(:mode_keys, mode)
      if (cached.nil? || cached[:stale] || now - cached[:at] >= MODE_TTL) && !conn.data[:mode_job]
        mode_read(conn, account_id)   # the verdict known, if any, holds meanwhile
      end
      return false if cached.nil? || cached[:ok]

      deny_mode(conn, mode, cached[:held], now)
      mode_enforced? && refuse_mode(conn, env[:map])
    end

    # Under `on`, with no script of the game starting swims, a keyless swim is refused.
    def mode_enforced?
      @config.position_enforcement == :on && @mode_keys[:sources].empty?
    end

    # The login's own badge read seeds the verdicts: the first swim is judged at once.
    def seed_mode_keys(conn, held)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      conn.data[:mode_keys] = KEYED_MODES.to_h { |m| [m, { ok: key_ok?(m, held), held: held, at: now }] }
    end

    # The account's badges may have moved (its badge frame, a prize claim): read again at
    # once - fresh before its next swim - the verdicts known holding until then.
    def mode_keys_stale(conn, account_id)
      return unless conn.data[:mode_keys]

      conn.data[:mode_keys].each_value { |e| e[:stale] = true }
      mode_read(conn, account_id) unless conn.data[:mode_job]
    end

    # One read for both modes, after the claims before it (a win's badge counts).
    def mode_read(conn, account_id)
      token = conn.data[:mode_job] = conn.data[:mode_token].to_i + 1
      conn.data[:mode_token] = token
      queued = @mailbox.submit(account_id) do
        held = begin
          badges_allowed(account_id)
        rescue StandardError => e
          @log.call("posaudit: account #{account_id} mode key read failed #{e.class}: #{e.message}")
          nil
        end
        @reactor.post { mode_verdict(conn, token, held) }
      end
      conn.data.delete(:mode_job) unless queued   # a full queue: asked again at the next frame
    end

    # On the reactor: the read's badges fill the verdicts; a swim going on with no key is
    # denied now; a read that failed leaves them as they were (read again at the next swim).
    def mode_verdict(conn, token, held)
      conn.data.delete(:mode_job) if conn.data[:mode_job] == token
      return unless held && @reactor.alive?(conn)

      seed_mode_keys(conn, held)
      mode = conn.data[:mode_cur]
      return unless KEYED_MODES.include?(mode) && !key_ok?(mode, held)

      deny_mode(conn, mode, held, Process.clock_gettime(Process::CLOCK_MONOTONIC))
    end

    # A keyless swim: said once per MODE_TTL (it is a steady state), flagged once per
    # episode - never where a script of the game starts swims (a player may then swim
    # with no key: logged only).
    def deny_mode(conn, mode, held, now)
      id = conn.data[:account_id]
      said = conn.data[:mode_said]
      unless said && said[0] == mode && now - said[1] < MODE_TTL
        conn.data[:mode_said] = [mode, now]
        what = "account #{id} #{mode} with no key (#{key_text(mode)} needed, has #{badge_count(held)}: #{held.to_s(2)})"
        if @config.position_enforcement != :on
          @log.call(@config.position_enforcement == :shadow ? "posenforce[shadow]: #{what} WOULD-CORRECT" : "posaudit: #{what}")
        elsif !@mode_keys[:sources].empty?
          @log.call("posaudit: #{what} (logged only: a script of the game starts swims)")
        elsif conn.data[:mode_from]
          @log.call("posaudit: #{what} -> sent back to the shore")
        else
          @log.call("posaudit: #{what} -> dropped (no land known)")
        end
      end
      return if conn.data[:mode_flagged] == mode || !@mode_keys[:sources].empty?

      conn.data[:mode_flagged] = mode
      flag_anomaly(id, :mode_illegal)
    end

    # A refused frame: no audit, no fan-out, and the way back to the land it left (none
    # known - a session begun on the water: the frame is only dropped). A way back to
    # another map clears the client's remotes: its next ask for them is honoured.
    def refuse_mode(conn, map)
      land = conn.data[:mode_from]
      if land
        conn.data.delete(:sync_at) if land[0] != map
        reply(conn, type: :pos_correct, map: land[0], x: land[1], y: land[2])
      end
      true
    end

    # +pos+ when the export knows it as land
    def land_tile(pos)
      pos if pos && @world.water?(pos[0], pos[1], pos[2]) == false
    end

    # The badges the client may use: what it is shown under B2 (owned or pending), the
    # ledger's mask otherwise (the client's own word then).
    def badges_allowed(account_id)
      badge_enforce? ? badge_shown(account_id) : @ledger.current(account_id, :badges).to_i
    end

    # A negative setting is no requirement; counting games need that many badges, the
    # others that one; the Dive key surfs too (surfacing from a dive).
    def key_ok?(mode, held)
      keys = [@mode_keys[mode]]
      keys << @mode_keys[:dive] if mode == :surf && @mode_keys[:dive] >= 0   # a Dive key surfs; "no Dive key" frees nothing
      keys.any? { |n| n.negative? || (@mode_keys[:count_badges] ? badge_count(held) >= n : held[n] == 1) }
    end

    def badge_count(mask)
      mask.to_i.to_s(2).count("1")
    end

    def key_text(mode)
      n = @mode_keys[mode]
      return "no badge" if n.negative?

      @mode_keys[:count_badges] ? "#{n} badges" : "badge #{n}"
    end

    def log_mode_keys
      unless @mode_keys
        @log.call("server: mode keys: the export predates them (one debug launch regenerates it) - a swim's key is not checked")
        return
      end
      what = if @config.position_enforcement != :on then "a swim with no key is logged"
             elsif @mode_keys[:sources].empty? then "a swim with no key is sent back to the shore"
             else "a swim with no key is logged only: a script of the game starts swims"
             end
      @log.call("server: mode keys: surf needs #{key_text(:surf)}, dive #{key_text(:dive)} (#{what})")
      @log.call("server: WARNING mode keys: client debug is allowed - the game waives the keys there, none is checked") if @config.client_debug == :allow
      @log.call("server: mode keys: the badges are the client's word (badge authority does not enforce)") unless badge_enforce?
      return if @mode_keys[:sources].empty?

      where = @mode_keys[:sources].first(5).map { |s| @world.badge_where(s) }.join("; ")
      @log.call("server: WARNING mode keys: #{@mode_keys[:sources].size} script(s) start a swim by themselves (#{where}) - " \
                "a swim with no key is logged, never sent back")
    end

    # Presence zones (reactor thread). A client without presence_v2 is also in its
    # zone's legacy set: the only members an idle repeat still reaches.
    def zone_join(conn, map)
      return if conn.closing   # a frame read with the one that closed it

      @zones[map].add(conn)
      (@zone_legacy[map] ||= Set.new).add(conn) unless conn.data[:presence_v2]
      conn.data[:zone] = map
    end

    # +conn+ leaves +map+'s zone, and its peers are told - unless the same account is
    # still on that map through a newer session (a replaced one closing late: bind and
    # the silence sweep take it out first, this is the backstop).
    def zone_leave(conn, map, account_id)
      conn.data.delete(:zone) if conn.data[:zone] == map
      zone = @zones.fetch(map, nil)
      return unless zone

      zone.delete(conn)
      if (legacy = @zone_legacy[map])
        legacy.delete(conn)
        @zone_legacy.delete(map) if legacy.empty?
      end
      live  = account_id && @online[account_id]
      stays = live && !live.equal?(conn) && live.data[:zone] == map
      broadcast_zone(map, conn, Wire.encode_split({ type: :leave, id: account_id })) if account_id && !stays
      @zones.delete(map) if zone.empty?   # reap AFTER the broadcast (audit: unbounded growth)
    end

    # Every peer's last frame on +map+, in one write, for +conn+ entering it (or asking):
    # a v2 client sees idle players at once - no heartbeat to wait for.
    def send_snapshot(conn, map)
      bodies = @zones.fetch(map, nil)&.filter_map do |peer|
        peer.data[:presence_body] unless peer.equal?(conn) || peer.closing
      end
      @reactor.send_frame(conn, bodies.join) if bodies && !bodies.empty?
    end

    # A zone member silent for PRESENCE_SILENCE (a dead link the socket has not shown
    # yet, a frozen client) leaves its map: a v2 peer would keep it for good. Its next
    # frame brings it back, with a snapshot. At most every PRESENCE_SWEEP_SEC, O(members).
    def maybe_presence_sweep
      return unless @config.presence_dedup

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @presence_swept_at && now - @presence_swept_at < PRESENCE_SWEEP_SEC

      @presence_swept_at = now
      stale = []
      @zones.each do |map, zone|
        zone.each { |c| stale << [c, map] if now - (c.data[:presence_seen] || now) > PRESENCE_SILENCE }
      end
      leave = Hash.new { |h, id| h[id] = Wire.encode_split({ type: :leave, id: id }) }   # encoded once per sweep
      stale.each do |c, map|
        c.data.delete(:presence_content)
        # it drops everyone too: out of the zone it hears no leave, and the snapshot of
        # its return only adds who is there then (the members as they are before its
        # own leave goes out: that broadcast may close one of them)
        peers = (@zones.fetch(map, nil) || []).reject { |p| p.equal?(c) }.map { |p| p.data[:account_id] }
        zone_leave(c, map, c.data[:account_id])
        @reactor.send_frame(c, peers.map { |id| leave[id] }.join) unless c.closing || peers.empty?
      end
    end

    # The only fields a presence frame may carry to peers. Peers draw the player from
    # its sprite, pace and name, so those pass too, each checked: every client on
    # the map shows them.
    def presence_frame(env, account_id, map)
      out = { type: env[:type], id: account_id, map: map }
      %i[x y dir mode].each { |k| out[k] = env[k] if env[k].is_a?(Integer) || env[k].is_a?(Symbol) }
      out[:speed] = env[:speed] if env[:speed].is_a?(Integer) && env[:speed].between?(1, 6)
      (char = PlainText.charset(env[:char])) && out[:char] = char
      (name = PlainText.name(env[:name])) && out[:name] = name
      out
    end

    def broadcast_zone(map, sender, frame)
      @zones.fetch(map, nil)&.each { |c| @reactor.send_frame(c, frame) unless c.equal?(sender) }
    end

    def broadcast_legacy(map, sender, frame)
      @zone_legacy[map]&.each { |c| @reactor.send_frame(c, frame) unless c.equal?(sender) }
    end

    # Relay an addressed frame to ONLY the :to account's connection, re-stamping
    # :from with the server-trusted sender id and preserving the opaque body
    # (e.g. a battle team). Unknown/offline or self-addressed -> dropped.
    #
    # AUTHORIZATION (audit): the relay used to forward ANY of the 15 addressed types,
    # with an unbounded body, to ANY online account. That was three weapons at once —
    # a >OUTBUF_CAP body disconnected the victim, an unsolicited :battle_team made the
    # victim Marshal.load attacker bytes, and a third party could inject into a live
    # battle. Now: HANDSHAKE frames (invite/accept/decline) may reach a stranger — that
    # is what an invite IS — but every PAYLOAD frame requires a live peer session that
    # only a mutual accept creates, and every body is capped.
    RELAY_BODY_MAX = 256 * 1024   # a Marshal'd battle team is a few KB

    def handle_addressed(sender, env, body, from_account)
      target = @online[env[:to]]
      if target.nil? || target.equal?(sender)
        @log.call("server: no route for #{env[:type].inspect} -> #{env[:to].inspect}")
        return
      end

      if body && body.bytesize > RELAY_BODY_MAX
        @log.call("server: account #{from_account} oversized #{env[:type].inspect} body " \
                  "(#{body.bytesize}B > #{RELAY_BODY_MAX}) -> drop")
        return
      end

      unless relay_allowed?(env[:type], from_account, env[:to])
        @log.call("server: account #{from_account} #{env[:type].inspect} -> #{env[:to].inspect} " \
                  "without a peer session -> drop")
        return
      end

      return unless peer_body_ok?(env[:type], body, from_account)

      hold_escrow(env, body, from_account) if env[:type] == :trade_lock
      note_peer_session(env[:type], from_account, env[:to])
      @reactor.send_frame(target, Wire.encode_split(relayed_envelope(env, from_account), body))
    end

    # The receiver Marshal-loads a relayed body, so one naming a class outside the
    # allow list is not forwarded (PEMK_PEER_CHECK on): the bytes are read, never
    # loaded (MarshalScan). An honest client only ever sends a party.
    def peer_body_ok?(type, body, from_account)
      return true if body.nil? || @config.peer_check == :off

      why = MarshalScan.refusal(body, @config.peer_classes)
      return true unless why

      on = @config.peer_check == :on
      @log.call("server: account #{from_account} #{type.inspect} body #{on ? 'REFUSED' : 'WOULD-REFUSE'} (#{why})")
      flag_anomaly(from_account, :peer_body)
      !on
    end

    # The envelope as the target receives it: the trusted sender, and a :name (the
    # inviter's, or the offered Pokemon's) it can print without running codes.
    def relayed_envelope(env, from_account)
      out = env.merge(from: from_account)
      if out.key?(:name)
        name = PlainText.name(out[:name])
        name ? out[:name] = name : out.delete(:name)
      end
      out
    end

    # Frames a stranger may legitimately send: the handshake itself, plus the
    # TEARDOWN. trade_cancel is deliberately here — the inviter's :awaiting_accept
    # watchdog fires BEFORE any accept opened a session, and dropping that cancel
    # would leave the invitee waiting on its own 30s timeout instead of being told
    # at once. It is a pure control frame (no body is ever read from it) and the
    # client already ignores one that doesn't match its own live trade (`mine?`),
    # so admitting it from a stranger grants nothing.
    HANDSHAKE = %i[challenge challenge_accept challenge_decline
                   trade_invite trade_accept trade_decline trade_cancel].freeze

    def relay_allowed?(type, from_account, to_account)
      return true if HANDSHAKE.include?(type)

      @peer_sessions[from_account] == to_account && @peer_sessions[to_account] == from_account
    end

    # A mutual accept opens the session; a decline/cancel/end closes it. Reactor-thread
    # only (like @online/@zones), so a plain Hash is correct.
    def note_peer_session(type, from_account, to_account)
      case type
      when :challenge_accept, :trade_accept
        @peer_sessions[from_account] = to_account
        @peer_sessions[to_account]   = from_account
      when :challenge_decline, :trade_decline, :trade_cancel, :battle_end
        clear_peer_session(from_account)
        clear_peer_session(to_account)
      end
    end

    def clear_peer_session(account_id)
      partner = @peer_sessions.delete(account_id)
      @peer_sessions.delete(partner) if partner && @peer_sessions[partner] == account_id
    end

    def bind(conn, account_id)
      # A reconnect on a new socket takes over routing for the account. The socket it
      # replaces is told why before it closes, so a window whose account was logged in
      # elsewhere stays offline instead of taking the account back: two windows trading
      # the session every few seconds each pushed its own save over the other's.
      previous = @online[account_id]
      if previous && !previous.equal?(conn)
        reply(previous, type: :session_replaced)
        # its map sees the player leave now, not when its socket finally drains: a late
        # leave would hide the new session from its peers
        (pzone = previous.data[:zone]) && zone_leave(previous, pzone, account_id)
        @reactor.finish(previous)
      end
      conn.data[:account_id] = account_id
      conn.data[:presence_v2] = @config.presence_dedup && Array(conn.data[:caps]).include?("presence_v2")
      @online[account_id] = conn
      @log.call("server: authed #{conn.addr} as account #{account_id}")
      return if @config.client_debug == :allow || Array(conn.data[:caps]).include?("debug_lock")

      @log.call("server: account #{account_id}'s client keeps debug mode (no debug_lock: an older client)")
    end

    # At boot: whether debug mode stays off on the clients.
    def log_client_debug
      case @config.client_debug
      when :deny
        @log.call("server: client debug = deny (debug mode stays off on the clients while they play here, " \
                  "their autopilot only reads; PEMK_CLIENT_DEBUG=allow for a dev server)")
      when :autopilot
        @log.call("server: WARNING client debug = autopilot - debug mode stays off, but a debug launch's " \
                  "autopilot is obeyed (the autotest's level: never a public server)")
      else
        @log.call("server: WARNING client debug = allow - a client in debug mode keeps it here " \
                  "(walls, trainer battles, debug menus): a dev server only")
      end
      return unless @config.pickup_reset_allowed && @config.client_debug != :allow

      @log.call("server: PEMK_ALLOW_PICKUP_RESET does nothing - its tool is in the debug menu, off here")
    end

    def reply(conn, **env)
      @reactor.send_frame(conn, Wire.encode_split(env))
    end

    def reply_body(conn, env, body)
      @reactor.send_frame(conn, Wire.encode_split(env, body))
    end

    def on_close(conn)
      aid = conn.data[:account_id]
      @online.delete(aid) if aid && @online[aid].equal?(conn)
      if aid
        cancel_pending_trades(aid, conn)
        clear_peer_session(aid)   # a dropped account's peer session dies with it
        @flag_state&.forget(aid) unless @online.key?(aid)   # step 5 mirrors of a gone account
        # a forgotten account's own rows go again after its last queued work (a save
        # pushed just before it quit) - whether the ban sweep let it go or it left first
        purge_if_forgotten(aid)
      end

      map = conn.data[:map_id]
      return unless map

      @last_maps[aid] = map if aid && @last_maps   # M1a: a claim re-sent after a reconnect may name it
      (zone = conn.data[:zone]) && zone_leave(conn, zone, aid)
    end

    # A dropped account cancels any rendezvous it was part of. If a LONE committer
    # (the still-connected party) was waiting on this account, tell it "partner_left"
    # — a single commit never mutated the registry, so nothing was traded.
    def cancel_pending_trades(aid, closing_conn)
      @pending_trades.reject! do |tid, p|
        next false unless p[:account] == aid || p[:partner] == aid

        waiter = p[:conn]
        if !waiter.equal?(closing_conn) && @reactor.alive?(waiter)
          reply(waiter, type: :trade_result, trade_id: tid, ok: false, reason: "partner_left")
        end
        true
      end
    end

    def install_signal_handlers
      %w[INT TERM].each { |sig| Signal.trap(sig) { @reactor.stop } }
    end
  end
end
